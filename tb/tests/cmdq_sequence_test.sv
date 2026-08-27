`ifndef CMDQ_SEQUENCE_TEST_SV
`define CMDQ_SEQUENCE_TEST_SV

class cmdq_wrong_adapter extends gq_hw_adapter;
    `uvm_object_utils(cmdq_wrong_adapter)

    function new(string name = "cmdq_wrong_adapter");
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

class cmdq_sequence_test extends uvm_test;
    `uvm_component_utils(cmdq_sequence_test)

    function new(string name = "cmdq_sequence_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function gq_queue_cfg make_irq_cfg(int unsigned queue_id);
        gq_queue_cfg cfg;

        cfg = gq_queue_cfg::type_id::create(
            $sformatf("tx_%0d_irq_cfg", queue_id));
        cfg.queue_id              = queue_id;
        cfg.role                  = GQ_TX;
        cfg.depth                 = 32;
        cfg.desc_size             = 32;
        cfg.alignment             = 64;
        cfg.status_area_size      = 0;
        cfg.wait_mode             = GQ_IRQ;
        cfg.poll_policy           = GQ_POLL_ADAPTIVE;
        cfg.poll_min_interval     = 10ns;
        cfg.poll_max_interval     = 100ns;
        cfg.poll_backoff_factor   = 2;
        cfg.irq_watchdog_interval = 1us;
        cfg.completion_timeout    = 10us;
        cfg.ptr_codec = cmdq_ptr_codec::type_id::create(
            $sformatf("tx_%0d_irq_ptr_codec", queue_id));
        cfg.completion_source = cmdq_completion::type_id::create(
            $sformatf("tx_%0d_irq_completion", queue_id));
        return cfg;
    endfunction

    function void build_phase(uvm_phase phase);
        host_mem_manager mem;
        cmdq_env_cfg env_cfg;
        cmdq_env_cfg null_adapter_cfg;
        cmdq_env_cfg wrong_adapter_cfg;
        cmdq_env_cfg irq_env_cfg;
        cmdq_mock_adapter adapter;
        cmdq_mock_adapter irq_adapter;
        cmdq_wrong_adapter wrong_adapter;
        cmdq_hw_cfg_t hw_cfg;
        cmdq_hw_cfg_t duplicate_hw_cfg;
        gq_queue_cfg cfg;
        gq_queue_cfg irq_cfg;
        cmdq_ptr_codec installed_codec;
        cmdq_completion installed_completion;
        string reason;
        string key;
        int unsigned queue_count;

        super.build_phase(phase);
        mem = new("mem");
        adapter = cmdq_mock_adapter::type_id::create("adapter");
        env_cfg = cmdq_env_cfg::type_id::create("env_cfg");
        env_cfg.mem = mem;
        env_cfg.adapter = adapter;
        hw_cfg.host_id     = 8'h5a;
        hw_cfg.function_id = 16'h1234;
        hw_cfg.msix_index  = 16'h4567;
        hw_cfg.msix_valid  = 1'b1;

        if (!env_cfg.add_cmdq(0, hw_cfg, reason))
            `uvm_fatal("CMDQ_PROFILE_ADD", {"standard queue rejected: ", reason})
        key = gq_queue_key(GQ_TX, 0);
        if (!env_cfg.queues.exists(key) || env_cfg.queues[key] == null)
            `uvm_fatal("CMDQ_PROFILE_QUEUE", "standard TX queue is absent")
        cfg = env_cfg.queues[key];
        if (cfg.role != GQ_TX || cfg.queue_id != 0 ||
            cfg.depth != 32 || cfg.desc_size != 32 ||
            cfg.alignment != 64 || cfg.status_area_size != 0 ||
            cfg.wait_mode != GQ_POLL ||
            cfg.poll_policy != GQ_POLL_ADAPTIVE ||
            cfg.poll_min_interval != 10ns ||
            cfg.poll_max_interval != 100ns ||
            cfg.poll_backoff_factor != 2 ||
            cfg.irq_watchdog_interval != 0 ||
            cfg.completion_timeout != 10us)
            `uvm_fatal("CMDQ_PROFILE_DEFAULTS",
                       "standard queue values do not match the CMDQ profile")
        if (!$cast(installed_codec, cfg.ptr_codec) ||
            !$cast(installed_completion, cfg.completion_source))
            `uvm_fatal("CMDQ_PROFILE_TYPES",
                       "standard queue did not install concrete CMDQ strategies")
        if (adapter.hw_cfg != hw_cfg)
            `uvm_fatal("CMDQ_PROFILE_METADATA",
                       "hardware metadata was not copied into the CMDQ adapter")
        if (!env_cfg.validate(reason))
            `uvm_fatal("CMDQ_PROFILE_VALIDATE",
                       {"standard environment rejected: ", reason})
        if (adapter.trace.size() != 0)
            `uvm_fatal("CMDQ_PROFILE_PROGRAMMED",
                       "profile construction or validation programmed hardware")

        duplicate_hw_cfg.host_id     = 8'ha5;
        duplicate_hw_cfg.function_id = 16'hfedc;
        duplicate_hw_cfg.msix_index  = 16'h7654;
        duplicate_hw_cfg.msix_valid  = 1'b0;
        queue_count = env_cfg.queues.num();
        if (env_cfg.add_cmdq(0, duplicate_hw_cfg, reason) || reason == "")
            `uvm_fatal("CMDQ_PROFILE_DUPLICATE",
                       "duplicate queue was not rejected with a reason")
        if (env_cfg.queues.num() != queue_count || adapter.hw_cfg != hw_cfg)
            `uvm_fatal("CMDQ_PROFILE_DUPLICATE_STATE",
                       "duplicate rejection changed queue or metadata state")

        null_adapter_cfg = cmdq_env_cfg::type_id::create("null_adapter_cfg");
        null_adapter_cfg.mem = mem;
        if (null_adapter_cfg.add_cmdq(1, hw_cfg, reason) || reason == "" ||
            null_adapter_cfg.queues.num() != 0)
            `uvm_fatal("CMDQ_PROFILE_NULL_ADAPTER",
                       "null adapter rejection left partial queue state")

        wrong_adapter = cmdq_wrong_adapter::type_id::create("wrong_adapter");
        wrong_adapter_cfg = cmdq_env_cfg::type_id::create("wrong_adapter_cfg");
        wrong_adapter_cfg.mem = mem;
        wrong_adapter_cfg.adapter = wrong_adapter;
        if (wrong_adapter_cfg.add_cmdq(2, hw_cfg, reason) || reason == "" ||
            wrong_adapter_cfg.queues.num() != 0)
            `uvm_fatal("CMDQ_PROFILE_WRONG_ADAPTER",
                       "wrong adapter rejection left partial queue state")

        irq_adapter = cmdq_mock_adapter::type_id::create("irq_adapter");
        irq_env_cfg = cmdq_env_cfg::type_id::create("irq_env_cfg");
        irq_env_cfg.mem = mem;
        irq_env_cfg.adapter = irq_adapter;
        irq_cfg = make_irq_cfg(3);
        if (!irq_env_cfg.add_queue(irq_cfg, reason) ||
            !irq_env_cfg.validate(reason))
            `uvm_fatal("CMDQ_PROFILE_IRQ",
                       {"public IRQ override rejected: ", reason})
        if (irq_cfg.wait_mode != GQ_IRQ ||
            irq_cfg.irq_watchdog_interval != 1us)
            `uvm_fatal("CMDQ_PROFILE_IRQ_VALUES",
                       "IRQ override lost its explicit watchdog")
        if (irq_adapter.trace.size() != 0)
            `uvm_fatal("CMDQ_PROFILE_IRQ_PROGRAMMED",
                       "IRQ profile validation programmed hardware")
    endfunction
endclass

`endif
