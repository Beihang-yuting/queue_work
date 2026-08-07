`ifndef GQ_WAIT_POLICY_SV
`define GQ_WAIT_POLICY_SV

virtual class gq_wait_policy extends uvm_object;
    function new(string name = "gq_wait_policy");
        super.new(name);
    endfunction

    pure virtual task wait_for_wakeup(gq_queue_cfg cfg,
                                      gq_hw_adapter adapter,
                                      output bit completion_wakeup);
endclass

class gq_poll_wait_policy extends gq_wait_policy;
    `uvm_object_utils(gq_poll_wait_policy)

    function new(string name = "gq_poll_wait_policy");
        super.new(name);
    endfunction

    virtual task wait_for_wakeup(gq_queue_cfg cfg,
                                 gq_hw_adapter adapter,
                                 output bit completion_wakeup);
        #(cfg.poll_interval);
        completion_wakeup = 1;
    endtask
endclass

class gq_irq_wait_policy extends gq_wait_policy;
    `uvm_object_utils(gq_irq_wait_policy)

    function new(string name = "gq_irq_wait_policy");
        super.new(name);
    endfunction

    virtual task wait_for_wakeup(gq_queue_cfg cfg,
                                 gq_hw_adapter adapter,
                                 output bit completion_wakeup);
        completion_wakeup = 0;
        // Isolate disable fork from other concurrent policy invocations.
        fork
            begin
                fork
                    begin
                        adapter.wait_irq(cfg.role, cfg.queue_id);
                        completion_wakeup = 1;
                    end
                    begin
                        #(cfg.completion_timeout);
                    end
                join_any
                disable fork;
            end
        join
    endtask
endclass

`endif
