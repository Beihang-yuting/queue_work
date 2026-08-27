`ifndef GQ_ENV_CFG_SV
`define GQ_ENV_CFG_SV

class gq_env_cfg extends uvm_object;
    `uvm_object_utils(gq_env_cfg)

    host_mem_api mem;
    gq_hw_adapter adapter;
    gq_queue_cfg queues[string];
    uvm_event env_ready;
    uvm_event reset_asserted;
    uvm_event reset_deasserted;
    protected bit reset_state;

    function new(string name = "gq_env_cfg");
        super.new(name);
        mem       = null;
        adapter   = null;
        env_ready = new({name, "_ready"});
        reset_asserted   = new({name, "_reset_asserted"});
        reset_deasserted = new({name, "_reset_deasserted"});
        reset_state      = 0;
    endfunction

    // Reset requests are persistent until the environment controller consumes
    // them. A new cycle is not accepted while an earlier edge is pending, so
    // callers cannot silently collapse multiple reset cycles into one event.
    function bit trigger_reset_asserted();
        if (reset_state || reset_asserted.is_on() || reset_deasserted.is_on())
            return 0;
        reset_state = 1;
        reset_asserted.trigger();
        return 1;
    endfunction

    function bit trigger_reset_deasserted();
        if (!reset_state || reset_asserted.is_on() ||
            reset_deasserted.is_on())
            return 0;
        reset_state = 0;
        reset_deasserted.trigger();
        return 1;
    endfunction

    function bit reset_is_asserted();
        return reset_state;
    endfunction

    function bit add_queue(gq_queue_cfg queue_cfg, output string reason);
        string key;

        if (queue_cfg == null) begin
            reason = "queue configuration must not be null";
            return 0;
        end

        key = gq_queue_key(queue_cfg.role, queue_cfg.queue_id);
        if (queues.exists(key)) begin
            reason = $sformatf("duplicate queue %s", key);
            return 0;
        end

        // Ownership transfers to the environment. Callers must treat the
        // configuration as immutable after a successful add_queue call.
        queues[key] = queue_cfg;
        reason = "";
        return 1;
    endfunction

    virtual function bit validate(output string reason);
        string key;
        string expected_key;
        string queue_reason;

        if (mem == null) begin
            reason = "host memory API must not be null";
            return 0;
        end
        if (adapter == null) begin
            reason = "hardware adapter must not be null";
            return 0;
        end

        if (queues.first(key)) begin
            do begin
                if (queues[key] == null) begin
                    reason = $sformatf("queue %s configuration must not be null", key);
                    return 0;
                end
                expected_key = gq_queue_key(queues[key].role, queues[key].queue_id);
                if (key != expected_key) begin
                    reason = $sformatf(
                        "queue key %s does not match current role/ID key %s; added configurations are immutable",
                        key, expected_key);
                    return 0;
                end
                if (!queues[key].validate(queue_reason)) begin
                    reason = $sformatf("queue %s: %s", key, queue_reason);
                    return 0;
                end
                if (queues[key].ptr_codec == null) begin
                    reason = $sformatf("queue %s pointer codec must not be null", key);
                    return 0;
                end
            end while (queues.next(key));
        end

        reason = "";
        return 1;
    endfunction

    task wait_ready();
        if (!env_ready.is_on())
            env_ready.wait_trigger();
    endtask
endclass

`endif
