`ifndef DMAQ_ENV_SV
`define DMAQ_ENV_SV

class dmaq_env_cfg extends gq_env_cfg;
    `uvm_object_utils(dmaq_env_cfg)

    int unsigned     depth;
    gq_logical_seq_t initial_logical_seq;
    time             poll_interval;
    time             completion_timeout;

    function new(string name = "dmaq_env_cfg");
        super.new(name);
        depth = DMAQ_DEFAULT_DEPTH;
        initial_logical_seq = DMAQ_DEFAULT_INITIAL_LOGICAL_SEQ;
        poll_interval = DMAQ_DEFAULT_POLL_INTERVAL;
        completion_timeout = DMAQ_DEFAULT_COMPLETION_TIMEOUT;
    endfunction

    function bit add_dmaq(int unsigned queue_id, dmaq_hw_cfg_t hw_cfg,
                          output string reason);
        dmaq_reg_adapter installed_adapter;
        gq_queue_cfg queue_cfg;
        string key;
        string queue_reason;

        if (adapter == null || !$cast(installed_adapter, adapter)) begin
            reason = "DMAQ adapter must derive from dmaq_reg_adapter";
            return 0;
        end
        key = gq_queue_key(GQ_TX, queue_id);
        if (queues.exists(key)) begin
            reason = $sformatf("duplicate queue %s", key);
            return 0;
        end
        if (queues.num() != 0) begin
            reason = "DMAQ environment supports exactly one queue";
            return 0;
        end
        if (depth < 2 || depth > 32768 || !gq_is_pow2(depth)) begin
            reason = $sformatf(
                "DMAQ depth %0d must be a power of two in 2..32768", depth);
            return 0;
        end
        if (initial_logical_seq >= depth) begin
            reason = $sformatf(
                "DMAQ initial logical sequence %0d must be below depth %0d",
                initial_logical_seq, depth);
            return 0;
        end
        if (poll_interval == 0) begin
            reason = "DMAQ poll interval must be non-zero";
            return 0;
        end
        if (completion_timeout <= poll_interval) begin
            reason = "DMAQ completion timeout must exceed poll interval";
            return 0;
        end

        queue_cfg = gq_queue_cfg::type_id::create($sformatf("tx_%0d_cfg",
                                                              queue_id));
        if (queue_cfg == null) begin
            reason = "DMAQ queue configuration creation failed";
            return 0;
        end
        queue_cfg.queue_id              = queue_id;
        queue_cfg.role                  = GQ_TX;
        queue_cfg.depth                 = depth;
        queue_cfg.initial_logical_seq   = initial_logical_seq;
        queue_cfg.desc_size             = DMAQ_DESC_BYTES;
        queue_cfg.alignment             = 64;
        queue_cfg.status_area_size      = 0;
        queue_cfg.wait_mode             = GQ_POLL;
        queue_cfg.poll_policy           = GQ_POLL_FIXED;
        queue_cfg.poll_min_interval     = poll_interval;
        queue_cfg.poll_max_interval     = poll_interval;
        queue_cfg.poll_backoff_factor   = 1;
        queue_cfg.irq_watchdog_interval = 0;
        queue_cfg.completion_timeout    = completion_timeout;
        queue_cfg.ptr_codec = dmaq_ptr_codec::type_id::create(
            $sformatf("tx_%0d_ptr_codec", queue_id));
        queue_cfg.completion_source = dmaq_completion::type_id::create(
            $sformatf("tx_%0d_completion", queue_id));
        if (!queue_cfg.validate(queue_reason)) begin
            reason = {"DMAQ queue configuration: ", queue_reason};
            return 0;
        end
        if (!installed_adapter.reserve_queue_binding(queue_id, hw_cfg,
                                                      reason))
            return 0;
        if (!add_queue(queue_cfg, reason)) begin
            void'(installed_adapter.release_queue_binding(queue_id, hw_cfg));
            return 0;
        end
        return 1;
    endfunction
endclass

class dmaq_env extends gq_env;
    `uvm_component_utils(dmaq_env)

    function new(string name = "dmaq_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction
endclass

`endif
