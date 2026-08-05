`ifndef GQ_WAIT_POLICY_SVH
`define GQ_WAIT_POLICY_SVH

virtual class gq_wait_policy extends uvm_object;
    function new(string name = "gq_wait_policy");
        super.new(name);
    endfunction

    pure virtual task wait_for_wakeup(gq_queue_cfg cfg,
                                      gq_hw_adapter adapter);
endclass

class gq_poll_wait_policy extends gq_wait_policy;
    `uvm_object_utils(gq_poll_wait_policy)

    function new(string name = "gq_poll_wait_policy");
        super.new(name);
    endfunction

    virtual task wait_for_wakeup(gq_queue_cfg cfg,
                                 gq_hw_adapter adapter);
        #(cfg.poll_interval);
    endtask
endclass

class gq_irq_wait_policy extends gq_wait_policy;
    `uvm_object_utils(gq_irq_wait_policy)

    function new(string name = "gq_irq_wait_policy");
        super.new(name);
    endfunction

    virtual task wait_for_wakeup(gq_queue_cfg cfg,
                                 gq_hw_adapter adapter);
        adapter.wait_irq(cfg.role, cfg.queue_id);
        adapter.ack_irq(cfg.role, cfg.queue_id);
    endtask
endclass

`endif
