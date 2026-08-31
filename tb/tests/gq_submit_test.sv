`ifndef GQ_SUBMIT_TEST_SV
`define GQ_SUBMIT_TEST_SV

class gq_prepare_fail_desc extends gq_desc_base;
    `uvm_object_utils(gq_prepare_fail_desc)

    function new(string name = "gq_prepare_fail_desc");
        super.new(name);
    endfunction

    virtual function bit prepare();
        void'(alloc_owned(24, 8));
        return 0;
    endfunction
endclass

class gq_bad_pack_desc extends gq_desc_base;
    `uvm_object_utils(gq_bad_pack_desc)

    function new(string name = "gq_bad_pack_desc");
        super.new(name);
    endfunction

    virtual function bit prepare();
        return alloc_owned(16, 8) != '1;
    endfunction

    virtual function void pack(ref byte packed_data[]);
        packed_data = new[63];
    endfunction
endclass

class gq_counting_tx_desc extends mailbox_tx_desc;
    `uvm_object_utils(gq_counting_tx_desc)

    int unsigned prepare_calls;

    function new(string name = "gq_counting_tx_desc");
        super.new(name);
        prepare_calls = 0;
    endfunction

    virtual function bit prepare();
        prepare_calls++;
        return super.prepare();
    endfunction
endclass

class gq_delayed_mock_adapter extends mailbox_mock_adapter;
    `uvm_object_utils(gq_delayed_mock_adapter)

    time publish_delay;
    uvm_event publish_entered;

    function new(string name = "gq_delayed_mock_adapter");
        super.new(name);
        publish_delay   = 0;
        publish_entered = new({name, "_publish_entered"});
    endfunction

    virtual task publish(gq_role_e role, int unsigned queue_id,
                         gq_raw_ptr_t raw_tail);
        publish_entered.trigger();
        #(publish_delay);
        super.publish(role, queue_id, raw_tail);
    endtask
endclass

class gq_host_access_catcher extends uvm_report_catcher;
    `uvm_object_utils(gq_host_access_catcher)

    bit caught_host_fatal;

    function new(string name = "gq_host_access_catcher");
        super.new(name);
        caught_host_fatal = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_FATAL && get_id() == "HOST_MEM") begin
            caught_host_fatal = 1;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class gq_pack_size_catcher extends uvm_report_catcher;
    `uvm_object_utils(gq_pack_size_catcher)

    bit caught_pack_fatal;
    string caught_message;

    function new(string name = "gq_pack_size_catcher");
        super.new(name);
        caught_pack_fatal = 0;
        caught_message    = "";
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_FATAL && get_id() == "GQ_PACK_SIZE") begin
            caught_pack_fatal = 1;
            caught_message    = get_message();
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass

class gq_submit_test_engine extends gq_queue_engine;
    `uvm_component_utils(gq_submit_test_engine)

    int unsigned membership_validation_steps;
    int unsigned outstanding_audit_steps;

    function new(string name = "gq_submit_test_engine", uvm_component parent = null);
        super.new(name, parent);
        membership_validation_steps = 0;
        outstanding_audit_steps = 0;
    endfunction

    protected virtual function bit mark_request_id_seen(
        gq_desc_base desc, ref bit seen_ids[int]);
        membership_validation_steps++;
        return super.mark_request_id_seen(desc, seen_ids);
    endfunction

    protected virtual function void audit_outstanding_entry(
        string transition_name, gq_logical_seq_t seq, gq_desc_base desc);
        outstanding_audit_steps++;
        super.audit_outstanding_entry(transition_name, seq, desc);
    endfunction

    function void reset_membership_validation_steps();
        membership_validation_steps = 0;
    endfunction

    function void reset_outstanding_audit_steps();
        outstanding_audit_steps = 0;
    endfunction

    task audit_state_invariants_for_test(string transition_name);
        state_lock.get(1);
        super.audit_state_invariants(transition_name);
        state_lock.put(1);
    endtask

    task probe_state_lock_for_test();
        super.probe_state_lock();
    endtask

    task probe_publish_locks_for_test(output bit locks_available);
        bit got_user;
        bit got_submit;

        got_user   = user_request_ordering.try_get(1);
        got_submit = submit_serialization.try_get(1);
        if (got_submit)
            submit_serialization.put(1);
        if (got_user)
            user_request_ordering.put(1);
        locks_available = got_user && got_submit;
    endtask
endclass

class gq_submit_test extends uvm_test;
    `uvm_component_utils(gq_submit_test)

    host_mem_manager     mem;
    host_mem_manager     failure_mem;
    host_mem_manager     validation_mem;
    gq_test_ptr_codec    ptr_codec;
    gq_delayed_mock_adapter adapter;
    mailbox_mock_dut     dut;
    mailbox_mock_adapter failure_adapter;
    mailbox_mock_adapter validation_adapter;
    mailbox_env_cfg      env_cfg;
    mailbox_env          env;
    gq_queue_cfg         failure_cfg;
    gq_queue_engine      failure_engine;
    gq_queue_cfg         validation_cfg;
    gq_submit_test_engine validation_engine;

    function new(string name = "gq_submit_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function gq_queue_cfg make_queue_cfg(string name, int unsigned queue_id);
        gq_queue_cfg cfg;

        cfg = gq_queue_cfg::type_id::create(name);
        cfg.queue_id           = queue_id;
        cfg.role               = GQ_TX;
        cfg.depth              = 32;
        cfg.desc_size          = 64;
        cfg.alignment          = 64;
        cfg.status_area_size   = 0;
        cfg.wait_mode          = GQ_POLL;
        cfg.poll_min_interval  = 10ns;
        cfg.poll_max_interval  = 10ns;
        cfg.completion_timeout = 1us;
        cfg.ptr_codec          = ptr_codec;
        cfg.completion_source  = mailbox_completion::type_id::create(
            {name, "_completion"});
        return cfg;
    endfunction

    function mailbox_tx_desc make_tx(string name, int unsigned index);
        mailbox_tx_desc desc;

        desc = mailbox_tx_desc::type_id::create(name);
        desc.srcid       = 16'h1100 + index;
        desc.dstid       = 16'h2200 + index;
        desc.msg_type    = 16'h3300 + index;
        desc.buf_len     = 0;
        desc.data_len    = 3;
        desc.data[0]     = byte'(8'ha0 + index);
        desc.data[1]     = byte'(8'hb0 + index);
        desc.data[2]     = byte'(8'hc0 + index);
        return desc;
    endfunction

    function void check_tx_slot(gq_queue_engine engine,
                                gq_logical_seq_t seq,
                                mailbox_tx_desc expected);
        mailbox_tx_desc decoded;
        byte packed_data[];
        gq_addr_t slot_addr;

        slot_addr = engine.ring_base() + ((seq % 32) * 64);
        mem.read_mem(slot_addr, 64, packed_data, `__FILE__, `__LINE__);
        decoded = mailbox_tx_desc::type_id::create($sformatf("decoded_%0d", seq));
        if (!decoded.unpack(packed_data))
            `uvm_fatal("SUBMIT_SLOT", $sformatf("slot %0d did not unpack", seq))
        if (decoded.srcid != expected.srcid || decoded.dstid != expected.dstid ||
            decoded.msg_type != expected.msg_type || decoded.data_len != expected.data_len)
            `uvm_fatal("SUBMIT_SLOT", $sformatf("slot %0d scalar mismatch", seq))
        for (int unsigned i = 0; i < expected.data_len; i++) begin
            if (decoded.data[i] !== expected.data[i])
                `uvm_fatal("SUBMIT_SLOT", $sformatf("slot %0d data[%0d] mismatch", seq, i))
        end
        if (decoded.flags !== 16'h0001)
            `uvm_fatal("SUBMIT_OWNERSHIP", $sformatf(
                "slot %0d flags 0x%04h, expected AVAIL=1 USED=0",
                seq, decoded.flags))
    endfunction

    function void expect_resource_error(string check_name, gq_response response);
        if (response == null || response.status != GQ_RESOURCE_ERROR ||
            response.committed_count != 0)
            `uvm_fatal("SUBMIT_REJECT", {check_name, " did not return resource error"})
    endfunction

    function void build_phase(uvm_phase phase);
        string reason;

        super.build_phase(phase);
        gq_queue_engine::type_id::set_type_override(gq_submit_test_engine::get_type());
        mem = new("mem");
        mem.init_region(64'h0000_0001_1000_0000,
                        64'h0000_0001_10ff_ffff, MODE_LINEAR, 16);
        failure_mem = new("failure_mem");
        failure_mem.init_region(64'h0000_0001_2000_0000,
                                64'h0000_0001_20ff_ffff, MODE_LINEAR, 16);
        validation_mem = new("validation_mem");
        validation_mem.init_region(64'h0000_0001_3000_0000,
                                   64'h0000_0001_30ff_ffff, MODE_LINEAR, 16);
        ptr_codec      = gq_test_ptr_codec::type_id::create("ptr_codec");
        adapter        = gq_delayed_mock_adapter::type_id::create("adapter");
        dut            = mailbox_mock_dut::type_id::create("dut");
        dut.mem        = mem;
        dut.adapter    = adapter;
        failure_adapter = mailbox_mock_adapter::type_id::create("failure_adapter");
        validation_adapter = mailbox_mock_adapter::type_id::create("validation_adapter");

        env_cfg = mailbox_env_cfg::type_id::create("env_cfg");
        env_cfg.mem       = mem;
        env_cfg.adapter   = adapter;
        env_cfg.ptr_codec = ptr_codec;
        if (!env_cfg.add_tx(7, 32, reason))
            `uvm_fatal("SUBMIT_CFG", reason)
        uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", env_cfg);
        env = mailbox_env::type_id::create("env", this);

        failure_cfg = make_queue_cfg("failure_cfg", 8);
        uvm_config_db#(gq_queue_cfg)::set(this, "failure_engine", "cfg", failure_cfg);
        uvm_config_db#(host_mem_api)::set(this, "failure_engine", "mem", failure_mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "failure_engine", "adapter",
                                           failure_adapter);
        failure_engine = gq_queue_engine::type_id::create("failure_engine", this);

        validation_cfg = make_queue_cfg("validation_cfg", 9);
        validation_cfg.depth = 1024;
        uvm_config_db#(gq_queue_cfg)::set(this, "validation_engine", "cfg",
                                          validation_cfg);
        uvm_config_db#(host_mem_api)::set(this, "validation_engine", "mem",
                                          validation_mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "validation_engine", "adapter",
                                           validation_adapter);
        validation_engine =
            gq_submit_test_engine::type_id::create("validation_engine", this);
    endfunction

    task run_phase(uvm_phase phase);
        uvm_component component_handle;
        gq_sequencer sequencer;
        gq_submit_test_engine engine;
        mailbox_tx_sequence tx_sequence;
        mailbox_tx_desc single_desc;
        mailbox_tx_desc batch_descs[3];
        gq_request request;
        gq_response response;
        mailbox_tx_desc rollback_first;
        gq_prepare_fail_desc rollback_second;
        gq_bad_pack_desc bad_pack;
        gq_counting_tx_desc first_concurrent;
        gq_counting_tx_desc second_concurrent;
        mailbox_tx_desc capacity_fill_descs[26];
        gq_counting_tx_desc blocked_pair_descs[2];
        gq_counting_tx_desc later_small_desc;
        gq_counting_tx_desc duplicate_within_batch;
        gq_host_access_catcher host_access_catcher;
        gq_pack_size_catcher pack_size_catcher;
        gq_request first_request;
        gq_request second_request;
        gq_response first_response;
        gq_response second_response;
        gq_request blocked_pair_request;
        gq_request later_small_request;
        gq_response blocked_pair_response;
        gq_response later_small_response;
        int unsigned publish_before;
        bit blocked_pair_returned;
        bit later_small_returned;
        bit first_progress_seen;
        bit blocked_pair_committed;
        bit later_small_committed;
        bit first_returned;
        bit second_returned;
        bit probe_returned;
        bit locks_available;
        byte owned_data[];
        gq_request validation_request;
        gq_response validation_response;
        gq_request scale_request;
        gq_response scale_response;

        phase.raise_objection(this);
        env_cfg.wait_ready();
        failure_engine.initialize();
        validation_engine.initialize();

        component_handle = uvm_root::get().find("uvm_test_top.env.tx_7.sequencer");
        if (!$cast(sequencer, component_handle))
            `uvm_fatal("SUBMIT_PATH", "could not find typed TX sequencer")
        component_handle = uvm_root::get().find("uvm_test_top.env.tx_7.engine");
        if (!$cast(engine, component_handle))
            `uvm_fatal("SUBMIT_PATH", "could not find TX engine")

        single_desc = make_tx("single_desc", 0);
        single_desc.buf_len = 16;
        tx_sequence = mailbox_tx_sequence::type_id::create("single_sequence");
        tx_sequence.add_desc(single_desc);
        tx_sequence.start(sequencer);
        if (tx_sequence.response == null || tx_sequence.response.status != GQ_OK ||
            tx_sequence.response.committed_count != 1)
            `uvm_fatal("SUBMIT_SINGLE", "single submit response is incorrect")
        if (engine.head_seq() != 0 || engine.tail_seq() != 1 ||
            engine.outstanding_count() != 1 || engine.get_outstanding(0) != single_desc)
            `uvm_fatal("SUBMIT_SINGLE", "single submit engine state is incorrect")
        if (adapter.publish_calls != 1 || adapter.published_tails["tx_7"].size() != 1 ||
            adapter.published_tails["tx_7"][0] != ptr_codec.encode_publish(0, 1, 32))
            `uvm_fatal("SUBMIT_SINGLE", "single submit publish is incorrect")
        check_tx_slot(engine, 0, single_desc);

        request = gq_request::type_id::create("already_outstanding_request");
        request.add_desc(single_desc);
        response = gq_response::type_id::create("already_outstanding_response");
        publish_before = adapter.publish_calls;
        engine.submit_batch(request, response);
        expect_resource_error("already outstanding descriptor", response);
        host_access_catcher = new("host_access_catcher");
        uvm_report_cb::add(null, host_access_catcher);
        mem.read_mem(single_desc.buf_addr, single_desc.buf_len, owned_data,
                     `__FILE__, `__LINE__);
        uvm_report_cb::delete(null, host_access_catcher);
        if (host_access_catcher.caught_host_fatal || owned_data.size() != single_desc.buf_len)
            `uvm_fatal("SUBMIT_DUP_OWNER", "duplicate rejection released outstanding ownership")
        foreach (owned_data[i]) begin
            if (owned_data[i] !== single_desc.external_data[i])
                `uvm_fatal("SUBMIT_DUP_OWNER", "outstanding buffer contents changed")
        end
        if (engine.tail_seq() != 1 || engine.outstanding_count() != 1 ||
            engine.get_outstanding(0) != single_desc || adapter.publish_calls != publish_before)
            `uvm_fatal("SUBMIT_DUP_OWNER", "already-outstanding rejection changed state")

        duplicate_within_batch =
            gq_counting_tx_desc::type_id::create("duplicate_within_batch");
        duplicate_within_batch.buf_len = 16;
        request = gq_request::type_id::create("duplicate_within_request");
        request.add_desc(duplicate_within_batch);
        request.add_desc(duplicate_within_batch);
        response = gq_response::type_id::create("duplicate_within_response");
        failure_engine.submit_batch(request, response);
        expect_resource_error("duplicate within batch", response);
        if (duplicate_within_batch.prepare_calls != 0 ||
            failure_engine.tail_seq() != 0 || failure_engine.outstanding_count() != 0 ||
            failure_adapter.publish_calls != 0)
            `uvm_fatal("SUBMIT_DUP_BATCH", "within-batch duplicate was prepared or committed")

        for (int unsigned i = 0; i < 3; i++)
            batch_descs[i] = make_tx($sformatf("batch_desc_%0d", i), i + 1);
        tx_sequence = mailbox_tx_sequence::type_id::create("batch_sequence");
        foreach (batch_descs[i])
            tx_sequence.add_desc(batch_descs[i]);
        tx_sequence.start(sequencer);
        if (tx_sequence.response == null || tx_sequence.response.status != GQ_OK ||
            tx_sequence.response.committed_count != 3)
            `uvm_fatal("SUBMIT_BATCH", "batch submit response is incorrect")
        if (engine.tail_seq() != 4 || engine.outstanding_count() != 4)
            `uvm_fatal("SUBMIT_BATCH", "batch submit engine state is incorrect")
        if (adapter.publish_calls != 2 || adapter.published_tails["tx_7"].size() != 2 ||
            adapter.published_tails["tx_7"][1] != ptr_codec.encode_publish(1, 4, 32))
            `uvm_fatal("SUBMIT_BATCH", "batch was not published exactly once")
        foreach (batch_descs[i]) begin
            if (engine.get_outstanding(i + 1) != batch_descs[i])
                `uvm_fatal("SUBMIT_BATCH", $sformatf("missing outstanding slot %0d", i + 1))
            check_tx_slot(engine, i + 1, batch_descs[i]);
        end

        first_concurrent = gq_counting_tx_desc::type_id::create("first_concurrent");
        first_concurrent.srcid = 16'h4401;
        second_concurrent = gq_counting_tx_desc::type_id::create("second_concurrent");
        second_concurrent.srcid = 16'h4402;
        first_request = gq_request::type_id::create("first_concurrent_request");
        first_request.add_desc(first_concurrent);
        second_request = gq_request::type_id::create("second_concurrent_request");
        second_request.add_desc(second_concurrent);
        first_response = gq_response::type_id::create("first_concurrent_response");
        second_response = gq_response::type_id::create("second_concurrent_response");
        adapter.publish_delay = 10ns;
        adapter.publish_entered.reset();
        first_returned = 0;
        second_returned = 0;
        probe_returned = 0;
        fork : delayed_first_submit
            begin
                engine.submit_batch(first_request, first_response);
                first_returned = 1;
            end
        join_none
        adapter.publish_entered.wait_on();
        if (engine.tail_seq() != 5 || first_response.status == GQ_OK)
            `uvm_fatal("SUBMIT_DELAY", "state/response timing during publish is incorrect")
        engine.probe_publish_locks_for_test(locks_available);
        if (!locks_available)
            `uvm_fatal("SUBMIT_PUBLISH_LOCK",
                       "external publish retained an engine submission semaphore")
        fork : state_lock_probe
            begin
                engine.probe_state_lock_for_test();
                probe_returned = 1;
            end
        join_none
        fork : delayed_second_submit
            begin
                engine.submit_batch(second_request, second_response);
                second_returned = 1;
            end
        join_none
        #1ns;
        if (!probe_returned)
            `uvm_fatal("SUBMIT_LOCK", "state lock was held across delayed publish")
        if (second_concurrent.prepare_calls != 0 || second_returned)
            `uvm_fatal("SUBMIT_PUBLISH_ORDER",
                       "later submit overtook the active publish")
        wait (first_returned && second_returned);
        if (first_response.status != GQ_OK || second_response.status != GQ_OK ||
            engine.tail_seq() != 6 || engine.outstanding_count() != 6)
            `uvm_fatal("SUBMIT_SERIAL", "concurrent submit responses/state are incorrect")
        if (first_concurrent.prepare_calls != 1 || second_concurrent.prepare_calls != 1 ||
            adapter.publish_calls != 4 ||
            adapter.published_tails["tx_7"][2] != ptr_codec.encode_publish(4, 5, 32) ||
            adapter.published_tails["tx_7"][3] != ptr_codec.encode_publish(5, 6, 32))
            `uvm_fatal("SUBMIT_SERIAL", "concurrent publish order is incorrect")
        adapter.publish_delay = 0;

        rollback_first = make_tx("rollback_first", 10);
        rollback_first.buf_len = 16;
        rollback_second = gq_prepare_fail_desc::type_id::create("rollback_second");
        request = gq_request::type_id::create("rollback_request");
        request.add_desc(rollback_first);
        request.add_desc(rollback_second);
        response = gq_response::type_id::create("rollback_response");
        failure_engine.submit_batch(request, response);
        expect_resource_error("prepare rollback", response);
        if (failure_engine.tail_seq() != 0 || failure_engine.outstanding_count() != 0 ||
            failure_adapter.publish_calls != 0)
            `uvm_fatal("SUBMIT_ROLLBACK", "prepare failure changed committed state")

        bad_pack = gq_bad_pack_desc::type_id::create("bad_pack");
        request = gq_request::type_id::create("bad_pack_request");
        request.add_desc(bad_pack);
        response = gq_response::type_id::create("bad_pack_response");
        pack_size_catcher = new("pack_size_catcher");
        uvm_report_cb::add(null, pack_size_catcher);
        failure_engine.submit_batch(request, response);
        uvm_report_cb::delete(null, pack_size_catcher);
        if (!pack_size_catcher.caught_pack_fatal ||
            !uvm_is_match("*role=TX*queue_id=8*logical_seq=0*expected=64*actual=63*",
                          pack_size_catcher.caught_message))
            `uvm_fatal("SUBMIT_PACK", "pack-size fatal or diagnostic context is missing")
        if (failure_engine.tail_seq() != 0 || failure_engine.outstanding_count() != 0 ||
            failure_adapter.publish_calls != 0)
            `uvm_fatal("SUBMIT_PACK", "bad pack changed committed state")

        request = gq_request::type_id::create("empty_request");
        response = gq_response::type_id::create("empty_response");
        failure_engine.submit_batch(request, response);
        expect_resource_error("empty batch", response);

        request = gq_request::type_id::create("null_request");
        request.add_desc(null);
        response = gq_response::type_id::create("null_response");
        failure_engine.submit_batch(request, response);
        expect_resource_error("null descriptor", response);

        request = gq_request::type_id::create("oversize_request");
        for (int unsigned i = 0; i < 33; i++)
            request.add_desc(make_tx($sformatf("oversize_%0d", i), i));
        response = gq_response::type_id::create("oversize_response");
        failure_engine.submit_batch(request, response);
        expect_resource_error("batch larger than depth", response);

        request = gq_request::type_id::create("capacity_fill_request");
        for (int unsigned i = 0; i < 26; i++) begin
            capacity_fill_descs[i] = make_tx(
                $sformatf("capacity_fill_%0d", i), i + 20);
            request.add_desc(capacity_fill_descs[i]);
        end
        response = gq_response::type_id::create("capacity_fill_response");
        engine.submit_batch(request, response);
        if (response.status != GQ_OK || response.committed_count != 26 ||
            engine.head_seq() != 0 || engine.tail_seq() != 32 ||
            engine.outstanding_count() != 32)
            `uvm_fatal("SUBMIT_CAPACITY", "queue fill did not reach depth")

        publish_before = adapter.publish_calls;
        blocked_pair_request = gq_request::type_id::create(
            "blocked_pair_request");
        for (int unsigned i = 0; i < 2; i++) begin
            blocked_pair_descs[i] = gq_counting_tx_desc::type_id::create(
                $sformatf("blocked_pair_%0d", i));
            blocked_pair_descs[i].srcid = 16'h5500 + i;
            blocked_pair_request.add_desc(blocked_pair_descs[i]);
        end
        blocked_pair_response = gq_response::type_id::create(
            "blocked_pair_response");
        blocked_pair_returned = 0;
        fork : blocked_pair_submit
            begin
                engine.submit_batch(blocked_pair_request,
                                    blocked_pair_response);
                blocked_pair_returned = 1;
            end
        join_none
        #5ns;
        if (blocked_pair_returned)
            `uvm_fatal("SUBMIT_CAPACITY", "whole batch did not wait for capacity")
        if (adapter.publish_calls != publish_before || engine.tail_seq() != 32)
            `uvm_fatal("SUBMIT_CAPACITY", "blocked batch changed queue state")
        if (blocked_pair_descs[0].prepare_calls != 0 ||
            blocked_pair_descs[1].prepare_calls != 0)
            `uvm_fatal("SUBMIT_CAPACITY", "blocked batch prepared a descriptor")

        later_small_desc = gq_counting_tx_desc::type_id::create(
            "later_small_desc");
        later_small_desc.srcid = 16'h6600;
        later_small_request = gq_request::type_id::create(
            "later_small_request");
        later_small_request.add_desc(later_small_desc);
        later_small_response = gq_response::type_id::create(
            "later_small_response");
        later_small_returned = 0;
        fork : later_small_submit
            begin
                engine.submit_batch(later_small_request,
                                    later_small_response);
                later_small_returned = 1;
            end
        join_none
        #5ns;
        if (later_small_returned || later_small_desc.prepare_calls != 0)
            `uvm_fatal("SUBMIT_ORDER", "later small batch bypassed a full queue")

        dut.complete_slot(engine, 0, 32, 64);
        first_progress_seen = 0;
        for (int unsigned poll = 0;
             poll < 200 && !first_progress_seen; poll++) begin
            #1ns;
            first_progress_seen = engine.head_seq() == 1;
        end
        if (!first_progress_seen)
            `uvm_fatal("SUBMIT_PROGRESS", "completion worker did not retire the first item")
        #5ns;
        if (blocked_pair_returned || later_small_returned ||
            blocked_pair_descs[0].prepare_calls != 0 ||
            blocked_pair_descs[1].prepare_calls != 0 ||
            later_small_desc.prepare_calls != 0 ||
            engine.tail_seq() != 32 || adapter.publish_calls != publish_before)
            `uvm_fatal("SUBMIT_ORDER",
                       "one free slot let a waiting request overtake or prepare")

        dut.complete_slot(engine, 1, 32, 64);
        blocked_pair_committed = 0;
        for (int unsigned poll = 0;
             poll < 200 && !blocked_pair_committed; poll++) begin
            #1ns;
            blocked_pair_committed = blocked_pair_returned &&
                                     engine.head_seq() == 2 &&
                                     engine.tail_seq() == 34;
        end
        if (!blocked_pair_committed)
            `uvm_fatal("SUBMIT_PROGRESS_DEADLOCK",
                       "second completion could not release the blocked batch")
        if (blocked_pair_response.status != GQ_OK ||
            blocked_pair_response.committed_count != 2 ||
            later_small_returned || later_small_desc.prepare_calls != 0 ||
            engine.outstanding_count() != 32 ||
            engine.get_outstanding(32) != blocked_pair_descs[0] ||
            engine.get_outstanding(33) != blocked_pair_descs[1] ||
            adapter.publish_calls != publish_before + 1 ||
            adapter.published_tails["tx_7"][publish_before] !=
                ptr_codec.encode_publish(32, 34, 32))
            `uvm_fatal("SUBMIT_PROGRESS",
                       "blocked pair response/state/publish order is incorrect")
        check_tx_slot(engine, 32, blocked_pair_descs[0]);
        check_tx_slot(engine, 33, blocked_pair_descs[1]);

        dut.complete_slot(engine, 2, 32, 64);
        later_small_committed = 0;
        for (int unsigned poll = 0;
             poll < 200 && !later_small_committed; poll++) begin
            #1ns;
            later_small_committed = later_small_returned &&
                                    engine.head_seq() == 3 &&
                                    engine.tail_seq() == 35;
        end
        if (!later_small_committed)
            `uvm_fatal("SUBMIT_ORDER_TIMEOUT",
                       "later small batch did not run after the earlier batch")
        if (later_small_response.status != GQ_OK ||
            later_small_response.committed_count != 1 ||
            engine.outstanding_count() != 32 ||
            engine.get_outstanding(34) != later_small_desc ||
            adapter.publish_calls != publish_before + 2 ||
            adapter.published_tails["tx_7"][publish_before + 1] !=
                ptr_codec.encode_publish(34, 35, 32))
            `uvm_fatal("SUBMIT_ORDER",
                       "later small batch response/state/publish is incorrect")
        check_tx_slot(engine, 34, later_small_desc);

        validation_request = gq_request::type_id::create("validation_request");
        for (int unsigned i = 0; i < 256; i++)
            validation_request.add_desc(make_tx($sformatf("validation_%0d", i), i));
        validation_response = gq_response::type_id::create("validation_response");
        validation_engine.reset_membership_validation_steps();
        validation_engine.submit_batch(validation_request, validation_response);
        if (validation_response.status != GQ_OK ||
            validation_response.committed_count != 256 ||
            validation_engine.membership_validation_steps != 256)
            `uvm_fatal("SUBMIT_MEMBERSHIP", $sformatf(
                "unique batch used %0d membership steps expected 256",
                validation_engine.membership_validation_steps))
        if (validation_engine.tail_seq() != 256 ||
            validation_engine.outstanding_count() != 256 ||
            validation_adapter.publish_calls != 1)
            `uvm_fatal("SUBMIT_MEMBERSHIP", "unique batch commit state is incorrect")

        validation_engine.reset_outstanding_audit_steps();
        for (int unsigned i = 0; i < 64; i++) begin
            scale_request = gq_request::type_id::create(
                $sformatf("scale_request_%0d", i));
            scale_request.add_desc(make_tx($sformatf("scale_desc_%0d", i),
                                           i + 256));
            scale_response = gq_response::type_id::create(
                $sformatf("scale_response_%0d", i));
            validation_engine.submit_batch(scale_request, scale_response);
            if (scale_response.status != GQ_OK ||
                scale_response.committed_count != 1)
                `uvm_fatal("SUBMIT_INVARIANT_SCALE",
                           $sformatf("single submit %0d failed", i))
        end
        if (validation_engine.outstanding_audit_steps != 0)
            `uvm_fatal("SUBMIT_INVARIANT_SCALE", $sformatf(
                "regular submit performed %0d full-audit steps expected 0",
                validation_engine.outstanding_audit_steps))
        validation_engine.audit_state_invariants_for_test("explicit test audit");
        if (validation_engine.outstanding_audit_steps != 320)
            `uvm_fatal("SUBMIT_INVARIANT_SCALE", $sformatf(
                "explicit audit used %0d steps expected 320",
                validation_engine.outstanding_audit_steps))
        if (validation_engine.tail_seq() != 320 ||
            validation_engine.outstanding_count() != 320 ||
            validation_adapter.publish_calls != 65)
            `uvm_fatal("SUBMIT_INVARIANT_SCALE",
                       "repeated single-submit state is incorrect")

        failure_engine.cleanup();
        validation_engine.cleanup();
        env.cleanup();
        failure_mem.leak_check(`__FILE__, `__LINE__);
        validation_mem.leak_check(`__FILE__, `__LINE__);
        mem.leak_check(`__FILE__, `__LINE__);
        phase.drop_objection(this);
    endtask
endclass

`endif
