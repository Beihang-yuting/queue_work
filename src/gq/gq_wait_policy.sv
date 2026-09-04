// src/gq/gq_wait_policy.sv: 支持可取消 IRQ/轮询、固定或自适应间隔及看门狗的等待策略。
`ifndef GQ_WAIT_POLICY_SV
`define GQ_WAIT_POLICY_SV

virtual class gq_wait_policy extends uvm_object;
    function new(string name = "gq_wait_policy");
        super.new(name);
    endfunction

    pure virtual task wait_for_wakeup(gq_queue_cfg cfg,
                                      gq_hw_adapter adapter,
                                      uvm_event cancel_event,
                                      uvm_event new_work_event,
                                      output gq_wakeup_e wakeup);

    virtual function void note_progress();
    endfunction

    virtual function void note_idle();
    endfunction
endclass

class gq_poll_wait_policy extends gq_wait_policy;
    `uvm_object_utils(gq_poll_wait_policy)

    time current_interval;

    protected time poll_min_interval;
    protected time poll_max_interval;
    protected int unsigned poll_backoff_factor;

    function new(string name = "gq_poll_wait_policy");
        super.new(name);
        current_interval    = 0;
        poll_min_interval   = 0;
        poll_max_interval   = 0;
        poll_backoff_factor = 1;
    endfunction

    virtual task wait_for_wakeup(gq_queue_cfg cfg,
                                 gq_hw_adapter adapter,
                                 uvm_event cancel_event,
                                 uvm_event new_work_event,
                                 output gq_wakeup_e wakeup);
        time wait_interval;

        poll_min_interval   = cfg.poll_min_interval;
        poll_max_interval   = cfg.poll_max_interval;
        poll_backoff_factor = cfg.poll_backoff_factor;
        if (current_interval == 0)
            current_interval = poll_min_interval;
        wait_interval = current_interval;

        // The wrapper keeps disable fork local to this invocation. Without it,
        // one concurrent policy call can terminate a sibling invocation.
        fork
            begin
                fork
                    begin
                        #(wait_interval);
                        wakeup = GQ_WAKE_POLL;
                    end
                    begin
                        cancel_event.wait_on();
                        wakeup = GQ_WAKE_CANCELLED;
                    end
                    begin
                        new_work_event.wait_on();
                        wakeup = GQ_WAKE_NEW_WORK;
                    end
                join_any
                disable fork;
            end
        join
    endtask

    virtual function void note_progress();
        if (poll_min_interval != 0)
            current_interval = poll_min_interval;
    endfunction

    virtual function void note_idle();
        if (current_interval == 0 || poll_max_interval == 0)
            return;

        if (poll_backoff_factor <= 1)
            return;

        if (current_interval >= poll_max_interval ||
            current_interval > (poll_max_interval / poll_backoff_factor))
            current_interval = poll_max_interval;
        else
            current_interval *= poll_backoff_factor;
    endfunction
endclass

class gq_irq_wait_policy extends gq_wait_policy;
    `uvm_object_utils(gq_irq_wait_policy)

    function new(string name = "gq_irq_wait_policy");
        super.new(name);
    endfunction

    virtual task wait_for_wakeup(gq_queue_cfg cfg,
                                 gq_hw_adapter adapter,
                                 uvm_event cancel_event,
                                 uvm_event new_work_event,
                                 output gq_wakeup_e wakeup);
        time watchdog_interval;

        watchdog_interval = cfg.irq_watchdog_interval;
        // The wrapper keeps disable fork local to this invocation. No policy
        // state is locked while the adapter callback is blocked.
        fork
            begin
                fork
                    begin
                        adapter.wait_irq(cfg.role, cfg.queue_id);
                        wakeup = GQ_WAKE_IRQ;
                    end
                    begin
                        cancel_event.wait_on();
                        wakeup = GQ_WAKE_CANCELLED;
                    end
                    begin
                        new_work_event.wait_on();
                        wakeup = GQ_WAKE_NEW_WORK;
                    end
                    begin
                        if (watchdog_interval == 0)
                            wait (watchdog_interval != 0);
                        else begin
                            #(watchdog_interval);
                            wakeup = GQ_WAKE_WATCHDOG;
                        end
                    end
                join_any
                disable fork;
            end
        join
    endtask
endclass

`endif
