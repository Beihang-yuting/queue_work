`ifndef TLPQ_DRIVER_CONFORMANCE_TEST_SV
`define TLPQ_DRIVER_CONFORMANCE_TEST_SV

class tlpq_wrong_adapter extends gq_hw_adapter;
    `uvm_object_utils(tlpq_wrong_adapter)

    function new(string name = "tlpq_wrong_adapter");
        super.new(name);
    endfunction

    virtual task configure_queue(
        gq_role_e role, int unsigned queue_id, gq_addr_t base,
        int unsigned depth, int unsigned desc_size);
    endtask

    virtual task disable_queue(gq_role_e role, int unsigned queue_id);
    endtask

    virtual task publish(
        gq_role_e role, int unsigned queue_id, gq_raw_ptr_t raw_tail);
    endtask

    virtual task wait_irq(gq_role_e role, int unsigned queue_id);
    endtask

    virtual task ack_irq(gq_role_e role, int unsigned queue_id);
    endtask
endclass

class tlpq_reg_error_catcher extends uvm_report_catcher;
    `uvm_object_utils(tlpq_reg_error_catcher)

    int unsigned role_errors;
    int unsigned queue_errors;
    int unsigned pointer_errors;

    function new(string name = "tlpq_reg_error_catcher");
        super.new(name);
        role_errors = 0;
        queue_errors = 0;
        pointer_errors = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR && get_id() == "TLPQ_REG_ROLE") begin
            role_errors++;
            return CAUGHT;
        end
        if (get_severity() == UVM_ERROR && get_id() == "TLPQ_REG_QUEUE") begin
            queue_errors++;
            return CAUGHT;
        end
        if (get_severity() == UVM_ERROR && get_id() == "TLPQ_REG_PTR") begin
            pointer_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class tlpq_driver_conformance_test extends uvm_test;
    `uvm_component_utils(tlpq_driver_conformance_test)

    localparam gq_addr_t HOST_BASE   = 64'h0000_0001_e000_0000;
    localparam gq_addr_t SWITCH_BASE = 64'h0000_0001_e001_0000;

    host_mem_manager mem;
    tlpq_mock_adapter adapter;
    tlpq_env_cfg env_cfg;
    gq_queue_cfg host_cfg;
    gq_queue_cfg switch_cfg;
    tlpq_refill_profile host_profile;
    tlpq_refill_profile switch_profile;
    tlpq_rx_hw_cfg_t host_hw_cfg;
    tlpq_rx_hw_cfg_t switch_hw_cfg;

    function new(string name = "tlpq_driver_conformance_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void check_defaults();
        string reason;

        host_cfg = env_cfg.get_tlpq_rx_cfg(TLPQ_HOST);
        switch_cfg = env_cfg.get_tlpq_rx_cfg(TLPQ_SWITCH);
        host_profile = env_cfg.get_refill_profile(TLPQ_HOST);
        switch_profile = env_cfg.get_refill_profile(TLPQ_SWITCH);

        if (host_cfg == null || switch_cfg == null ||
            host_cfg == switch_cfg ||
            host_cfg.queue_id != TLPQ_HOST_QUEUE_ID ||
            switch_cfg.queue_id != TLPQ_SWITCH_QUEUE_ID ||
            host_cfg.role != GQ_RX || switch_cfg.role != GQ_RX ||
            host_cfg.depth != 32 || switch_cfg.depth != 32 ||
            host_cfg.desc_size != 16 || switch_cfg.desc_size != 16 ||
            host_cfg.rx_slot_mode != GQ_RX_EXPLICIT_REFILL ||
            switch_cfg.rx_slot_mode != GQ_RX_EXPLICIT_REFILL ||
            host_cfg.wait_mode != GQ_IRQ || switch_cfg.wait_mode != GQ_IRQ ||
            host_cfg.poll_policy != GQ_POLL_ADAPTIVE ||
            switch_cfg.poll_policy != GQ_POLL_ADAPTIVE ||
            host_cfg.poll_min_interval != 50ns ||
            switch_cfg.poll_min_interval != 50ns ||
            host_cfg.poll_max_interval != 500ns ||
            switch_cfg.poll_max_interval != 500ns ||
            host_cfg.irq_watchdog_interval != 1us ||
            switch_cfg.irq_watchdog_interval != 1us ||
            host_cfg.completion_timeout != 0 ||
            switch_cfg.completion_timeout != 0)
            `uvm_fatal("TLPQ_DEFAULT_CFG",
                       "Host/Switch standard RX queue defaults diverged")

        if (host_cfg.ptr_codec == null || switch_cfg.ptr_codec == null ||
            host_cfg.ptr_codec == switch_cfg.ptr_codec ||
            host_cfg.completion_source == null ||
            switch_cfg.completion_source == null ||
            host_cfg.completion_source == switch_cfg.completion_source ||
            host_profile == null || switch_profile == null ||
            host_profile == switch_profile ||
            host_profile.initial_post_count != 31 ||
            switch_profile.initial_post_count != 31 ||
            host_profile.low_watermark != 30 ||
            switch_profile.low_watermark != 30 ||
            host_profile.high_watermark != 31 ||
            switch_profile.high_watermark != 31 ||
            host_profile.max_refill_batch != 1 ||
            switch_profile.max_refill_batch != 1 ||
            !host_profile.restart_after_reset ||
            !switch_profile.restart_after_reset)
            `uvm_fatal("TLPQ_DEFAULT_ISOLATION",
                       "Host/Switch strategies or refill profiles are shared")

        host_cfg.wait_mode = GQ_POLL;
        host_cfg.poll_policy = GQ_POLL_FIXED;
        host_cfg.poll_max_interval = host_cfg.poll_min_interval;
        if (!env_cfg.validate(reason))
            `uvm_fatal("TLPQ_POLL_FIXED",
                       {"fixed Poll selection was rejected: ", reason})
        host_cfg.poll_policy = GQ_POLL_ADAPTIVE;
        host_cfg.poll_max_interval = 500ns;
        if (!env_cfg.validate(reason))
            `uvm_fatal("TLPQ_POLL_ADAPTIVE",
                       {"adaptive Poll selection was rejected: ", reason})
        host_cfg.wait_mode = GQ_IRQ;
    endfunction

    task check_channel_setup(
        tlpq_channel_e channel, int unsigned queue_id,
        gq_addr_t base, tlpq_rx_hw_cfg_t hw_cfg);
        string expected_trace[$];
        string channel_name;
        int channel_key;

        channel_name = channel == TLPQ_HOST ? "HOST" : "SWITCH";
        channel_key = int'(channel);
        expected_trace.push_back($sformatf(
            "RESET(channel=%s)", channel_name));
        expected_trace.push_back($sformatf(
            {"CONFIGURE(channel=%s,base=0x%016h,depth=32,size=16,",
             "host_id=0x%01h,bdf=0x%04h,msix=0x%04h,valid=%0b)"},
            channel_name, base, hw_cfg.host_id, hw_cfg.bdf,
            hw_cfg.msix_index, hw_cfg.msix_valid));
        expected_trace.push_back($sformatf(
            "PUBLISH(channel=%s,tail=31)", channel_name));
        expected_trace.push_back($sformatf(
            "ENABLE(channel=%s)", channel_name));

        adapter.clear_trace(channel);
        adapter.configure_queue(GQ_RX, queue_id, base, 32, 16);
        if (adapter.enable_count[channel_key] != 0)
            `uvm_fatal("TLPQ_EARLY_ENABLE",
                       "configure_queue enabled RX before initial publish")
        adapter.publish(GQ_RX, queue_id, 32'h0000_001f);
        if (adapter.trace[channel_key] != expected_trace)
            `uvm_fatal("TLPQ_SETUP_TRACE", $sformatf(
                "%s trace was not RESET,CONFIGURE,PUBLISH,ENABLE",
                channel_name))
        if (adapter.reset_count[channel_key] != 1 ||
            adapter.configure_count[channel_key] != 1 ||
            adapter.enable_count[channel_key] != 1 ||
            adapter.configured_base[channel_key] != base ||
            adapter.configured_depth[channel_key] != 32 ||
            adapter.configured_desc_size[channel_key] != 16 ||
            adapter.configured_hw_cfg[channel_key] != hw_cfg ||
            adapter.published_tails[channel_key].size() != 1 ||
            adapter.published_tails[channel_key][0] != 16'h001f)
            `uvm_fatal("TLPQ_SETUP_ARGS", $sformatf(
                "%s setup arguments/counters diverged", channel_name))

        adapter.publish(GQ_RX, queue_id, 32'h0000_001e);
        if (adapter.enable_count[channel_key] != 1 ||
            adapter.published_tails[channel_key].size() != 2)
            `uvm_fatal("TLPQ_ENABLE_ON_REFILL",
                       "refill publish repeated the deferred enable")
    endtask

    task check_reconfigure_rearms();
        int host_key;
        int switch_key;

        host_key = int'(TLPQ_HOST);
        switch_key = int'(TLPQ_SWITCH);
        adapter.clear_trace(TLPQ_HOST);
        adapter.configure_queue(GQ_RX, TLPQ_HOST_QUEUE_ID,
                                HOST_BASE, 32, 16);
        if (adapter.enable_count[host_key] != 1)
            `uvm_fatal("TLPQ_RECONFIG_EARLY_ENABLE",
                       "reconfigure enabled Host before its next publish")
        adapter.publish(GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0000_001f);
        if (adapter.enable_count[host_key] != 2 ||
            adapter.enable_count[switch_key] != 1)
            `uvm_fatal("TLPQ_RECONFIG_REARM",
                       "Host reconfigure did not rearm exactly Host enable")
    endtask

    task check_irq_isolation();
        int host_key;
        int switch_key;
        int switch_trace_before;

        host_key = int'(TLPQ_HOST);
        switch_key = int'(TLPQ_SWITCH);
        switch_trace_before = adapter.trace[switch_key].size();
        adapter.trigger_irq(TLPQ_HOST);
        adapter.wait_irq(GQ_RX, TLPQ_HOST_QUEUE_ID);
        adapter.ack_irq(GQ_RX, TLPQ_HOST_QUEUE_ID);
        if (adapter.wait_irq_count[host_key] != 1 ||
            adapter.ack_irq_count[host_key] != 1 ||
            adapter.wait_irq_count[switch_key] != 0 ||
            adapter.ack_irq_count[switch_key] != 0 ||
            adapter.trace[switch_key].size() != switch_trace_before)
            `uvm_fatal("TLPQ_IRQ_ISOLATION",
                       "Host IRQ activity crossed into Switch state")
    endtask

    task check_generic_rejections();
        tlpq_reg_error_catcher catcher;
        int host_trace_before;
        int switch_trace_before;

        host_trace_before = adapter.trace[int'(TLPQ_HOST)].size();
        switch_trace_before = adapter.trace[int'(TLPQ_SWITCH)].size();
        catcher = tlpq_reg_error_catcher::type_id::create("catcher");
        uvm_report_cb::add(null, catcher);
        adapter.configure_queue(GQ_TX, TLPQ_HOST_QUEUE_ID,
                                HOST_BASE, 32, 16);
        adapter.disable_queue(GQ_TX, TLPQ_HOST_QUEUE_ID);
        adapter.publish(GQ_TX, TLPQ_HOST_QUEUE_ID, 32'h0000_0001);
        adapter.wait_irq(GQ_TX, TLPQ_HOST_QUEUE_ID);
        adapter.ack_irq(GQ_TX, TLPQ_HOST_QUEUE_ID);
        adapter.configure_queue(GQ_RX, 99, HOST_BASE, 32, 16);
        adapter.disable_queue(GQ_RX, 99);
        adapter.publish(GQ_RX, 99, 32'h0000_0001);
        adapter.wait_irq(GQ_RX, 99);
        adapter.ack_irq(GQ_RX, 99);
        adapter.publish(GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0001_001f);
        uvm_report_cb::delete(null, catcher);

        if (catcher.role_errors != 5 || catcher.queue_errors != 5 ||
            catcher.pointer_errors != 1)
            `uvm_fatal("TLPQ_GENERIC_REJECT", $sformatf(
                "role/queue/pointer rejection counts were %0d/%0d/%0d",
                catcher.role_errors, catcher.queue_errors,
                catcher.pointer_errors))
        if (adapter.trace[int'(TLPQ_HOST)].size() != host_trace_before ||
            adapter.trace[int'(TLPQ_SWITCH)].size() != switch_trace_before)
            `uvm_fatal("TLPQ_GENERIC_LEAK",
                       "rejected generic operation reached semantic callback")
    endtask

    task run_phase(uvm_phase phase);
        string reason;
        tlpq_env_cfg duplicate_cfg;
        tlpq_env_cfg wrong_cfg;
        tlpq_wrong_adapter wrong_adapter;

        phase.raise_objection(this);
        mem = new("mem");
        mem.init_region(64'h0000_0001_e000_0000,
                        64'h0000_0001_e0ff_ffff, MODE_LINEAR, 16);
        adapter = tlpq_mock_adapter::type_id::create("adapter");
        env_cfg = tlpq_env_cfg::type_id::create("env_cfg");
        env_cfg.mem = mem;
        env_cfg.adapter = adapter;
        host_hw_cfg = '{host_id:3'h1, bdf:16'h0100,
                        msix_index:13'h011, msix_valid:1'b1};
        switch_hw_cfg = '{host_id:3'h5, bdf:16'h0201,
                          msix_index:13'h122, msix_valid:1'b1};
        if (!env_cfg.add_tlpq_rx(TLPQ_HOST, TLPQ_HOST_QUEUE_ID,
                                 host_hw_cfg, reason) ||
            !env_cfg.add_tlpq_rx(TLPQ_SWITCH, TLPQ_SWITCH_QUEUE_ID,
                                 switch_hw_cfg, reason) ||
            !env_cfg.validate(reason))
            `uvm_fatal("TLPQ_VALID_CFG",
                       {"valid dual-RX environment rejected: ", reason})

        check_defaults();
        check_channel_setup(TLPQ_HOST, TLPQ_HOST_QUEUE_ID,
                            HOST_BASE, host_hw_cfg);
        check_channel_setup(TLPQ_SWITCH, TLPQ_SWITCH_QUEUE_ID,
                            SWITCH_BASE, switch_hw_cfg);
        check_reconfigure_rearms();
        check_irq_isolation();
        check_generic_rejections();

        duplicate_cfg = tlpq_env_cfg::type_id::create("duplicate_cfg");
        duplicate_cfg.mem = mem;
        duplicate_cfg.adapter = tlpq_mock_adapter::type_id::create(
            "duplicate_adapter");
        if (!duplicate_cfg.add_tlpq_rx(TLPQ_HOST, 10,
                                       host_hw_cfg, reason) ||
            duplicate_cfg.add_tlpq_rx(TLPQ_HOST, 11,
                                       switch_hw_cfg, reason) ||
            duplicate_cfg.add_tlpq_rx(TLPQ_SWITCH, 10,
                                       switch_hw_cfg, reason))
            `uvm_fatal("TLPQ_DUPLICATE",
                       "duplicate channel or queue ID was accepted")

        wrong_adapter = tlpq_wrong_adapter::type_id::create("wrong_adapter");
        wrong_cfg = tlpq_env_cfg::type_id::create("wrong_cfg");
        wrong_cfg.mem = mem;
        wrong_cfg.adapter = wrong_adapter;
        if (wrong_cfg.add_tlpq_rx(TLPQ_HOST, 20, host_hw_cfg, reason) ||
            wrong_cfg.validate(reason))
            `uvm_fatal("TLPQ_ADAPTER_TYPE",
                       "non-TLPQ adapter was accepted")

        phase.drop_objection(this);
    endtask
endclass

`endif
