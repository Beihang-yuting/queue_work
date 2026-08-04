`ifndef GQ_CONFIG_TEST_SVH
`define GQ_CONFIG_TEST_SVH

class gq_config_test extends uvm_test;
    `uvm_component_utils(gq_config_test)

    host_mem_manager    mem;
    gq_test_ptr_codec   ptr_codec;
    mailbox_mock_adapter adapter;
    mailbox_env_cfg     env_cfg;
    mailbox_env_cfg     disabled_cfg;
    mailbox_env         env;
    mailbox_env         disabled_env;

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

    function void build_phase(uvm_phase phase);
        gq_queue_cfg cfg;
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

        cfg = gq_queue_cfg::type_id::create("cfg");
        cfg.queue_id           = 7;
        cfg.role               = GQ_TX;
        cfg.depth              = 48;
        cfg.desc_size          = 64;
        cfg.alignment          = 16;
        cfg.status_area_size   = 64;
        cfg.wait_mode          = GQ_POLL;
        cfg.poll_interval      = 10ns;
        cfg.completion_timeout = 1us;
        expect_invalid(cfg, "depth 48");

        cfg.depth = 32;
        if (!cfg.validate(reason))
            `uvm_fatal("CFG", reason)

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

        cfg.poll_interval = 0;
        expect_invalid(cfg, "zero poll interval");
        cfg.poll_interval = 10ns;

        cfg.completion_timeout = 0;
        expect_invalid(cfg, "zero completion timeout");

        mem = new("mem");
        mem.init_region(64'h0000_0001_0000_0000,
                        64'h0000_0001_00ff_ffff, MODE_LINEAR, 16);
        ptr_codec = gq_test_ptr_codec::type_id::create("ptr_codec");
        adapter   = mailbox_mock_adapter::type_id::create("adapter");

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
        if (env_cfg.add_rx(0, 131072, reason))
            `uvm_fatal("MAILBOX_CFG", "accepted mailbox depth above 65536")
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

        env.cleanup();
        disabled_env.cleanup();
        mem.leak_check(`__FILE__, `__LINE__);
        phase.drop_objection(this);
    endtask
endclass

`endif
