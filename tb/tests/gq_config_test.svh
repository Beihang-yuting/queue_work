`ifndef GQ_CONFIG_TEST_SVH
`define GQ_CONFIG_TEST_SVH

class gq_config_test extends uvm_test;
    `uvm_component_utils(gq_config_test)

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
    endfunction
endclass

`endif
