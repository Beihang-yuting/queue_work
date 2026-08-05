`ifndef GQ_SUBMIT_TEST_SVH
`define GQ_SUBMIT_TEST_SVH

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

class gq_submit_test extends uvm_test;
    `uvm_component_utils(gq_submit_test)

    host_mem_manager     mem;
    host_mem_manager     failure_mem;
    gq_test_ptr_codec    ptr_codec;
    mailbox_mock_adapter adapter;
    mailbox_mock_adapter failure_adapter;
    mailbox_env_cfg      env_cfg;
    mailbox_env          env;
    gq_queue_cfg         failure_cfg;
    gq_queue_engine      failure_engine;

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
        cfg.poll_interval      = 10ns;
        cfg.completion_timeout = 1us;
        cfg.ptr_codec          = ptr_codec;
        cfg.completion_source  = null;
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
        if (decoded.flags[0] !== gq_phase(seq, 32) ||
            decoded.flags[1] !== !gq_phase(seq, 32))
            `uvm_fatal("SUBMIT_PHASE", $sformatf("slot %0d phase mismatch", seq))
    endfunction

    function void expect_resource_error(string check_name, gq_response response);
        if (response == null || response.status != GQ_RESOURCE_ERROR ||
            response.committed_count != 0)
            `uvm_fatal("SUBMIT_REJECT", {check_name, " did not return resource error"})
    endfunction

    function void build_phase(uvm_phase phase);
        string reason;

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_1000_0000,
                        64'h0000_0001_10ff_ffff, MODE_LINEAR, 16);
        failure_mem = new("failure_mem");
        failure_mem.init_region(64'h0000_0001_2000_0000,
                                64'h0000_0001_20ff_ffff, MODE_LINEAR, 16);
        ptr_codec      = gq_test_ptr_codec::type_id::create("ptr_codec");
        adapter        = mailbox_mock_adapter::type_id::create("adapter");
        failure_adapter = mailbox_mock_adapter::type_id::create("failure_adapter");

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
    endfunction

    task run_phase(uvm_phase phase);
        uvm_component component_handle;
        gq_sequencer sequencer;
        gq_queue_engine engine;
        mailbox_tx_sequence tx_sequence;
        mailbox_tx_desc single_desc;
        mailbox_tx_desc batch_descs[3];
        gq_request request;
        gq_response response;
        mailbox_tx_desc rollback_first;
        gq_prepare_fail_desc rollback_second;
        gq_bad_pack_desc bad_pack;
        int unsigned publish_before;
        bit blocked_returned;

        phase.raise_objection(this);
        env_cfg.wait_ready();
        failure_engine.initialize();

        component_handle = uvm_root::get().find("uvm_test_top.env.tx_7.sequencer");
        if (!$cast(sequencer, component_handle))
            `uvm_fatal("SUBMIT_PATH", "could not find typed TX sequencer")
        component_handle = uvm_root::get().find("uvm_test_top.env.tx_7.engine");
        if (!$cast(engine, component_handle))
            `uvm_fatal("SUBMIT_PATH", "could not find TX engine")

        single_desc = make_tx("single_desc", 0);
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
        failure_engine.submit_batch(request, response);
        expect_resource_error("bad packed size", response);
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

        request = gq_request::type_id::create("blocked_request");
        for (int unsigned i = 0; i < 29; i++)
            request.add_desc(make_tx($sformatf("blocked_%0d", i), i));
        response = gq_response::type_id::create("blocked_response");
        publish_before = adapter.publish_calls;
        blocked_returned = 0;
        fork : bounded_full_submit
            begin
                engine.submit_batch(request, response);
                blocked_returned = 1;
            end
        join_none
        #5ns;
        if (blocked_returned)
            `uvm_fatal("SUBMIT_CAPACITY", "whole batch did not wait for capacity")
        if (adapter.publish_calls != publish_before || engine.tail_seq() != 4)
            `uvm_fatal("SUBMIT_CAPACITY", "blocked batch changed queue state")
        disable bounded_full_submit;

        failure_engine.cleanup();
        env.cleanup();
        failure_mem.leak_check(`__FILE__, `__LINE__);
        mem.leak_check(`__FILE__, `__LINE__);
        phase.drop_objection(this);
    endtask
endclass

`endif
