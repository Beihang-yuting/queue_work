`ifndef CMDQ_ENV_SV
`define CMDQ_ENV_SV

class cmdq_env_cfg extends gq_env_cfg;
    `uvm_object_utils(cmdq_env_cfg)

    function new(string name = "cmdq_env_cfg");
        super.new(name);
    endfunction

    function bit add_cmdq(
        int unsigned queue_id,
        cmdq_hw_cfg_t hw_cfg,
        output string reason);
        string key;
        string queue_reason;
        cmdq_reg_adapter installed_adapter;
        gq_queue_cfg queue_cfg;

        if (adapter == null || !$cast(installed_adapter, adapter)) begin
            reason = "CMDQ adapter must derive from cmdq_reg_adapter";
            return 0;
        end

        key = gq_queue_key(GQ_TX, queue_id);
        if (queues.exists(key)) begin
            reason = $sformatf("duplicate queue %s", key);
            return 0;
        end
        if (queues.num() != 0) begin
            reason = "CMDQ environment supports exactly one queue";
            return 0;
        end

        queue_cfg = gq_queue_cfg::type_id::create(
            $sformatf("tx_%0d_cfg", queue_id));
        if (queue_cfg == null) begin
            reason = "CMDQ queue configuration creation failed";
            return 0;
        end
        queue_cfg.queue_id              = queue_id;
        queue_cfg.role                  = GQ_TX;
        queue_cfg.depth                 = CMDQ_DEPTH;
        queue_cfg.desc_size             = CMDQ_DESC_BYTES;
        queue_cfg.alignment             = 64;
        queue_cfg.status_area_size      = 0;
        queue_cfg.wait_mode             = GQ_POLL;
        queue_cfg.poll_policy           = GQ_POLL_ADAPTIVE;
        queue_cfg.poll_min_interval     = 10ns;
        queue_cfg.poll_max_interval     = 100ns;
        queue_cfg.poll_backoff_factor   = 2;
        queue_cfg.irq_watchdog_interval = 0;
        queue_cfg.completion_timeout    = 10us;
        queue_cfg.ptr_codec = cmdq_ptr_codec::type_id::create(
            $sformatf("tx_%0d_ptr_codec", queue_id));
        queue_cfg.completion_source = cmdq_completion::type_id::create(
            $sformatf("tx_%0d_completion", queue_id));

        if (!queue_cfg.validate(queue_reason)) begin
            reason = {"CMDQ queue configuration: ", queue_reason};
            return 0;
        end

        installed_adapter.hw_cfg = hw_cfg;
        return add_queue(queue_cfg, reason);
    endfunction
endclass

`endif
