// tb/tests/gq_refill_test.sv: UVM 测试 gq_refill_test：验证对应队列组件的定向行为和接口契约。
`ifndef GQ_REFILL_TEST_SV
`define GQ_REFILL_TEST_SV

class gq_refill_spy_mem extends host_mem_manager;
    int unsigned event_serial;
    int unsigned alloc_order[gq_addr_t];
    int unsigned free_order[gq_addr_t];

    function new(string name = "gq_refill_spy_mem");
        super.new(name);
        event_serial = 0;
    endfunction

    virtual function bit [63:0] alloc(
        int unsigned size,
        int unsigned align = 1,
        string file = "",
        int line = 0);
        bit [63:0] addr;

        addr = super.alloc(size, align, file, line);
        if (addr != '1) begin
            event_serial++;
            alloc_order[addr] = event_serial;
        end
        return addr;
    endfunction

    virtual function void free(
        bit [63:0] addr,
        string file = "",
        int line = 0);
        event_serial++;
        free_order[addr] = event_serial;
        super.free(addr, file, line);
    endfunction
endclass

class gq_refill_prepare_fail_desc extends mailbox_rx_desc;
    `uvm_object_utils(gq_refill_prepare_fail_desc)

    function new(string name = "gq_refill_prepare_fail_desc");
        super.new(name);
    endfunction

    virtual function bit prepare();
        void'(super.prepare());
        return 0;
    endfunction
endclass

class gq_deterministic_refill_profile extends mailbox_refill_profile;
    `uvm_object_utils(gq_deterministic_refill_profile)

    bit [31:0] base_len;
    longint fail_create_seq;
    longint fail_prepare_seq;

    function new(string name = "gq_deterministic_refill_profile");
        super.new(name);
        base_len         = 64;
        fail_create_seq  = -1;
        fail_prepare_seq = -1;
    endfunction

    virtual function bit [31:0] choose_buf_len(
        gq_logical_seq_t logical_seq);
        return base_len + logical_seq;
    endfunction

    virtual function gq_desc_base create_desc(
        int unsigned queue_id, gq_logical_seq_t logical_seq);
        mailbox_rx_desc desc;

        if (fail_create_seq >= 0 &&
            logical_seq == gq_logical_seq_t'(fail_create_seq))
            return null;
        if (fail_prepare_seq >= 0 &&
            logical_seq == gq_logical_seq_t'(fail_prepare_seq))
            desc = gq_refill_prepare_fail_desc::type_id::create(
                $sformatf("rx_%0d_prepare_fail_%0d", queue_id, logical_seq));
        else
            desc = mailbox_rx_desc::type_id::create(
                $sformatf("rx_%0d_desc_%0d", queue_id, logical_seq));
        desc.buf_len = choose_buf_len(logical_seq);
        return desc;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        gq_deterministic_refill_profile rhs_profile;

        super.do_copy(rhs);
        if (!$cast(rhs_profile, rhs))
            `uvm_fatal("REFILL_TEST_COPY",
                       "source is not a deterministic refill profile")
        base_len         = rhs_profile.base_len;
        fail_create_seq  = rhs_profile.fail_create_seq;
        fail_prepare_seq = rhs_profile.fail_prepare_seq;
    endfunction
endclass

class gq_refill_error_catcher extends uvm_report_catcher;
    `uvm_object_utils(gq_refill_error_catcher)

    int unsigned caught_refill_errors;

    function new(string name = "gq_refill_error_catcher");
        super.new(name);
        caught_refill_errors = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR && get_id() == "GQ_REFILL") begin
            caught_refill_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class gq_refill_publish_gate_adapter extends mailbox_mock_adapter;
    `uvm_object_utils(gq_refill_publish_gate_adapter)

    bit gate_publishes;
    string gated_key;
    int unsigned gated_entries;
    gq_raw_ptr_t gated_tails[$];
    uvm_event allow_publish_return;

    function new(string name = "gq_refill_publish_gate_adapter");
        super.new(name);
        gate_publishes = 0;
        gated_key = "";
        gated_entries = 0;
        allow_publish_return = new({name, "_allow_publish_return"});
    endfunction

    virtual task publish(
        gq_role_e role,
        int unsigned queue_id,
        gq_raw_ptr_t raw_tail);
        string key;

        key = gq_queue_key(role, queue_id);
        if (gate_publishes && key == gated_key) begin
            gated_entries++;
            gated_tails.push_back(raw_tail);
            allow_publish_return.wait_on();
            allow_publish_return.reset();
        end
        super.publish(role, queue_id, raw_tail);
    endtask
endclass

class gq_refill_test extends uvm_test;
    `uvm_component_utils(gq_refill_test)

    gq_refill_spy_mem   mem;
    gq_test_ptr_codec   ptr_codec;
    mailbox_mock_adapter adapter;
    mailbox_mock_dut    dut;
    mailbox_env_cfg     env_cfg;
    mailbox_env         env;
    gq_refill_spy_mem   race_mem;
    gq_refill_publish_gate_adapter race_adapter;
    mailbox_mock_dut    race_dut;
    gq_queue_cfg        race_cfg;
    gq_queue_engine     race_engine;

    function new(string name = "gq_refill_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function gq_queue_engine find_engine(string path);
        uvm_component component_handle;
        gq_queue_engine engine;

        component_handle = uvm_root::get().find(path);
        if (!$cast(engine, component_handle))
            `uvm_fatal("REFILL_PATH", {"could not find engine ", path})
        return engine;
    endfunction

    function gq_sequencer find_sequencer(string path);
        uvm_component component_handle;
        gq_sequencer sequencer;

        component_handle = uvm_root::get().find(path);
        if (!$cast(sequencer, component_handle))
            `uvm_fatal("REFILL_PATH", {"could not find sequencer ", path})
        return sequencer;
    endfunction

    task wait_for_gated_publish(int unsigned expected);
        for (int unsigned poll = 0; poll < 200; poll++) begin
            #1ns;
            if (race_adapter.gated_entries == expected)
                return;
        end
        `uvm_fatal("REFILL_PUBLISH_REVALIDATE", $sformatf(
            "gated publish count did not reach %0d", expected))
    endtask

    function void expect_resource_error(string check_name,
                                        gq_response response);
        if (response == null || response.status != GQ_RESOURCE_ERROR ||
            response.committed_count != 0)
            `uvm_fatal("REFILL_REJECT",
                       {check_name, " did not return a resource error"})
    endfunction

    function void check_profile_validation();
        mailbox_refill_profile profile;
        gq_deterministic_refill_profile clone_source;
        gq_deterministic_refill_profile cloned_profile;
        gq_refill_profile cloned_base;
        string reason;
        bit [31:0] chosen_len;

        profile = mailbox_refill_profile::type_id::create("valid_profile");
        profile.initial_post_count = 32;
        profile.low_watermark      = 0;
        profile.high_watermark     = 32;
        profile.min_buf_len        = 4;
        profile.max_buf_len        = 8;
        if (!profile.validate(32, reason))
            `uvm_fatal("REFILL_VALIDATE", {"legal boundary failed: ", reason})
        repeat (32) begin
            chosen_len = profile.choose_buf_len(0);
            if (chosen_len < 4 || chosen_len > 8)
                `uvm_fatal("REFILL_RANDOM", "default provider chose out-of-range length")
        end

        profile.low_watermark  = 7;
        profile.high_watermark = 7;
        if (profile.validate(32, reason) ||
            !uvm_is_match("*low watermark*", reason))
            `uvm_fatal("REFILL_VALIDATE", "low >= high was accepted")
        profile.low_watermark  = 3;
        profile.high_watermark = 33;
        if (profile.validate(32, reason) ||
            !uvm_is_match("*queue depth*", reason))
            `uvm_fatal("REFILL_VALIDATE", "high > depth was accepted")
        profile.high_watermark     = 7;
        profile.initial_post_count = 33;
        if (profile.validate(32, reason) ||
            !uvm_is_match("*initial post count*", reason))
            `uvm_fatal("REFILL_VALIDATE", "initial > depth was accepted")
        profile.initial_post_count = 8;
        profile.min_buf_len        = 0;
        profile.max_buf_len        = 8;
        if (profile.validate(32, reason) ||
            !uvm_is_match("*positive*", reason))
            `uvm_fatal("REFILL_VALIDATE", "zero minimum length was accepted")
        profile.min_buf_len = 9;
        profile.max_buf_len = 8;
        if (profile.validate(32, reason) ||
            !uvm_is_match("*exceeds maximum*", reason))
            `uvm_fatal("REFILL_VALIDATE", "min > max was accepted")
        profile.min_buf_len = 1;
        profile.max_buf_len = 64'h0000_0001_0000_0000;
        if (profile.validate(32, reason) ||
            !uvm_is_match("*32-bit*", reason))
            `uvm_fatal("REFILL_VALIDATE", "non-32-bit length was accepted")

        clone_source = gq_deterministic_refill_profile::type_id::create(
            "clone_source");
        clone_source.initial_post_count  = 8;
        clone_source.low_watermark       = 3;
        clone_source.high_watermark      = 7;
        clone_source.restart_after_reset = 1;
        clone_source.min_buf_len         = 16;
        clone_source.max_buf_len         = 512;
        clone_source.base_len            = 77;
        clone_source.fail_create_seq     = 19;
        cloned_base = clone_source.clone_profile();
        if (!$cast(cloned_profile, cloned_base) ||
            cloned_profile == clone_source ||
            cloned_profile.initial_post_count != 8 ||
            cloned_profile.low_watermark != 3 ||
            cloned_profile.high_watermark != 7 ||
            !cloned_profile.restart_after_reset ||
            cloned_profile.min_buf_len != 16 ||
            cloned_profile.max_buf_len != 512 ||
            cloned_profile.base_len != 77 ||
            cloned_profile.fail_create_seq != 19)
            `uvm_fatal("REFILL_CLONE", "profile clone was not a deep value copy")
        clone_source.high_watermark  = 31;
        clone_source.base_len        = 900;
        clone_source.fail_create_seq = -1;
        if (cloned_profile.high_watermark != 7 ||
            cloned_profile.base_len != 77 ||
            cloned_profile.fail_create_seq != 19)
            `uvm_fatal("REFILL_CLONE", "profile clone followed caller mutation")
    endfunction

    function void build_phase(uvm_phase phase);
        string reason;

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_5000_0000,
                        64'h0000_0001_50ff_ffff, MODE_LINEAR, 16);
        ptr_codec = gq_test_ptr_codec::type_id::create("ptr_codec");
        adapter = mailbox_mock_adapter::type_id::create("adapter");
        dut = mailbox_mock_dut::type_id::create("dut");
        dut.mem     = mem;
        dut.adapter = adapter;
        env_cfg = mailbox_env_cfg::type_id::create("env_cfg");
        env_cfg.mem       = mem;
        env_cfg.adapter   = adapter;
        env_cfg.ptr_codec = ptr_codec;
        if (!env_cfg.add_rx(5, 32, reason) ||
            !env_cfg.add_tx(6, 32, reason) ||
            !env_cfg.add_rx(7, 32, reason) ||
            !env_cfg.add_rx(8, 32, reason) ||
            !env_cfg.add_rx(9, 32, reason))
            `uvm_fatal("REFILL_CFG", reason)
        uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", env_cfg);
        env = mailbox_env::type_id::create("env", this);

        race_mem = new("race_mem");
        race_mem.init_region(64'h0000_0001_5100_0000,
                             64'h0000_0001_51ff_ffff, MODE_LINEAR, 16);
        race_adapter = gq_refill_publish_gate_adapter::type_id::create(
            "race_adapter");
        race_dut = mailbox_mock_dut::type_id::create("race_dut");
        race_dut.mem = race_mem;
        race_dut.adapter = race_adapter;
        race_cfg = gq_queue_cfg::type_id::create("race_cfg");
        race_cfg.queue_id           = 10;
        race_cfg.role               = GQ_RX;
        race_cfg.depth              = 32;
        race_cfg.desc_size          = 16;
        race_cfg.alignment          = 64;
        race_cfg.status_area_size   = 0;
        race_cfg.wait_mode          = GQ_POLL;
        race_cfg.poll_min_interval  = 1ns;
        race_cfg.poll_max_interval  = 1ns;
        race_cfg.completion_timeout = 20ns;
        race_cfg.ptr_codec          = ptr_codec;
        race_cfg.completion_source  = mailbox_completion::type_id::create(
            "race_completion");
        uvm_config_db#(gq_queue_cfg)::set(
            this, "race_engine", "cfg", race_cfg);
        uvm_config_db#(host_mem_api)::set(
            this, "race_engine", "mem", race_mem);
        uvm_config_db#(gq_hw_adapter)::set(
            this, "race_engine", "adapter", race_adapter);
        race_engine = gq_queue_engine::type_id::create("race_engine", this);
    endfunction

    task run_phase(uvm_phase phase);
        gq_sequencer rx_sequencer;
        gq_sequencer tx_sequencer;
        gq_sequencer zero_sequencer;
        gq_sequencer create_fail_sequencer;
        gq_sequencer prepare_fail_sequencer;
        gq_queue_engine rx_engine;
        gq_queue_engine tx_engine;
        gq_queue_engine zero_engine;
        gq_queue_engine create_fail_engine;
        gq_queue_engine prepare_fail_engine;
        gq_deterministic_refill_profile profile;
        gq_deterministic_refill_profile zero_profile;
        gq_deterministic_refill_profile fail_profile;
        gq_deterministic_refill_profile recovery_profile;
        mailbox_rx_start_sequence start_sequence;
        mailbox_rx_start_sequence duplicate_sequence;
        mailbox_rx_start_sequence tx_start_sequence;
        mailbox_rx_start_sequence zero_sequence;
        mailbox_rx_start_sequence fail_sequence;
        mailbox_rx_start_sequence recovery_sequence;
        mailbox_rx_start_sequence prepare_fail_sequence;
        mailbox_rx_desc desc;
        mailbox_rx_desc new_desc;
        mailbox_rx_desc old_descs[5];
        gq_addr_t old_buf_addrs[5];
        gq_refill_error_catcher refill_catcher;
        int unsigned latest_old_free;
        int unsigned earliest_new_alloc;
        int unsigned events_before_start;
        bit refill_seen;
        bit failure_seen;
        gq_deterministic_refill_profile race_profile;
        gq_request race_start_request;
        gq_response race_start_response;
        gq_request race_submit_a_request;
        gq_response race_submit_a_response;
        gq_request race_submit_b_request;
        gq_response race_submit_b_response;
        mailbox_rx_desc race_submit_a_desc;
        mailbox_rx_desc race_submit_b_desc;
        mailbox_rx_desc race_refill_desc;
        bit race_submit_a_returned;
        bit race_submit_b_returned;
        bit race_drain_returned;

        phase.raise_objection(this);
        env_cfg.wait_ready();
        check_profile_validation();
        rx_sequencer = find_sequencer("uvm_test_top.env.rx_5.sequencer");
        tx_sequencer = find_sequencer("uvm_test_top.env.tx_6.sequencer");
        zero_sequencer = find_sequencer("uvm_test_top.env.rx_7.sequencer");
        create_fail_sequencer = find_sequencer(
            "uvm_test_top.env.rx_8.sequencer");
        prepare_fail_sequencer = find_sequencer(
            "uvm_test_top.env.rx_9.sequencer");
        rx_engine = find_engine("uvm_test_top.env.rx_5.engine");
        tx_engine = find_engine("uvm_test_top.env.tx_6.engine");
        zero_engine = find_engine("uvm_test_top.env.rx_7.engine");
        create_fail_engine = find_engine("uvm_test_top.env.rx_8.engine");
        prepare_fail_engine = find_engine("uvm_test_top.env.rx_9.engine");

        profile = gq_deterministic_refill_profile::type_id::create("profile");
        profile.initial_post_count = 8;
        profile.low_watermark      = 3;
        profile.high_watermark     = 7;
        profile.fail_create_seq    = 12;

        tx_start_sequence = mailbox_rx_start_sequence::type_id::create(
            "tx_start_sequence");
        tx_start_sequence.set_refill_profile(profile);
        tx_start_sequence.start(tx_sequencer);
        expect_resource_error("TX RX-start", tx_start_sequence.response);
        if (tx_engine.tail_seq() != 0 || tx_engine.outstanding_count() != 0 ||
            adapter.publish_count["tx_6"] != 0)
            `uvm_fatal("REFILL_TX", "rejected TX start changed queue state")

        start_sequence = mailbox_rx_start_sequence::type_id::create(
            "start_sequence");
        start_sequence.set_refill_profile(profile);
        events_before_start = mem.event_serial;
        start_sequence.start(rx_sequencer);
        if (start_sequence.response == null ||
            start_sequence.response.status != GQ_OK ||
            start_sequence.response.committed_count != 8)
            `uvm_fatal("REFILL_START", "RX startup response is incorrect")
        if (rx_engine.head_seq() != 0 || rx_engine.tail_seq() != 8 ||
            rx_engine.outstanding_count() != 8)
            `uvm_fatal("REFILL_START", "RX startup state is incorrect")
        if (mem.event_serial != events_before_start + 8)
            `uvm_fatal("REFILL_START",
                       "RX startup did not allocate exactly eight buffers")
        if (adapter.publish_count["rx_5"] != 1 ||
            adapter.published_tails["rx_5"].size() != 1 ||
            adapter.published_tails["rx_5"][0] !=
                ptr_codec.encode_publish(0, 8, 32))
            `uvm_fatal("REFILL_START", "RX startup did not publish once")
        for (gq_logical_seq_t seq = 0; seq < 8; seq++) begin
            if (!$cast(desc, rx_engine.get_outstanding(seq)) ||
                desc.buf_len != 64 + seq || desc.buf_addr == '1)
                `uvm_fatal("REFILL_DESC", $sformatf(
                    "descriptor %0d is missing or has the wrong buffer", seq))
        end

        duplicate_sequence = mailbox_rx_start_sequence::type_id::create(
            "duplicate_sequence");
        duplicate_sequence.set_refill_profile(profile);
        duplicate_sequence.start(rx_sequencer);
        expect_resource_error("duplicate RX start", duplicate_sequence.response);
        if (rx_engine.tail_seq() != 8 || rx_engine.outstanding_count() != 8 ||
            adapter.publish_count["rx_5"] != 1)
            `uvm_fatal("REFILL_DUP", "duplicate start changed RX state")

        profile.initial_post_count = 0;
        profile.low_watermark      = 30;
        profile.high_watermark     = 31;
        profile.base_len           = 1000;
        profile.fail_create_seq    = -1;
        start_sequence.set_refill_profile(null);
        duplicate_sequence.set_refill_profile(null);
        profile = null;

        #35ns;
        if (rx_engine.head_seq() != 0 || rx_engine.tail_seq() != 8 ||
            rx_engine.outstanding_count() != 8 ||
            adapter.publish_count["rx_5"] != 1)
            `uvm_fatal("REFILL_PROGRESS",
                       "poll wake without DUT completion triggered refill")

        for (int unsigned i = 0; i < 5; i++) begin
            if (!$cast(old_descs[i], rx_engine.get_outstanding(i)))
                `uvm_fatal("REFILL_OLD", "missing initial descriptor")
            old_buf_addrs[i] = old_descs[i].buf_addr;
            dut.complete_slot(rx_engine, i, 32, 16);
        end
        refill_seen = 0;
        fork : refill_watchdog
            begin
                for (int unsigned poll = 0; poll < 200; poll++) begin
                    #1ns;
                    if (rx_engine.head_seq() == 5 &&
                        rx_engine.tail_seq() == 12)
                        refill_seen = 1;
                end
            end
        join
        if (!refill_seen)
            `uvm_fatal("REFILL_TIMEOUT", "DUT progress did not trigger refill")
        if (rx_engine.outstanding_count() != 7 ||
            adapter.publish_count["rx_5"] != 2 ||
            adapter.published_tails["rx_5"].size() != 2 ||
            adapter.published_tails["rx_5"][1] !=
                ptr_codec.encode_publish(8, 12, 32))
            `uvm_fatal("REFILL_WATERMARK",
                       "five completions did not publish four replacements once")

        latest_old_free    = 0;
        earliest_new_alloc = '1;
        for (int unsigned i = 0; i < 5; i++) begin
            if (!mem.free_order.exists(old_buf_addrs[i]))
                `uvm_fatal("REFILL_RELEASE", "completed buffer was not freed")
            if (mem.free_order[old_buf_addrs[i]] > latest_old_free)
                latest_old_free = mem.free_order[old_buf_addrs[i]];
        end
        for (gq_logical_seq_t seq = 8; seq < 12; seq++) begin
            if (!$cast(new_desc, rx_engine.get_outstanding(seq)) ||
                new_desc.buf_len != 64 + seq || new_desc.buf_addr == '1)
                `uvm_fatal("REFILL_CLONED_PROVIDER", $sformatf(
                    "replacement %0d did not use the cloned provider", seq))
            if (!mem.alloc_order.exists(new_desc.buf_addr))
                `uvm_fatal("REFILL_ALLOC", "replacement buffer was not allocated")
            if (mem.alloc_order[new_desc.buf_addr] < earliest_new_alloc)
                earliest_new_alloc = mem.alloc_order[new_desc.buf_addr];
        end
        if (latest_old_free >= earliest_new_alloc)
            `uvm_fatal("REFILL_ORDER",
                       "replacement allocation preceded an old-buffer free")

        #35ns;
        if (rx_engine.head_seq() != 5 || rx_engine.tail_seq() != 12 ||
            adapter.publish_count["rx_5"] != 2)
            `uvm_fatal("REFILL_ZERO",
                       "zero completion after refill caused another publish")

        refill_catcher = new("refill_catcher");
        uvm_report_cb::add(null, refill_catcher);
        for (gq_logical_seq_t seq = 5; seq < 9; seq++)
            dut.complete_slot(rx_engine, seq, 32, 16);
        failure_seen = 0;
        fork : failure_watchdog
            begin
                for (int unsigned poll = 0; poll < 200; poll++) begin
                    #1ns;
                    if (refill_catcher.caught_refill_errors == 1)
                        failure_seen = 1;
                end
            end
        join
        uvm_report_cb::delete(null, refill_catcher);
        if (!failure_seen || rx_engine.head_seq() != 9 ||
            rx_engine.tail_seq() != 12 ||
            rx_engine.outstanding_count() != 3 ||
            adapter.publish_count["rx_5"] != 2)
            `uvm_fatal("REFILL_FAILURE",
                       "refill creation failure corrupted retired state")

        zero_profile = gq_deterministic_refill_profile::type_id::create(
            "zero_profile");
        zero_profile.initial_post_count = 0;
        zero_profile.low_watermark      = 3;
        zero_profile.high_watermark     = 7;
        zero_sequence = mailbox_rx_start_sequence::type_id::create(
            "zero_sequence");
        zero_sequence.set_refill_profile(zero_profile);
        zero_sequence.start(zero_sequencer);
        if (zero_sequence.response == null ||
            zero_sequence.response.status != GQ_OK ||
            zero_sequence.response.committed_count != 0 ||
            zero_engine.tail_seq() != 0 ||
            zero_engine.outstanding_count() != 0 ||
            adapter.publish_count["rx_7"] != 0)
            `uvm_fatal("REFILL_ZERO_START",
                       "zero startup did not activate without publication")
        duplicate_sequence = mailbox_rx_start_sequence::type_id::create(
            "zero_duplicate_sequence");
        duplicate_sequence.set_refill_profile(zero_profile);
        duplicate_sequence.start(zero_sequencer);
        expect_resource_error("duplicate zero RX start",
                              duplicate_sequence.response);

        fail_profile = gq_deterministic_refill_profile::type_id::create(
            "create_fail_profile");
        fail_profile.initial_post_count = 3;
        fail_profile.low_watermark      = 1;
        fail_profile.high_watermark     = 2;
        fail_profile.fail_create_seq    = 1;
        fail_sequence = mailbox_rx_start_sequence::type_id::create(
            "create_fail_sequence");
        fail_sequence.set_refill_profile(fail_profile);
        fail_sequence.start(create_fail_sequencer);
        expect_resource_error("descriptor creation failure",
                              fail_sequence.response);
        if (create_fail_engine.head_seq() != 0 ||
            create_fail_engine.tail_seq() != 0 ||
            create_fail_engine.outstanding_count() != 0 ||
            adapter.publish_count["rx_8"] != 0)
            `uvm_fatal("REFILL_CREATE_FAIL",
                       "creation failure polluted startup state")
        recovery_profile = gq_deterministic_refill_profile::type_id::create(
            "recovery_profile");
        recovery_profile.initial_post_count = 2;
        recovery_profile.low_watermark      = 1;
        recovery_profile.high_watermark     = 2;
        recovery_sequence = mailbox_rx_start_sequence::type_id::create(
            "recovery_sequence");
        recovery_sequence.set_refill_profile(recovery_profile);
        recovery_sequence.start(create_fail_sequencer);
        if (recovery_sequence.response == null ||
            recovery_sequence.response.status != GQ_OK ||
            create_fail_engine.tail_seq() != 2 ||
            create_fail_engine.outstanding_count() != 2 ||
            adapter.publish_count["rx_8"] != 1)
            `uvm_fatal("REFILL_RECOVERY",
                       "failed startup left RX marked as started")

        fail_profile = gq_deterministic_refill_profile::type_id::create(
            "prepare_fail_profile");
        fail_profile.initial_post_count = 3;
        fail_profile.low_watermark      = 1;
        fail_profile.high_watermark     = 2;
        fail_profile.fail_prepare_seq   = 1;
        prepare_fail_sequence = mailbox_rx_start_sequence::type_id::create(
            "prepare_fail_sequence");
        prepare_fail_sequence.set_refill_profile(fail_profile);
        prepare_fail_sequence.start(prepare_fail_sequencer);
        expect_resource_error("descriptor preparation failure",
                              prepare_fail_sequence.response);
        if (prepare_fail_engine.head_seq() != 0 ||
            prepare_fail_engine.tail_seq() != 0 ||
            prepare_fail_engine.outstanding_count() != 0 ||
            adapter.publish_count["rx_9"] != 0)
            `uvm_fatal("REFILL_PREPARE_FAIL",
                       "preparation failure polluted startup state")

        // Refill must not retain a batch generated from a tail/watermark
        // snapshot taken while an earlier publish was still active. A queued
        // user submit owns the first wakeup and advances the tail before refill
        // may generate descriptors for the actual installation sequences.
        race_engine.initialize();
        race_profile = gq_deterministic_refill_profile::type_id::create(
            "race_profile");
        race_profile.initial_post_count = 4;
        race_profile.low_watermark      = 3;
        race_profile.high_watermark     = 4;
        race_profile.base_len           = 100;
        race_start_request = gq_request::type_id::create(
            "race_start_request");
        race_start_request.kind = GQ_START_RX;
        race_start_request.set_refill_profile(race_profile);
        race_start_response = gq_response::type_id::create(
            "race_start_response");
        race_engine.start_rx(race_start_request, race_start_response);
        if (race_start_response.status != GQ_OK ||
            race_start_response.committed_count != 4 ||
            race_engine.tail_seq() != 4 ||
            race_adapter.publish_count["rx_10"] != 1)
            `uvm_fatal("REFILL_PUBLISH_REVALIDATE",
                       "race setup did not start four RX descriptors")

        race_adapter.gate_publishes = 1;
        race_adapter.gated_key = "rx_10";
        race_adapter.allow_publish_return.reset();
        race_submit_a_desc = mailbox_rx_desc::type_id::create(
            "race_submit_a_desc");
        race_submit_a_desc.buf_len = 800;
        race_submit_a_request = gq_request::type_id::create(
            "race_submit_a_request");
        race_submit_a_request.add_desc(race_submit_a_desc);
        race_submit_a_response = gq_response::type_id::create(
            "race_submit_a_response");
        race_submit_a_returned = 0;
        fork : race_blocked_publish_a
            begin
                race_engine.submit_batch(race_submit_a_request,
                                         race_submit_a_response);
                race_submit_a_returned = 1;
            end
        join_none
        wait_for_gated_publish(1);

        race_submit_b_desc = mailbox_rx_desc::type_id::create(
            "race_submit_b_desc");
        race_submit_b_desc.buf_len = 900;
        race_submit_b_request = gq_request::type_id::create(
            "race_submit_b_request");
        race_submit_b_request.add_desc(race_submit_b_desc);
        race_submit_b_response = gq_response::type_id::create(
            "race_submit_b_response");
        race_submit_b_returned = 0;
        fork : race_queued_publish_b
            begin
                race_engine.submit_batch(race_submit_b_request,
                                         race_submit_b_response);
                race_submit_b_returned = 1;
            end
        join_none
        #1ns;
        if (race_submit_b_returned || race_engine.tail_seq() != 5)
            `uvm_fatal("REFILL_PUBLISH_REVALIDATE",
                       "second user submit did not queue behind blocked publish")

        for (gq_logical_seq_t seq = 0; seq < 3; seq++)
            race_dut.complete_slot(race_engine, seq, 32, 16);
        race_drain_returned = 0;
        fork : race_completion_refill
            begin
                race_engine.drain_completed();
                race_drain_returned = 1;
            end
        join_none
        for (int unsigned poll = 0; poll < 200; poll++) begin
            #1ns;
            if (race_engine.head_seq() == 3)
                break;
        end
        #1ns;
        if (race_engine.head_seq() != 3 || race_drain_returned)
            `uvm_fatal("REFILL_PUBLISH_REVALIDATE",
                       "completion refill did not wait behind blocked publish")

        race_adapter.allow_publish_return.trigger();
        wait_for_gated_publish(2);
        if (race_adapter.gated_tails[1] !=
            ptr_codec.encode_publish(5, 6, 32))
            `uvm_fatal("REFILL_PUBLISH_REVALIDATE",
                       "queued user submit did not own the first publish wakeup")
        race_adapter.allow_publish_return.trigger();
        wait_for_gated_publish(3);
        if (race_adapter.gated_tails[2] !=
                ptr_codec.encode_publish(6, 7, 32) ||
            race_engine.tail_seq() != 7 ||
            race_engine.outstanding_count() != 4 ||
            !$cast(race_refill_desc, race_engine.get_outstanding(6)) ||
            race_refill_desc.buf_len != 106 ||
            race_engine.get_outstanding(7) != null)
            `uvm_fatal("REFILL_PUBLISH_REVALIDATE",
                       "refill used a stale logical sequence or exceeded high watermark")
        race_adapter.allow_publish_return.trigger();
        for (int unsigned poll = 0; poll < 200; poll++) begin
            #1ns;
            if (race_submit_a_returned && race_submit_b_returned &&
                race_drain_returned)
                break;
        end
        if (!race_submit_a_returned || !race_submit_b_returned ||
            !race_drain_returned ||
            race_submit_a_response.status != GQ_OK ||
            race_submit_b_response.status != GQ_OK ||
            race_adapter.publish_count["rx_10"] != 4)
            `uvm_fatal("REFILL_PUBLISH_REVALIDATE",
                       "revalidated refill publications did not complete once")
        race_adapter.gate_publishes = 0;
        race_adapter.gated_key = "";
        race_engine.cleanup();
        race_mem.leak_check(`__FILE__, `__LINE__);

        env.cleanup();
        mem.leak_check(`__FILE__, `__LINE__);
        phase.drop_objection(this);
    endtask
endclass

`endif
