// tb/tests/gq_config_test.sv: UVM 测试 gq_config_test：验证对应队列组件的定向行为和接口契约。
`ifndef GQ_CONFIG_TEST_SV
`define GQ_CONFIG_TEST_SV

class gq_config_test extends uvm_test;
    `uvm_component_utils(gq_config_test)

    host_mem_manager    mem;
    gq_test_ptr_codec   ptr_codec;
    mailbox_mock_adapter adapter;
    mailbox_env_cfg     env_cfg;
    mailbox_env_cfg     disabled_cfg;
    mailbox_env         env;
    mailbox_env         disabled_env;
    gq_queue_cfg        lifecycle_cfg;
    mailbox_mock_adapter lifecycle_adapter;
    gq_queue_engine     lifecycle_engine;

    function new(string name = "gq_config_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void expect_invalid(gq_queue_cfg cfg, string expected_fragment);
        string reason;

        if (cfg.validate(reason))
            `uvm_fatal("CFG", $sformatf("accepted invalid configuration: %s", expected_fragment))
        if (reason == "")
            `uvm_fatal("CFG", $sformatf("missing reason for invalid configuration: %s", expected_fragment))
    endfunction

    function bit ranges_overlap(gq_addr_t base_a, longint unsigned size_a,
                                gq_addr_t base_b, longint unsigned size_b);
        return base_a < (base_b + size_b) && base_b < (base_a + size_a);
    endfunction

    function gq_queue_cfg make_queue_cfg(string name, gq_role_e role,
                                         int unsigned queue_id,
                                         int unsigned depth,
                                         int unsigned desc_size);
        gq_queue_cfg queue_cfg;

        queue_cfg = gq_queue_cfg::type_id::create(name);
        queue_cfg.queue_id           = queue_id;
        queue_cfg.role               = role;
        queue_cfg.depth              = depth;
        queue_cfg.desc_size          = desc_size;
        queue_cfg.alignment          = 64;
        queue_cfg.status_area_size   = 0;
        queue_cfg.wait_mode          = GQ_POLL;
        queue_cfg.poll_min_interval  = 10ns;
        queue_cfg.poll_max_interval  = 10ns;
        queue_cfg.completion_timeout = 1us;
        queue_cfg.ptr_codec          = ptr_codec;
        queue_cfg.completion_source  = mailbox_completion::type_id::create(
            {name, "_completion"});
        return queue_cfg;
    endfunction

    function mailbox_env_cfg make_mailbox_cfg(string name);
        mailbox_env_cfg candidate;

        candidate           = mailbox_env_cfg::type_id::create(name);
        candidate.mem       = mem;
        candidate.adapter   = adapter;
        candidate.ptr_codec = ptr_codec;
        return candidate;
    endfunction

    function void append_failure(ref string failures, input string message);
        failures = {failures, failures == "" ? "" : "; ", message};
    endfunction

    function void expect_env_invalid(gq_env_cfg candidate, string check_name,
                                     ref string failures);
        string reason;

        if (candidate.validate(reason))
            append_failure(failures, {check_name, " was accepted"});
        else if (reason == "")
            append_failure(failures, {check_name, " had no failure reason"});
    endfunction

    function void build_phase(uvm_phase phase);
        gq_queue_cfg cfg;
        gq_queue_cfg malformed_queue;
        mailbox_env_cfg invalid_mailbox_cfg;
        mailbox_env_cfg boundary_mailbox_cfg;
        gq_env_cfg mutated_env_cfg;
        longint unsigned descriptor_bytes;
        longint unsigned checked_ring_bytes;
        string validation_failures;
        string reason;

        super.build_phase(phase);

        if ($bits(gq_addr_t) != 64)
            `uvm_fatal("WIDTH", "gq_addr_t")
        if ($bits(gq_raw_ptr_t) != 32)
            `uvm_fatal("WIDTH", "gq_raw_ptr_t")

        if (gq_phase(0, 32) != 1)
            `uvm_fatal("PHASE", "initial")
        if (gq_phase(31, 32) != 1)
            `uvm_fatal("PHASE", "early wrap")
        if (gq_phase(32, 32) != 0)
            `uvm_fatal("PHASE", "missing wrap")

        if (gq_queue_key(GQ_TX, 7) != "tx_7")
            `uvm_fatal("QUEUE_KEY", "TX queue key")
        if (gq_queue_key(GQ_RX, 7) != "rx_7")
            `uvm_fatal("QUEUE_KEY", "RX queue key")

        ptr_codec = gq_test_ptr_codec::type_id::create("ptr_codec");
        cfg = gq_queue_cfg::type_id::create("cfg");
        if (cfg.initial_logical_seq != 0)
            `uvm_fatal("CFG_INITIAL_SEQ", "default initial logical sequence is not zero")
        cfg.queue_id           = 7;
        cfg.role               = GQ_TX;
        cfg.depth              = 48;
        cfg.desc_size          = 64;
        cfg.alignment          = 16;
        cfg.status_area_size   = 64;
        cfg.wait_mode          = GQ_POLL;
        cfg.poll_min_interval  = 10ns;
        cfg.poll_max_interval  = 10ns;
        cfg.completion_timeout = 1us;
        cfg.ptr_codec          = ptr_codec;
        cfg.completion_source  = mailbox_completion::type_id::create(
            "cfg_completion");
        expect_invalid(cfg, "depth 48");

        cfg.depth = 32;
        if (!cfg.validate(reason))
            `uvm_fatal("CFG", reason)

        cfg.initial_logical_seq = 31;
        if (!cfg.validate(reason))
            `uvm_fatal("CFG_INITIAL_SEQ", {"valid initial sequence rejected: ", reason})
        cfg.initial_logical_seq = 32;
        expect_invalid(cfg, "initial logical sequence equal to depth");
        cfg.initial_logical_seq = 0;

        cfg.depth = 0;
        expect_invalid(cfg, "zero depth");
        cfg.depth = 24;
        expect_invalid(cfg, "non-power-of-two depth");
        cfg.depth = 32;

        cfg.desc_size = 0;
        expect_invalid(cfg, "zero descriptor size");
        cfg.desc_size = 64;

        cfg.alignment = 0;
        expect_invalid(cfg, "zero alignment");
        cfg.alignment = 16;

        cfg.poll_min_interval = 0;
        expect_invalid(cfg, "zero poll interval");
        cfg.poll_min_interval = 10ns;

        cfg.completion_timeout = 0;
        expect_invalid(cfg, "zero completion timeout");

        mem = new("mem");
        mem.init_region(64'h0000_0001_0000_0000,
                        64'h0000_0001_00ff_ffff, MODE_LINEAR, 16);
        adapter   = mailbox_mock_adapter::type_id::create("adapter");

        invalid_mailbox_cfg = make_mailbox_cfg("bad_id_cfg");
        malformed_queue = make_queue_cfg("bad_id_queue", GQ_TX, 4096, 32, 64);
        if (!invalid_mailbox_cfg.add_queue(malformed_queue, reason))
            append_failure(validation_failures, "generic add unexpectedly rejected bad mailbox ID");
        expect_env_invalid(invalid_mailbox_cfg, "mailbox ID above 4095", validation_failures);

        invalid_mailbox_cfg = make_mailbox_cfg("bad_depth_cfg");
        malformed_queue = make_queue_cfg("bad_depth_queue", GQ_RX, 1, 16, 16);
        if (!invalid_mailbox_cfg.add_queue(malformed_queue, reason))
            append_failure(validation_failures, "generic add unexpectedly rejected mailbox depth 16");
        expect_env_invalid(invalid_mailbox_cfg, "mailbox depth below 32", validation_failures);

        invalid_mailbox_cfg = make_mailbox_cfg("bad_tx_size_cfg");
        malformed_queue = make_queue_cfg("bad_tx_size_queue", GQ_TX, 2, 32, 16);
        if (!invalid_mailbox_cfg.add_queue(malformed_queue, reason))
            append_failure(validation_failures, "generic add unexpectedly rejected bad TX size");
        expect_env_invalid(invalid_mailbox_cfg, "mailbox TX descriptor size", validation_failures);

        invalid_mailbox_cfg = make_mailbox_cfg("bad_rx_size_cfg");
        malformed_queue = make_queue_cfg("bad_rx_size_queue", GQ_RX, 3, 32, 64);
        if (!invalid_mailbox_cfg.add_queue(malformed_queue, reason))
            append_failure(validation_failures, "generic add unexpectedly rejected bad RX size");
        expect_env_invalid(invalid_mailbox_cfg, "mailbox RX descriptor size", validation_failures);

        invalid_mailbox_cfg = make_mailbox_cfg("null_add_cfg");
        if (invalid_mailbox_cfg.add_queue(null, reason) || reason == "")
            append_failure(validation_failures, "null add was not rejected with a reason");

        mutated_env_cfg         = gq_env_cfg::type_id::create("mutated_env_cfg");
        mutated_env_cfg.mem     = mem;
        mutated_env_cfg.adapter = adapter;
        malformed_queue = make_queue_cfg("mutated_queue", GQ_TX, 20, 32, 64);
        if (!mutated_env_cfg.add_queue(malformed_queue, reason))
            append_failure(validation_failures, "initial mutable queue add failed");
        malformed_queue.queue_id = 21;
        if (!mutated_env_cfg.add_queue(malformed_queue, reason))
            append_failure(validation_failures, "reused mutable queue add failed before validation");
        expect_env_invalid(mutated_env_cfg, "mutated/reused queue handle", validation_failures);

        invalid_mailbox_cfg = make_mailbox_cfg("null_entry_cfg");
        invalid_mailbox_cfg.queues["tx_4"] = null;
        expect_env_invalid(invalid_mailbox_cfg, "null mailbox queue entry", validation_failures);

        boundary_mailbox_cfg = make_mailbox_cfg("boundary_mailbox_cfg");
        if (!boundary_mailbox_cfg.add_tx(0, 32, reason))
            append_failure(validation_failures, {"valid TX boundary rejected: ", reason});
        if (!boundary_mailbox_cfg.add_rx(4095, 32768, reason))
            append_failure(validation_failures, {"valid RX boundary rejected: ", reason});
        if (!boundary_mailbox_cfg.validate(reason))
            append_failure(validation_failures, {"valid mailbox boundaries failed validation: ",
                                                   reason});

        if (!gq_queue_engine::checked_ring_size(32, 64, 128,
                                                descriptor_bytes,
                                                checked_ring_bytes, reason))
            append_failure(validation_failures, {"valid checked ring size rejected: ", reason});
        else if (descriptor_bytes != 2048 || checked_ring_bytes != 2176)
            append_failure(validation_failures, "checked ring size returned incorrect byte counts");
        if (gq_queue_engine::checked_ring_size(65536, 65536, 0,
                                               descriptor_bytes,
                                               checked_ring_bytes, reason))
            append_failure(validation_failures, "checked ring size accepted a 2^32-byte block");
        else if (reason == "")
            append_failure(validation_failures, "oversized checked ring had no failure reason");

        if (validation_failures != "")
            `uvm_fatal("ENV_VALIDATE", validation_failures)

        lifecycle_adapter = mailbox_mock_adapter::type_id::create("lifecycle_adapter");
        lifecycle_cfg = make_queue_cfg("lifecycle_cfg", GQ_TX, 77, 32, 64);
        lifecycle_cfg.status_area_size = 128;
        lifecycle_cfg.initial_logical_seq = 7;
        uvm_config_db#(gq_queue_cfg)::set(this, "lifecycle_engine", "cfg", lifecycle_cfg);
        uvm_config_db#(host_mem_api)::set(this, "lifecycle_engine", "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "lifecycle_engine", "adapter",
                                           lifecycle_adapter);
        lifecycle_engine = gq_queue_engine::type_id::create("lifecycle_engine", this);

        env_cfg = mailbox_env_cfg::type_id::create("env_cfg");
        env_cfg.mem       = mem;
        env_cfg.adapter   = adapter;

        if (!env_cfg.add_tx(3, 32, reason))
            `uvm_fatal("MAILBOX_CFG", reason)
        if (!env_cfg.add_tx(100, 32, reason))
            `uvm_fatal("MAILBOX_CFG", reason)
        if (!env_cfg.add_rx(9, 64, reason))
            `uvm_fatal("MAILBOX_CFG", reason)
        if (env_cfg.add_tx(3, 32, reason))
            `uvm_fatal("MAILBOX_CFG", "accepted duplicate TX queue")
        if (env_cfg.add_tx(4096, 32, reason))
            `uvm_fatal("MAILBOX_CFG", "accepted mailbox queue ID 4096")
        if (env_cfg.add_rx(0, 16, reason))
            `uvm_fatal("MAILBOX_CFG", "accepted mailbox depth below 32")
        if (env_cfg.add_rx(0, 48, reason))
            `uvm_fatal("MAILBOX_CFG", "accepted non-power-of-two mailbox depth")
        if (env_cfg.add_rx(0, 65536, reason))
            `uvm_fatal("MAILBOX_CFG", "accepted mailbox depth above 32768")
        env_cfg.ptr_codec = ptr_codec;

        disabled_cfg = mailbox_env_cfg::type_id::create("disabled_cfg");
        disabled_cfg.mem       = mem;
        disabled_cfg.adapter   = adapter;
        disabled_cfg.ptr_codec = ptr_codec;

        uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", env_cfg);
        uvm_config_db#(gq_env_cfg)::set(this, "disabled_env", "cfg", disabled_cfg);
        env          = mailbox_env::type_id::create("env", this);
        disabled_env = mailbox_env::type_id::create("disabled_env", this);
    endfunction

    task run_phase(uvm_phase phase);
        gq_addr_t tx3_base;
        gq_addr_t tx100_base;
        gq_addr_t rx9_base;
        bit irq_wait_returned;
        uvm_component default_component;
        gq_queue_engine default_engine;
        int unsigned lifecycle_disable_before_cleanup;

        phase.raise_objection(this);
        env_cfg.wait_ready();
        disabled_cfg.wait_ready();

        if (env.agent_count() != 3)
            `uvm_fatal("SPARSE", $sformatf("got %0d agents expected 3", env.agent_count()))
        if (disabled_env.agent_count() != 0)
            `uvm_fatal("SPARSE", "disabled environment created an agent")
        if (!env.has_agent("tx_3") || !env.has_agent("tx_100") ||
            !env.has_agent("rx_9") || env.has_agent("tx_4"))
            `uvm_fatal("SPARSE", "sparse agent keys are incorrect")

        default_component = uvm_root::get().find("uvm_test_top.env.tx_3.engine");
        if (!$cast(default_engine, default_component) ||
            default_engine.head_seq() != 0 || default_engine.tail_seq() != 0)
            `uvm_fatal("CFG_INITIAL_SEQ", "default GQ queue did not start at zero")

        if (env.ring_size("tx_3") != 2048 ||
            env.ring_size("tx_100") != 2048 ||
            env.ring_size("rx_9") != 1024)
            `uvm_fatal("RING_SIZE", "allocated ring size is incorrect")

        tx3_base   = env.ring_base("tx_3");
        tx100_base = env.ring_base("tx_100");
        rx9_base   = env.ring_base("rx_9");
        if (tx3_base == 0 || tx100_base == 0 || rx9_base == 0 ||
            tx3_base == '1 || tx100_base == '1 || rx9_base == '1)
            `uvm_fatal("RING_BASE", "invalid ring base")
        if (tx3_base[63:32] == 0 || tx100_base[63:32] == 0 || rx9_base[63:32] == 0)
            `uvm_fatal("RING_BASE", "ring base lost its upper 32 bits")
        if (ranges_overlap(tx3_base, 2048, tx100_base, 2048) ||
            ranges_overlap(tx3_base, 2048, rx9_base, 1024) ||
            ranges_overlap(tx100_base, 2048, rx9_base, 1024))
            `uvm_fatal("RING_BASE", "queue ring allocations overlap")

        if (adapter.configure_calls != 3)
            `uvm_fatal("ADAPTER", $sformatf("got %0d configure calls expected 3",
                                             adapter.configure_calls))
        if (adapter.configure_count["tx_3"] != 1 ||
            adapter.configure_count["tx_100"] != 1 ||
            adapter.configure_count["rx_9"] != 1)
            `uvm_fatal("ADAPTER", "per-queue configure counts are incorrect")
        if (adapter.configured_base["tx_3"] != tx3_base ||
            adapter.configured_base["tx_100"] != tx100_base ||
            adapter.configured_base["rx_9"] != rx9_base)
            `uvm_fatal("ADAPTER", "configured bases do not match engine bases")
        if (adapter.configured_depth["tx_3"] != 32 ||
            adapter.configured_depth["tx_100"] != 32 ||
            adapter.configured_depth["rx_9"] != 64)
            `uvm_fatal("ADAPTER", "configured depths are incorrect")
        if (adapter.configured_desc_size["tx_3"] != 64 ||
            adapter.configured_desc_size["tx_100"] != 64 ||
            adapter.configured_desc_size["rx_9"] != 16)
            `uvm_fatal("ADAPTER", "mailbox descriptor sizes are incorrect")

        adapter.trigger_irq(GQ_TX, 3);
        irq_wait_returned = 0;
        fork : irq_wait_or_timeout
            begin
                adapter.wait_irq(GQ_TX, 3);
                irq_wait_returned = 1;
            end
            begin
                #1ns;
            end
        join_any
        disable irq_wait_or_timeout;
        if (!irq_wait_returned)
            `uvm_fatal("IRQ", "wait_irq missed an interrupt triggered before the wait")

        adapter.ack_irq(GQ_TX, 3);
        if (adapter.irq_events["tx_3"].is_on())
            `uvm_fatal("IRQ", "ack_irq did not clear the persistent interrupt")
        adapter.trigger_irq(GQ_TX, 3);
        adapter.disable_queue(GQ_TX, 3);
        if (adapter.irq_events["tx_3"].is_on())
            `uvm_fatal("IRQ", "disable_queue did not clear the persistent interrupt")

        lifecycle_engine.initialize();
        if (lifecycle_engine.head_seq() != 7 || lifecycle_engine.tail_seq() != 7 ||
            lifecycle_engine.outstanding_count() != 0)
            `uvm_fatal("CFG_INITIAL_SEQ", "initialize did not apply initial logical sequence")
        if (lifecycle_engine.ring_size() != 2176)
            `uvm_fatal("LIFECYCLE", "status-area ring allocation size is incorrect")
        if (lifecycle_engine.status_addr() != lifecycle_engine.ring_base() + 2048)
            `uvm_fatal("LIFECYCLE", "status address does not follow the descriptor ring")
        if (lifecycle_adapter.configure_calls != 1)
            `uvm_fatal("LIFECYCLE", "first initialize did not configure exactly once")
        lifecycle_engine.initialize();
        if (lifecycle_adapter.configure_calls != 1)
            `uvm_fatal("LIFECYCLE", "idempotent initialize configured the queue again")
        lifecycle_engine.assert_reset();
        if (lifecycle_engine.head_seq() != 7 || lifecycle_engine.tail_seq() != 7 ||
            lifecycle_engine.outstanding_count() != 0)
            `uvm_fatal("CFG_INITIAL_SEQ", "assert reset did not restore initial logical sequence")
        lifecycle_engine.release_reset();
        if (lifecycle_engine.head_seq() != 7 || lifecycle_engine.tail_seq() != 7 ||
            lifecycle_engine.outstanding_count() != 0)
            `uvm_fatal("CFG_INITIAL_SEQ", "release reset did not preserve initial logical sequence")
        lifecycle_disable_before_cleanup = lifecycle_adapter.disable_calls;
        lifecycle_engine.cleanup();
        if (lifecycle_adapter.disable_calls !=
            lifecycle_disable_before_cleanup + 1)
            `uvm_fatal("LIFECYCLE", "cleanup did not disable the queue exactly once")
        if (lifecycle_engine.head_seq() != 7 || lifecycle_engine.tail_seq() != 7 ||
            lifecycle_engine.outstanding_count() != 0)
            `uvm_fatal("CFG_INITIAL_SEQ", "cleanup did not restore initial logical sequence")
        lifecycle_engine.cleanup();
        if (lifecycle_adapter.disable_calls !=
            lifecycle_disable_before_cleanup + 1)
            `uvm_fatal("LIFECYCLE", "idempotent cleanup disabled the queue more than once")

        lifecycle_engine.initialize();
        if (lifecycle_engine.ring_size() != 2176 ||
            lifecycle_engine.status_addr() != lifecycle_engine.ring_base() + 2048 ||
            lifecycle_adapter.configure_calls != 3)
            `uvm_fatal("LIFECYCLE", "sequential reinitialize did not recreate the ring")
        lifecycle_disable_before_cleanup = lifecycle_adapter.disable_calls;
        lifecycle_engine.cleanup();
        if (lifecycle_adapter.disable_calls !=
            lifecycle_disable_before_cleanup + 1)
            `uvm_fatal("LIFECYCLE", "second cleanup did not disable the queue exactly once")
        lifecycle_engine.cleanup();
        if (lifecycle_adapter.disable_calls !=
            lifecycle_disable_before_cleanup + 1)
            `uvm_fatal("LIFECYCLE", "second idempotent cleanup count is incorrect")

        env.cleanup();
        disabled_env.cleanup();
        mem.leak_check(`__FILE__, `__LINE__);
        phase.drop_objection(this);
    endtask
endclass

`endif
