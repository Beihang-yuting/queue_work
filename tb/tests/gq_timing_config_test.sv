// tb/tests/gq_timing_config_test.sv: UVM 测试 gq_timing_config_test：验证对应队列组件的定向行为和接口契约。
`ifndef GQ_TIMING_CONFIG_TEST_SV
`define GQ_TIMING_CONFIG_TEST_SV

class gq_cfg_timeout_catcher extends uvm_report_catcher;
    `uvm_object_utils(gq_cfg_timeout_catcher)

    int unsigned timeout_warning_count;

    function new(string name = "gq_cfg_timeout_catcher");
        super.new(name);
        timeout_warning_count = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_WARNING && get_id() == "GQ_CFG_TIMEOUT") begin
            timeout_warning_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class gq_timing_config_test extends uvm_test;
    `uvm_component_utils(gq_timing_config_test)

    gq_cfg_timeout_catcher timeout_catcher;

    function new(string name = "gq_timing_config_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function gq_queue_cfg make_valid_cfg(string name, gq_role_e role = GQ_TX);
        gq_queue_cfg cfg;

        cfg = gq_queue_cfg::type_id::create(name);
        cfg.queue_id             = 1;
        cfg.role                 = role;
        cfg.depth                = 32;
        cfg.desc_size            = 64;
        cfg.alignment            = 64;
        cfg.status_area_size     = 0;
        cfg.wait_mode            = GQ_POLL;
        cfg.poll_policy          = GQ_POLL_ADAPTIVE;
        cfg.poll_min_interval    = 10ns;
        cfg.poll_max_interval    = 100ns;
        cfg.poll_backoff_factor  = 2;
        cfg.irq_watchdog_interval = 1us;
        cfg.completion_timeout   = 10us;
        cfg.rx_slot_mode         = GQ_RX_EXPLICIT_REFILL;
        cfg.ptr_codec            = gq_test_ptr_codec::type_id::create(
            {name, "_ptr_codec"});
        cfg.completion_source    = mailbox_completion::type_id::create(
            {name, "_completion"});
        return cfg;
    endfunction

    function void expect_valid(gq_queue_cfg cfg, string check_name);
        string reason;

        if (!cfg.validate(reason))
            `uvm_fatal("TIMING_CFG", $sformatf(
                "%s was rejected: %s", check_name, reason))
    endfunction

    function void expect_invalid(gq_queue_cfg cfg, string check_name);
        string reason;

        if (cfg.validate(reason))
            `uvm_fatal("TIMING_CFG", $sformatf(
                "%s was accepted", check_name))
        if (reason == "")
            `uvm_fatal("TIMING_CFG", $sformatf(
                "%s had no validation reason", check_name))
    endfunction

    function void build_phase(uvm_phase phase);
        gq_queue_cfg cfg;
        mailbox_refill_profile profile;
        gq_refill_profile cloned_base;
        mailbox_refill_profile cloned_profile;
        mailbox_tx_desc desc;
        host_mem_manager mem;
        gq_wakeup_e wakeup;

        super.build_phase(phase);

        cfg = gq_queue_cfg::type_id::create("default_cfg");
        if (cfg.poll_policy != GQ_POLL_FIXED ||
            cfg.poll_min_interval != 10ns ||
            cfg.poll_max_interval != 10ns ||
            cfg.poll_backoff_factor != 2 ||
            cfg.irq_watchdog_interval != 0 ||
            cfg.completion_timeout != 0 ||
            cfg.rx_slot_mode != GQ_RX_EXPLICIT_REFILL)
            `uvm_fatal("TIMING_DEFAULT", "queue timing/lifecycle defaults are incorrect")

        wakeup = GQ_WAKE_CANCELLED;
        if (int'(wakeup) != 0 || int'(GQ_WAKE_POLL) != 1 ||
            int'(GQ_WAKE_IRQ) != 2 || int'(GQ_WAKE_WATCHDOG) != 3 ||
            int'(GQ_WAKE_NEW_WORK) != 4)
            `uvm_fatal("TIMING_ENUM", "wakeup values or ordering are incorrect")

        cfg = make_valid_cfg("valid_matrix_cfg");
        expect_valid(cfg, "adaptive timing matrix");

        cfg = make_valid_cfg("zero_min_cfg");
        cfg.poll_min_interval = 0;
        expect_invalid(cfg, "zero poll minimum");

        cfg = make_valid_cfg("reversed_bounds_cfg");
        cfg.poll_max_interval = 9ns;
        expect_invalid(cfg, "poll maximum below minimum");

        cfg = make_valid_cfg("zero_factor_cfg");
        cfg.poll_backoff_factor = 0;
        expect_invalid(cfg, "poll backoff factor below one");

        cfg = make_valid_cfg("fixed_bounds_cfg");
        cfg.poll_policy = GQ_POLL_FIXED;
        expect_invalid(cfg, "unequal fixed poll bounds");

        cfg = make_valid_cfg("zero_tx_timeout_cfg");
        cfg.completion_timeout = 0;
        expect_invalid(cfg, "zero TX completion timeout");

        cfg = make_valid_cfg("short_tx_timeout_cfg");
        cfg.completion_timeout = 100ns;
        expect_invalid(cfg, "TX timeout not greater than poll maximum");

        cfg = make_valid_cfg("zero_rx_timeout_cfg", GQ_RX);
        cfg.completion_timeout = 0;
        expect_valid(cfg, "zero RX completion timeout");

        timeout_catcher = gq_cfg_timeout_catcher::type_id::create(
            "timeout_catcher");
        uvm_report_cb::add(null, timeout_catcher);
        cfg = make_valid_cfg("warning_cfg");
        cfg.completion_timeout = 250ns;
        expect_valid(cfg, "short nonzero timeout warning");
        uvm_report_cb::delete(null, timeout_catcher);
        if (timeout_catcher.timeout_warning_count != 1)
            `uvm_fatal("TIMING_WARNING", $sformatf(
                "expected one GQ_CFG_TIMEOUT warning, caught %0d",
                timeout_catcher.timeout_warning_count))

        profile = mailbox_refill_profile::type_id::create("profile");
        if (profile.max_refill_batch != 0)
            `uvm_fatal("REFILL_DEFAULT", "max refill batch default is not zero")
        profile.max_refill_batch = 1;
        cloned_base = profile.clone_profile();
        if (!$cast(cloned_profile, cloned_base) ||
            cloned_profile.max_refill_batch != 1)
            `uvm_fatal("REFILL_COPY", "max refill batch was not copied")

        mem = new("allocation_mem");
        mem.init_region(64'h0000_0001_7000_0000,
                        64'h0000_0001_7000_ffff, MODE_LINEAR, 16);
        desc = mailbox_tx_desc::type_id::create("allocation_desc");
        desc.attach_mem(mem);
        if (desc.owned_allocation_count() != 0)
            `uvm_fatal("ALLOCATION_COUNT", "new descriptor owns an allocation")
        if (desc.alloc_owned(16, 16) == '1 ||
            desc.owned_allocation_count() != 1)
            `uvm_fatal("ALLOCATION_COUNT", "owned allocation was not inspectable")
        desc.release_owned();
        if (desc.owned_allocation_count() != 0)
            `uvm_fatal("ALLOCATION_COUNT", "released allocation remains inspectable")
        mem.leak_check(`__FILE__, `__LINE__);
    endfunction
endclass

`endif
