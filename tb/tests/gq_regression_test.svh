`ifndef GQ_REGRESSION_TEST_SVH
`define GQ_REGRESSION_TEST_SVH

class gq_regression_zero_completion extends gq_completion_source;
    `uvm_object_utils(gq_regression_zero_completion)

    int unsigned forced_count;

    function new(string name = "gq_regression_zero_completion");
        super.new(name);
        forced_count = 0;
    endfunction

    virtual function int unsigned completed_count(
        host_mem_api mem,
        gq_addr_t ring_base,
        gq_addr_t status_addr,
        int unsigned depth,
        int unsigned desc_size,
        gq_logical_seq_t logical_head,
        input gq_desc_base pending[$]);
        int unsigned result;

        result = forced_count;
        forced_count = 0;
        return result;
    endfunction
endclass

class gq_regression_overcount_completion extends gq_completion_source;
    `uvm_object_utils(gq_regression_overcount_completion)

    function new(string name = "gq_regression_overcount_completion");
        super.new(name);
    endfunction

    virtual function int unsigned completed_count(
        host_mem_api mem,
        gq_addr_t ring_base,
        gq_addr_t status_addr,
        int unsigned depth,
        int unsigned desc_size,
        gq_logical_seq_t logical_head,
        input gq_desc_base pending[$]);
        return pending.size() + 1;
    endfunction
endclass

class gq_regression_diagnostic_catcher extends uvm_report_catcher;
    `uvm_object_utils(gq_regression_diagnostic_catcher)

    int unsigned timeout_count;
    int unsigned protocol_count;
    string timeout_message;
    string protocol_message;

    function new(string name = "gq_regression_diagnostic_catcher");
        super.new(name);
        timeout_count   = 0;
        protocol_count  = 0;
        timeout_message = "";
        protocol_message = "";
    endfunction

    virtual function action_e catch();
        if (get_severity() != UVM_ERROR)
            return THROW;
        if (get_id() == "GQ_COMPLETION_TIMEOUT") begin
            timeout_count++;
            timeout_message = get_message();
            set_severity(UVM_INFO);
            return THROW;
        end
        if (get_id() == "GQ_COMPLETION_PROTOCOL") begin
            protocol_count++;
            protocol_message = get_message();
            set_severity(UVM_INFO);
            return THROW;
        end
        return THROW;
    endfunction
endclass

class gq_regression_delayed_adapter extends mailbox_mock_adapter;
    `uvm_object_utils(gq_regression_delayed_adapter)

    time publish_delay;
    uvm_event publish_entered;

    function new(string name = "gq_regression_delayed_adapter");
        super.new(name);
        publish_delay = 0;
        publish_entered = new({name, "_publish_entered"});
    endfunction

    virtual task publish(
        gq_role_e role,
        int unsigned queue_id,
        gq_raw_ptr_t raw_tail);
        publish_entered.trigger();
        #(publish_delay);
        super.publish(role, queue_id, raw_tail);
    endtask
endclass

class gq_regression_lifecycle_engine extends gq_queue_engine;
    `uvm_component_utils(gq_regression_lifecycle_engine)

    bit pause_before_commit;
    uvm_event commit_entered;
    uvm_event allow_commit;

    function new(string name = "gq_regression_lifecycle_engine",
                 uvm_component parent = null);
        super.new(name, parent);
        pause_before_commit = 0;
        commit_entered = new({name, "_commit_entered"});
        allow_commit = new({name, "_allow_commit"});
    endfunction

    protected virtual task completion_commit_entered();
        if (pause_before_commit) begin
            commit_entered.trigger();
            allow_commit.wait_on();
        end
    endtask
endclass

class gq_regression_test extends uvm_test;
    `uvm_component_utils(gq_regression_test)

    host_mem_manager     mem;
    gq_test_ptr_codec    ptr_codec;
    gq_regression_delayed_adapter timeout_adapter;
    mailbox_mock_adapter protocol_adapter;
    gq_queue_cfg         timeout_cfg;
    gq_regression_zero_completion timeout_source;
    gq_regression_lifecycle_engine timeout_engine;
    gq_queue_cfg         protocol_cfg;
    gq_regression_lifecycle_engine protocol_engine;
    gq_queue_cfg         irq_timeout_cfg;
    gq_queue_engine      irq_timeout_engine;
    host_mem_manager     regression_mem;
    mailbox_mock_adapter regression_adapter;
    mailbox_mock_dut     regression_dut;
    mailbox_env_cfg      env_cfg;
    mailbox_env          env;

    function new(string name = "gq_regression_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function string bytes_to_hex(input byte data[]);
        string result;
        bit [7:0] value;

        result = "";
        foreach (data[i]) begin
            if (i != 0)
                result = {result, " "};
            value = data[i];
            result = {result, $sformatf("%02x", value)};
        end
        return result;
    endfunction

    function bit has_token(input string message, input string token);
        return uvm_is_match({"*", token, "*"}, message);
    endfunction

    function bit diagnostic_matches(
        input string message,
        input string role,
        input int unsigned queue_id,
        input gq_logical_seq_t head,
        input gq_logical_seq_t tail,
        input int unsigned slot,
        input bit phase,
        input gq_addr_t ring_addr,
        input gq_addr_t slot_addr,
        input string descriptor_hex);
        return has_token(message, {"role=", role}) &&
               has_token(message, $sformatf("queue_id=%0d", queue_id)) &&
               has_token(message, $sformatf("head=%0d", head)) &&
               has_token(message, $sformatf("tail=%0d", tail)) &&
               has_token(message, $sformatf("slot=%0d", slot)) &&
               has_token(message, $sformatf("phase=%0d", phase)) &&
               has_token(message, $sformatf("ring_addr=0x%016h", ring_addr)) &&
               has_token(message, $sformatf("slot_addr=0x%016h", slot_addr)) &&
               has_token(message, {"descriptor=", descriptor_hex});
    endfunction

    function gq_queue_engine find_engine(input string key);
        uvm_component component_handle;
        gq_queue_engine engine;

        component_handle = uvm_root::get().find(
            {"uvm_test_top.env.", key, ".engine"});
        if (!$cast(engine, component_handle))
            `uvm_fatal("REG_PATH", {"could not find engine ", key})
        return engine;
    endfunction

    function gq_sequencer find_sequencer(input string key);
        uvm_component component_handle;
        gq_sequencer sequencer;

        component_handle = uvm_root::get().find(
            {"uvm_test_top.env.", key, ".sequencer"});
        if (!$cast(sequencer, component_handle))
            `uvm_fatal("REG_PATH", {"could not find sequencer ", key})
        return sequencer;
    endfunction

    function mailbox_tx_desc make_tx(input string name,
                                     input int unsigned index);
        mailbox_tx_desc desc;

        desc = mailbox_tx_desc::type_id::create(name);
        desc.srcid    = 16'h8100 + index;
        desc.dstid    = 16'h8200 + index;
        desc.msg_type = 16'h8300 + index;
        desc.buf_len  = (index & 1) ? 16 : 0;
        desc.data_len = 1;
        desc.data[0]  = byte'(index);
        return desc;
    endfunction

    task wait_for_state(input gq_queue_engine engine,
                        input gq_logical_seq_t expected_head,
                        input gq_logical_seq_t expected_tail,
                        input string check_name);
        for (int unsigned poll = 0; poll < 2000; poll++) begin
            if (engine.head_seq() == expected_head &&
                engine.tail_seq() == expected_tail)
                return;
            #1ns;
        end
        `uvm_fatal("REG_TIMEOUT", $sformatf(
            "%s expected head/tail=%0d/%0d got %0d/%0d",
            check_name, expected_head, expected_tail,
            engine.head_seq(), engine.tail_seq()))
    endtask

    task wait_for_all_rings(input bit allocated);
        gq_queue_engine tx_1;
        gq_queue_engine tx_4095;
        gq_queue_engine rx_2;
        gq_queue_engine rx_3000;
        bit matched;

        tx_1    = find_engine("tx_1");
        tx_4095 = find_engine("tx_4095");
        rx_2    = find_engine("rx_2");
        rx_3000 = find_engine("rx_3000");
        for (int unsigned poll = 0; poll < 2000; poll++) begin
            matched = allocated ?
                (tx_1.ring_base() != 0 && tx_4095.ring_base() != 0 &&
                 rx_2.ring_base() != 0 && rx_3000.ring_base() != 0 &&
                 tx_1.is_ready() && tx_4095.is_ready() &&
                 rx_2.is_ready() && rx_3000.is_ready()) :
                (tx_1.ring_base() == 0 && tx_4095.ring_base() == 0 &&
                 rx_2.ring_base() == 0 && rx_3000.ring_base() == 0 &&
                 !tx_1.is_ready() && !tx_4095.is_ready() &&
                 !rx_2.is_ready() && !rx_3000.is_ready());
            if (matched)
                return;
            #1ns;
        end
        `uvm_fatal("REG_RESET_TIMEOUT",
                   allocated ? "queue rings did not recover" :
                               "queue rings were not released")
    endtask

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        mem = new("mem");
        mem.init_region(64'h0000_0001_7000_0000,
                        64'h0000_0001_70ff_ffff, MODE_LINEAR, 16);
        ptr_codec = gq_test_ptr_codec::type_id::create("ptr_codec");
        timeout_adapter = gq_regression_delayed_adapter::type_id::create(
            "timeout_adapter");
        timeout_adapter.publish_delay = 100ns;
        protocol_adapter = mailbox_mock_adapter::type_id::create(
            "protocol_adapter");

        timeout_cfg = gq_queue_cfg::type_id::create("timeout_cfg");
        timeout_cfg.queue_id           = 4095;
        timeout_cfg.role               = GQ_TX;
        timeout_cfg.depth              = 32;
        timeout_cfg.desc_size          = 64;
        timeout_cfg.alignment          = 64;
        timeout_cfg.status_area_size   = 0;
        timeout_cfg.wait_mode          = GQ_POLL;
        timeout_cfg.poll_interval      = 10ns;
        timeout_cfg.completion_timeout = 50ns;
        timeout_cfg.ptr_codec          = ptr_codec;
        timeout_source = gq_regression_zero_completion::type_id::create(
            "timeout_completion");
        timeout_cfg.completion_source = timeout_source;
        uvm_config_db#(gq_queue_cfg)::set(this, "timeout_engine", "cfg",
                                          timeout_cfg);
        uvm_config_db#(host_mem_api)::set(this, "timeout_engine", "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "timeout_engine", "adapter",
                                           timeout_adapter);
        timeout_engine = gq_regression_lifecycle_engine::type_id::create(
            "timeout_engine", this);

        protocol_cfg = gq_queue_cfg::type_id::create("protocol_cfg");
        protocol_cfg.queue_id           = 3000;
        protocol_cfg.role               = GQ_RX;
        protocol_cfg.depth              = 32;
        protocol_cfg.desc_size          = 16;
        protocol_cfg.alignment          = 64;
        protocol_cfg.status_area_size   = 0;
        protocol_cfg.wait_mode          = GQ_POLL;
        protocol_cfg.poll_interval      = 10ns;
        protocol_cfg.completion_timeout = 50ns;
        protocol_cfg.ptr_codec          = ptr_codec;
        protocol_cfg.completion_source  =
            gq_regression_overcount_completion::type_id::create(
                "protocol_completion");
        uvm_config_db#(gq_queue_cfg)::set(this, "protocol_engine", "cfg",
                                          protocol_cfg);
        uvm_config_db#(host_mem_api)::set(this, "protocol_engine", "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "protocol_engine", "adapter",
                                           protocol_adapter);
        protocol_engine = gq_regression_lifecycle_engine::type_id::create(
            "protocol_engine", this);

        irq_timeout_cfg = gq_queue_cfg::type_id::create("irq_timeout_cfg");
        irq_timeout_cfg.queue_id           = 2048;
        irq_timeout_cfg.role               = GQ_TX;
        irq_timeout_cfg.depth              = 32;
        irq_timeout_cfg.desc_size          = 64;
        irq_timeout_cfg.alignment          = 64;
        irq_timeout_cfg.status_area_size   = 0;
        irq_timeout_cfg.wait_mode          = GQ_IRQ;
        irq_timeout_cfg.poll_interval      = 10ns;
        irq_timeout_cfg.completion_timeout = 50ns;
        irq_timeout_cfg.ptr_codec          = ptr_codec;
        irq_timeout_cfg.completion_source  =
            gq_regression_zero_completion::type_id::create(
                "irq_timeout_completion");
        uvm_config_db#(gq_queue_cfg)::set(this, "irq_timeout_engine", "cfg",
                                          irq_timeout_cfg);
        uvm_config_db#(host_mem_api)::set(this, "irq_timeout_engine", "mem",
                                          mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "irq_timeout_engine",
                                           "adapter", protocol_adapter);
        irq_timeout_engine = gq_queue_engine::type_id::create(
            "irq_timeout_engine", this);

        regression_mem = new("regression_mem");
        regression_mem.init_region(64'h0000_0001_7100_0000,
                                   64'h0000_0001_71ff_ffff,
                                   MODE_LINEAR, 16);
        regression_adapter = mailbox_mock_adapter::type_id::create(
            "regression_adapter");
        regression_dut = mailbox_mock_dut::type_id::create(
            "regression_dut");
        regression_dut.mem     = regression_mem;
        regression_dut.adapter = regression_adapter;
        env_cfg = mailbox_env_cfg::type_id::create("env_cfg");
        env_cfg.mem       = regression_mem;
        env_cfg.adapter   = regression_adapter;
        env_cfg.ptr_codec = ptr_codec;
        begin
            string reason;

            if (!env_cfg.add_tx(1, 32, reason) ||
                !env_cfg.add_tx(4095, 32, reason) ||
                !env_cfg.add_rx(2, 32, reason) ||
                !env_cfg.add_rx(3000, 32, reason))
                `uvm_fatal("REG_CFG", reason)
        end
        env_cfg.queues["tx_1"].wait_mode = GQ_POLL;
        env_cfg.queues["tx_4095"].wait_mode = GQ_IRQ;
        env_cfg.queues["rx_2"].wait_mode = GQ_POLL;
        env_cfg.queues["rx_3000"].wait_mode = GQ_IRQ;
        foreach (env_cfg.queues[key]) begin
            env_cfg.queues[key].poll_interval = 10ns;
            env_cfg.queues[key].completion_timeout = 100us;
        end
        uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", env_cfg);
        env = mailbox_env::type_id::create("env", this);
    endfunction

    task run_integrated_checks();
        gq_queue_engine tx_1;
        gq_queue_engine tx_4095;
        gq_queue_engine rx_2;
        gq_queue_engine rx_3000;
        gq_sequencer tx_1_sequencer;
        gq_sequencer tx_4095_sequencer;
        gq_sequencer rx_2_sequencer;
        gq_sequencer rx_3000_sequencer;
        mailbox_tx_sequence tx_sequence;
        mailbox_rx_start_sequence rx_sequence;
        mailbox_rx_start_sequence duplicate_rx_sequence;
        mailbox_refill_profile rx_2_profile;
        mailbox_refill_profile rx_3000_profile;
        byte slot_bytes[];

        env_cfg.wait_ready();
        if (env.agent_count() != 4 ||
            !env.has_agent("tx_1") || !env.has_agent("tx_4095") ||
            !env.has_agent("rx_2") || !env.has_agent("rx_3000") ||
            env.has_agent("tx_2") || env.has_agent("rx_1"))
            `uvm_fatal("REG_SPARSE", "sparse queue construction is incorrect")
        tx_1    = find_engine("tx_1");
        tx_4095 = find_engine("tx_4095");
        rx_2    = find_engine("rx_2");
        rx_3000 = find_engine("rx_3000");
        tx_1_sequencer    = find_sequencer("tx_1");
        tx_4095_sequencer = find_sequencer("tx_4095");
        rx_2_sequencer    = find_sequencer("rx_2");
        rx_3000_sequencer = find_sequencer("rx_3000");

        tx_sequence = mailbox_tx_sequence::type_id::create(
            "single_tx_sequence");
        tx_sequence.add_desc(make_tx("single_tx", 0));
        tx_sequence.start(tx_1_sequencer);
        if (tx_sequence.response == null ||
            tx_sequence.response.status != GQ_OK ||
            tx_sequence.response.committed_count != 1)
            `uvm_fatal("REG_TX_SINGLE", "single TX request failed")
        regression_dut.complete_slot(tx_1, 0, 32, 64);
        wait_for_state(tx_1, 1, 1, "single TX poll completion");

        tx_sequence = mailbox_tx_sequence::type_id::create(
            "batch_tx_sequence");
        for (int unsigned i = 0; i < 3; i++)
            tx_sequence.add_desc(make_tx($sformatf("batch_tx_%0d", i),
                                         10 + i));
        tx_sequence.start(tx_4095_sequencer);
        if (tx_sequence.response == null ||
            tx_sequence.response.status != GQ_OK ||
            tx_sequence.response.committed_count != 3)
            `uvm_fatal("REG_TX_BATCH", "batch TX request failed")
        for (gq_logical_seq_t seq = 0; seq < 3; seq++)
            regression_dut.complete_slot(tx_4095, seq, 32, 64);
        regression_dut.trigger_irq(GQ_TX, 4095);
        wait_for_state(tx_4095, 3, 3, "batch TX IRQ completion");
        if (regression_adapter.ack_irq_calls == 0)
            `uvm_fatal("REG_IRQ", "TX IRQ completion was not acknowledged")

        // Fill and drain through the last slot, then reuse slot zero with the
        // opposite phase at logical sequence 32.
        tx_sequence = mailbox_tx_sequence::type_id::create(
            "wrap_fill_sequence");
        for (int unsigned i = 1; i < 32; i++)
            tx_sequence.add_desc(make_tx($sformatf("wrap_fill_%0d", i),
                                         100 + i));
        tx_sequence.start(tx_1_sequencer);
        if (tx_sequence.response == null ||
            tx_sequence.response.status != GQ_OK ||
            tx_sequence.response.committed_count != 31)
            `uvm_fatal("REG_PHASE", "phase-wrap fill request failed")
        for (gq_logical_seq_t seq = 1; seq < 32; seq++)
            regression_dut.complete_slot(tx_1, seq, 32, 64);
        wait_for_state(tx_1, 32, 32, "phase-wrap fill completion");
        tx_sequence = mailbox_tx_sequence::type_id::create(
            "wrap_reuse_sequence");
        tx_sequence.add_desc(make_tx("wrap_reuse", 200));
        tx_sequence.start(tx_1_sequencer);
        regression_mem.read_mem(tx_1.ring_base(), 64, slot_bytes,
                                `__FILE__, `__LINE__);
        if (slot_bytes[0][0] != gq_phase(32, 32) ||
            slot_bytes[0][1] != !gq_phase(32, 32))
            `uvm_fatal("REG_PHASE", "slot-zero phase did not toggle on wrap")
        regression_dut.complete_slot(tx_1, 32, 32, 64);
        wait_for_state(tx_1, 33, 33, "phase-wrap reuse completion");

        rx_2_profile = mailbox_refill_profile::type_id::create(
            "rx_2_profile");
        rx_2_profile.initial_post_count  = 4;
        rx_2_profile.low_watermark       = 2;
        rx_2_profile.high_watermark      = 6;
        rx_2_profile.restart_after_reset = 1;
        rx_2_profile.min_buf_len         = 16;
        rx_2_profile.max_buf_len         = 16;
        rx_sequence = mailbox_rx_start_sequence::type_id::create(
            "rx_2_start");
        rx_sequence.set_refill_profile(rx_2_profile);
        rx_sequence.start(rx_2_sequencer);
        if (rx_sequence.response == null ||
            rx_sequence.response.status != GQ_OK ||
            rx_sequence.response.committed_count != 4)
            `uvm_fatal("REG_RX_START", "RX 2 startup failed")
        duplicate_rx_sequence = mailbox_rx_start_sequence::type_id::create(
            "rx_2_duplicate_start");
        duplicate_rx_sequence.set_refill_profile(rx_2_profile);
        duplicate_rx_sequence.start(rx_2_sequencer);
        if (duplicate_rx_sequence.response == null ||
            duplicate_rx_sequence.response.status != GQ_RESOURCE_ERROR ||
            duplicate_rx_sequence.response.committed_count != 0 ||
            rx_2.tail_seq() != 4)
            `uvm_fatal("REG_RX_ONESHOT",
                       "duplicate RX startup changed queue state")
        for (gq_logical_seq_t seq = 0; seq < 3; seq++)
            regression_dut.complete_slot(rx_2, seq, 32, 16);
        wait_for_state(rx_2, 3, 9, "RX low/high watermark refill");
        if (rx_2.outstanding_count() != 6 ||
            regression_adapter.publish_count["rx_2"] != 2)
            `uvm_fatal("REG_RX_REFILL", "RX 2 did not refill once to high watermark")

        rx_3000_profile = mailbox_refill_profile::type_id::create(
            "rx_3000_profile");
        rx_3000_profile.initial_post_count  = 4;
        rx_3000_profile.low_watermark       = 2;
        rx_3000_profile.high_watermark      = 6;
        rx_3000_profile.restart_after_reset = 0;
        rx_3000_profile.min_buf_len         = 16;
        rx_3000_profile.max_buf_len         = 16;
        rx_sequence = mailbox_rx_start_sequence::type_id::create(
            "rx_3000_start");
        rx_sequence.set_refill_profile(rx_3000_profile);
        rx_sequence.start(rx_3000_sequencer);
        if (rx_sequence.response == null ||
            rx_sequence.response.status != GQ_OK ||
            rx_sequence.response.committed_count != 4)
            `uvm_fatal("REG_RX_START", "RX 3000 startup failed")
        regression_dut.complete_slot(rx_3000, 0, 32, 16);
        regression_dut.trigger_irq(GQ_RX, 3000);
        wait_for_state(rx_3000, 1, 4, "RX IRQ completion");
        if (regression_adapter.ack_irq_calls < 2)
            `uvm_fatal("REG_IRQ", "RX IRQ completion was not acknowledged")

        if (!env_cfg.trigger_reset_asserted())
            `uvm_fatal("REG_RESET", "runtime reset assertion was rejected")
        wait_for_all_rings(0);
        if (tx_1.outstanding_count() != 0 ||
            tx_4095.outstanding_count() != 0 ||
            rx_2.outstanding_count() != 0 ||
            rx_3000.outstanding_count() != 0 ||
            regression_adapter.disable_calls != 4)
            `uvm_fatal("REG_RESET", "reset did not quiesce all four queues")
        if (!env_cfg.trigger_reset_deasserted())
            `uvm_fatal("REG_RESET", "runtime reset release was rejected")
        wait_for_all_rings(1);
        if (tx_1.head_seq() != 0 || tx_1.tail_seq() != 0 ||
            tx_4095.head_seq() != 0 || tx_4095.tail_seq() != 0 ||
            rx_2.head_seq() != 0 || rx_2.tail_seq() != 4 ||
            rx_2.outstanding_count() != 4 ||
            rx_3000.head_seq() != 0 || rx_3000.tail_seq() != 0 ||
            rx_3000.outstanding_count() != 0 ||
            regression_adapter.configure_calls != 8)
            `uvm_fatal("REG_RESET", "reset recovery state is incorrect")

        tx_sequence = mailbox_tx_sequence::type_id::create(
            "post_reset_tx_sequence");
        tx_sequence.add_desc(make_tx("post_reset_tx", 300));
        tx_sequence.start(tx_4095_sequencer);
        if (tx_sequence.response == null ||
            tx_sequence.response.status != GQ_OK ||
            tx_sequence.response.reset_epoch != 1)
            `uvm_fatal("REG_RESET", "post-reset TX request failed")
        regression_dut.complete_slot(tx_4095, 0, 32, 64);
        regression_dut.trigger_irq(GQ_TX, 4095);
        wait_for_state(tx_4095, 1, 1, "post-reset IRQ completion");

        env.cleanup_and_check_leaks();
        env.cleanup_and_check_leaks();
        if (tx_1.is_ready() || tx_4095.is_ready() ||
            rx_2.is_ready() || rx_3000.is_ready() ||
            tx_1.ring_base() != 0 || tx_4095.ring_base() != 0 ||
            rx_2.ring_base() != 0 || rx_3000.ring_base() != 0 ||
            tx_1.outstanding_count() != 0 ||
            tx_4095.outstanding_count() != 0 ||
            rx_2.outstanding_count() != 0 ||
            rx_3000.outstanding_count() != 0 ||
            regression_adapter.disable_calls != 8)
            `uvm_fatal("REG_CLEANUP",
                       "idempotent final cleanup left queue resources")
    endtask

    task run_phase(uvm_phase phase);
        gq_regression_diagnostic_catcher catcher;
        gq_regression_diagnostic_catcher irq_catcher;
        mailbox_tx_desc timeout_desc;
        mailbox_tx_desc head_rearm_desc;
        mailbox_tx_desc reset_rearm_desc;
        mailbox_tx_desc irq_timeout_desc;
        mailbox_tx_desc stale_reset_desc;
        mailbox_rx_desc protocol_desc;
        gq_request request;
        gq_response response;
        byte expected_bytes[];
        string timeout_hex;
        string protocol_hex;
        bit failed;
        bit timeout_submit_returned;
        int unsigned premature_timeout_count;
        gq_regression_diagnostic_catcher lifecycle_catcher;
        bit stale_reset_drain_returned;
        bit cleanup_wait_returned;

        phase.raise_objection(this);
        failed = 0;
        timeout_engine.initialize();
        protocol_engine.initialize();
        irq_timeout_engine.initialize();

        timeout_desc = mailbox_tx_desc::type_id::create("timeout_desc");
        timeout_desc.srcid    = 16'h1234;
        timeout_desc.dstid    = 16'h5678;
        timeout_desc.msg_type = 16'h9abc;
        timeout_desc.buf_len  = 0;
        timeout_desc.data_len = 1;
        timeout_desc.data[0]  = 8'ha5;
        request = gq_request::type_id::create("timeout_request");
        request.add_desc(timeout_desc);
        response = gq_response::type_id::create("timeout_response");
        catcher = new("diagnostic_catcher");
        uvm_report_cb::add(null, catcher);
        timeout_submit_returned = 0;
        fork : delayed_timeout_submit
            begin
                timeout_engine.submit_batch(request, response);
                timeout_submit_returned = 1;
            end
        join_none
        timeout_adapter.publish_entered.wait_on();
        #(timeout_cfg.completion_timeout);
        timeout_engine.drain_completed();
        premature_timeout_count = catcher.timeout_count;
        wait (timeout_submit_returned);
        timeout_engine.drain_completed();
        if (response.status != GQ_OK || response.committed_count != 1)
            `uvm_fatal("REG_DIAG_SETUP", "timeout descriptor submit failed")
        mem.read_mem(timeout_engine.ring_base(), timeout_cfg.desc_size,
                     expected_bytes, `__FILE__, `__LINE__);
        timeout_hex = bytes_to_hex(expected_bytes);

        protocol_desc = mailbox_rx_desc::type_id::create("protocol_desc");
        protocol_desc.buf_len = 16;
        request = gq_request::type_id::create("protocol_request");
        request.add_desc(protocol_desc);
        response = gq_response::type_id::create("protocol_response");
        protocol_engine.submit_batch(request, response);
        if (response.status != GQ_OK || response.committed_count != 1)
            `uvm_fatal("REG_DIAG_SETUP", "protocol descriptor submit failed")
        mem.read_mem(protocol_engine.ring_base(), protocol_cfg.desc_size,
                     expected_bytes, `__FILE__, `__LINE__);
        protocol_hex = bytes_to_hex(expected_bytes);

        #(timeout_cfg.completion_timeout);
        timeout_engine.drain_completed();
        timeout_engine.drain_completed();
        timeout_engine.drain_completed();
        protocol_engine.drain_completed();
        uvm_report_cb::delete(null, catcher);

        if (premature_timeout_count != 0 || catcher.timeout_count != 1 ||
            !diagnostic_matches(catcher.timeout_message, "TX", 4095,
                                0, 1, 0, gq_phase(0, timeout_cfg.depth),
                                timeout_engine.ring_base(),
                                timeout_engine.ring_base(), timeout_hex))
            failed = 1;
        if (catcher.protocol_count != 1 ||
            !diagnostic_matches(catcher.protocol_message, "RX", 3000,
                                0, 1, 0, gq_phase(0, protocol_cfg.depth),
                                protocol_engine.ring_base(),
                                protocol_engine.ring_base(), protocol_hex))
            failed = 1;
        if (protocol_engine.head_seq() != 0 ||
            protocol_engine.tail_seq() != 1 ||
            protocol_engine.outstanding_count() != 1 ||
            protocol_engine.get_outstanding(0) != protocol_desc)
            `uvm_fatal("REG_DIAG_PROTOCOL",
                       "over-count retired or changed outstanding state")

        // Advancing the head to empty and a later runtime reset each create a
        // new oldest-outstanding episode. Repeated drains remain one-shot
        // within each episode.
        uvm_report_cb::add(null, catcher);
        timeout_source.forced_count = 1;
        timeout_engine.drain_completed();
        if (timeout_engine.head_seq() != 1 ||
            timeout_engine.tail_seq() != 1 ||
            timeout_engine.outstanding_count() != 0)
            `uvm_fatal("REG_DIAG_REARM", "forced head advancement failed")
        timeout_adapter.publish_delay = 0;
        head_rearm_desc = make_tx("head_rearm_desc", 401);
        request = gq_request::type_id::create("head_rearm_request");
        request.add_desc(head_rearm_desc);
        response = gq_response::type_id::create("head_rearm_response");
        timeout_engine.submit_batch(request, response);
        #(timeout_cfg.completion_timeout);
        timeout_engine.drain_completed();
        timeout_engine.drain_completed();
        if (response.status != GQ_OK || catcher.timeout_count != 2)
            `uvm_fatal("REG_DIAG_REARM",
                       "head advancement did not rearm one timeout")

        timeout_engine.begin_reset();
        timeout_engine.finish_reset();
        timeout_engine.release_reset();
        if (!timeout_engine.is_ready() || timeout_engine.head_seq() != 0 ||
            timeout_engine.tail_seq() != 0 ||
            timeout_engine.outstanding_count() != 0)
            `uvm_fatal("REG_DIAG_REARM", "diagnostic reset did not recover")
        reset_rearm_desc = make_tx("reset_rearm_desc", 402);
        request = gq_request::type_id::create("reset_rearm_request");
        request.add_desc(reset_rearm_desc);
        response = gq_response::type_id::create("reset_rearm_response");
        timeout_engine.submit_batch(request, response);
        #(timeout_cfg.completion_timeout);
        timeout_engine.drain_completed();
        timeout_engine.drain_completed();
        if (response.status != GQ_OK || catcher.timeout_count != 3)
            `uvm_fatal("REG_DIAG_REARM", "reset did not rearm one timeout")
        uvm_report_cb::delete(null, catcher);

        irq_timeout_desc = make_tx("irq_timeout_desc", 403);
        request = gq_request::type_id::create("irq_timeout_request");
        request.add_desc(irq_timeout_desc);
        response = gq_response::type_id::create("irq_timeout_response");
        irq_timeout_engine.submit_batch(request, response);
        irq_catcher = new("irq_diagnostic_catcher");
        uvm_report_cb::add(null, irq_catcher);
        irq_timeout_engine.wait_and_drain_once();
        irq_timeout_engine.wait_and_drain_once();
        uvm_report_cb::delete(null, irq_catcher);
        if (response.status != GQ_OK || irq_catcher.timeout_count != 1 ||
            !has_token(irq_catcher.timeout_message, "role=TX") ||
            !has_token(irq_catcher.timeout_message, "queue_id=2048") ||
            !has_token(irq_catcher.timeout_message, $sformatf(
                "slot_addr=0x%016h", irq_timeout_engine.ring_base())) ||
            !has_token(irq_catcher.timeout_message, "descriptor="))
            `uvm_fatal("REG_DIAG_IRQ",
                       "bounded IRQ wait did not report one complete timeout")

        // Reset or cleanup that wins after a completion query is validated but
        // before its lifecycle commit must suppress every stale diagnostic.
        timeout_source.forced_count = 1;
        timeout_engine.drain_completed();
        stale_reset_desc = make_tx("stale_reset_desc", 404);
        request = gq_request::type_id::create("stale_reset_request");
        request.add_desc(stale_reset_desc);
        response = gq_response::type_id::create("stale_reset_response");
        timeout_engine.submit_batch(request, response);
        #(timeout_cfg.completion_timeout);
        if (response.status != GQ_OK)
            `uvm_fatal("REG_DIAG_STALE", "stale reset setup submit failed")

        lifecycle_catcher = new("lifecycle_diagnostic_catcher");
        uvm_report_cb::add(null, lifecycle_catcher);
        timeout_engine.pause_before_commit = 1;
        timeout_engine.commit_entered.reset();
        timeout_engine.allow_commit.reset();
        stale_reset_drain_returned = 0;
        fork : stale_reset_diagnostic_race
            begin
                timeout_engine.drain_completed();
                stale_reset_drain_returned = 1;
            end
        join_none
        timeout_engine.commit_entered.wait_on();
        timeout_engine.begin_reset();
        timeout_engine.allow_commit.trigger();
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (stale_reset_drain_returned)
                break;
        end
        if (!stale_reset_drain_returned)
            `uvm_fatal("REG_DIAG_STALE",
                       "reset-cancelled diagnostic drain did not return")
        disable stale_reset_diagnostic_race;
        timeout_engine.pause_before_commit = 0;
        timeout_engine.finish_reset();
        timeout_engine.release_reset();

        // Separately cover the normal cleanup-cancellation path while a
        // completion wait is active. Cleanup must make the engine stale before
        // the poll interval can enter the drain path.
        cleanup_wait_returned = 0;
        fork : cleanup_wait_cancellation
            begin
                protocol_engine.wait_and_drain_once();
                cleanup_wait_returned = 1;
            end
        join_none
        #1ns;
        protocol_engine.cleanup();
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (cleanup_wait_returned)
                break;
        end
        if (!cleanup_wait_returned)
            `uvm_fatal("REG_DIAG_STALE",
                       "cleanup-cancelled completion wait did not return")
        disable cleanup_wait_cancellation;
        uvm_report_cb::delete(null, lifecycle_catcher);
        if (lifecycle_catcher.timeout_count != 0 ||
            lifecycle_catcher.protocol_count != 0)
            `uvm_fatal("REG_DIAG_STALE",
                       "reset or cleanup allowed a stale diagnostic")

        timeout_engine.cleanup();
        protocol_engine.cleanup();
        irq_timeout_engine.cleanup();
        mem.leak_check(`__FILE__, `__LINE__);
        if (failed)
            `uvm_fatal("REG_DIAG_FIELDS",
                       "completion diagnostics were missing, repeated, or incomplete")
        run_integrated_checks();
        phase.drop_objection(this);
    endtask
endclass

`endif
