`ifndef GQ_WAIT_POLICY_TEST_SV
`define GQ_WAIT_POLICY_TEST_SV

class gq_wait_policy_test extends uvm_test;
    `uvm_component_utils(gq_wait_policy_test)

    function new(string name = "gq_wait_policy_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function gq_queue_cfg make_poll_cfg(string name,
                                        time min_interval,
                                        time max_interval,
                                        gq_poll_policy_e poll_policy);
        gq_queue_cfg cfg;

        cfg = gq_queue_cfg::type_id::create(name);
        cfg.role                 = GQ_TX;
        cfg.queue_id             = 1;
        cfg.poll_policy          = poll_policy;
        cfg.poll_min_interval    = min_interval;
        cfg.poll_max_interval    = max_interval;
        cfg.poll_backoff_factor  = 2;
        return cfg;
    endfunction

    function gq_queue_cfg make_irq_cfg(string name,
                                       int unsigned queue_id,
                                       time watchdog_interval);
        gq_queue_cfg cfg;

        cfg = gq_queue_cfg::type_id::create(name);
        cfg.role                  = GQ_TX;
        cfg.queue_id              = queue_id;
        cfg.wait_mode             = GQ_IRQ;
        cfg.irq_watchdog_interval = watchdog_interval;
        return cfg;
    endfunction

    task check_poll_timer(gq_poll_wait_policy policy,
                          gq_queue_cfg cfg,
                          uvm_event cancel_event,
                          uvm_event new_work_event,
                          time expected_delta,
                          string check_name);
        gq_wakeup_e wakeup;
        time start_time;
        time elapsed;

        start_time = $time;
        policy.wait_for_wakeup(cfg, null, cancel_event, new_work_event,
                               wakeup);
        elapsed = $time - start_time;
        `uvm_info("WAIT_POLICY_TRACE", $sformatf(
            "%s timestamp=%0t delta=%0t wakeup=%0d",
            check_name, $time, elapsed, wakeup), UVM_LOW)
        if (elapsed != expected_delta || wakeup != GQ_WAKE_POLL)
            `uvm_fatal("WAIT_POLICY_POLL", $sformatf(
                "%s expected delta %0t/POLL, got %0t/%0d",
                check_name, expected_delta, elapsed, wakeup))
    endtask

    task run_phase(uvm_phase phase);
        mailbox_mock_adapter adapter;
        gq_poll_wait_policy adaptive_policy;
        gq_poll_wait_policy fixed_policy;
        gq_irq_wait_policy irq_policy;
        gq_queue_cfg adaptive_cfg;
        gq_queue_cfg fixed_cfg;
        gq_queue_cfg irq_cfg;
        gq_queue_cfg watchdog_cfg;
        gq_queue_cfg irq_new_work_cfg;
        gq_queue_cfg irq_cancel_cfg;
        gq_queue_cfg concurrent_irq_cfg;
        gq_queue_cfg concurrent_watchdog_cfg;
        uvm_event cancel_event;
        uvm_event new_work_event;
        uvm_event concurrent_cancel_a;
        uvm_event concurrent_cancel_b;
        uvm_event concurrent_new_work_a;
        uvm_event concurrent_new_work_b;
        gq_wakeup_e wakeup;
        gq_wakeup_e concurrent_wakeup_a;
        gq_wakeup_e concurrent_wakeup_b;
        time start_time;
        time elapsed;
        time concurrent_elapsed_a;
        time concurrent_elapsed_b;

        phase.raise_objection(this);

        adapter = mailbox_mock_adapter::type_id::create("adapter");
        adaptive_policy = gq_poll_wait_policy::type_id::create(
            "adaptive_policy");
        fixed_policy = gq_poll_wait_policy::type_id::create("fixed_policy");
        irq_policy = gq_irq_wait_policy::type_id::create("irq_policy");
        cancel_event = new("cancel_event");
        new_work_event = new("new_work_event");

        adaptive_cfg = make_poll_cfg("adaptive_cfg", 10ns, 100ns,
                                     GQ_POLL_ADAPTIVE);
        check_poll_timer(adaptive_policy, adaptive_cfg, cancel_event,
                         new_work_event, 10ns, "adaptive_idle_1");
        adaptive_policy.note_idle();
        check_poll_timer(adaptive_policy, adaptive_cfg, cancel_event,
                         new_work_event, 20ns, "adaptive_idle_2");
        adaptive_policy.note_idle();
        check_poll_timer(adaptive_policy, adaptive_cfg, cancel_event,
                         new_work_event, 40ns, "adaptive_idle_3");
        adaptive_policy.note_idle();
        check_poll_timer(adaptive_policy, adaptive_cfg, cancel_event,
                         new_work_event, 80ns, "adaptive_idle_4");
        adaptive_policy.note_idle();
        check_poll_timer(adaptive_policy, adaptive_cfg, cancel_event,
                         new_work_event, 100ns, "adaptive_idle_5");
        adaptive_policy.note_idle();
        adaptive_policy.note_idle();
        check_poll_timer(adaptive_policy, adaptive_cfg, cancel_event,
                         new_work_event, 100ns, "adaptive_saturated");
        adaptive_policy.note_progress();
        check_poll_timer(adaptive_policy, adaptive_cfg, cancel_event,
                         new_work_event, 10ns, "adaptive_progress_reset");

        fixed_cfg = make_poll_cfg("fixed_cfg", 100ns, 100ns,
                                  GQ_POLL_FIXED);
        start_time = $time;
        fork
            begin
                fixed_policy.wait_for_wakeup(fixed_cfg, null, cancel_event,
                                             new_work_event, wakeup);
            end
            begin
                #7ns;
                new_work_event.trigger();
            end
        join
        elapsed = $time - start_time;
        `uvm_info("WAIT_POLICY_TRACE", $sformatf(
            "poll_new_work timestamp=%0t delta=%0t wakeup=%0d",
            $time, elapsed, wakeup), UVM_LOW)
        if (elapsed != 7ns || wakeup != GQ_WAKE_NEW_WORK)
            `uvm_fatal("WAIT_POLICY_NEW_WORK", $sformatf(
                "expected 7ns/NEW_WORK, got %0t/%0d", elapsed, wakeup))
        new_work_event.reset();

        start_time = $time;
        fork
            begin
                fixed_policy.wait_for_wakeup(fixed_cfg, null, cancel_event,
                                             new_work_event, wakeup);
            end
            begin
                #6ns;
                cancel_event.trigger();
            end
        join
        elapsed = $time - start_time;
        `uvm_info("WAIT_POLICY_TRACE", $sformatf(
            "poll_cancel timestamp=%0t delta=%0t wakeup=%0d",
            $time, elapsed, wakeup), UVM_LOW)
        if (elapsed != 6ns || wakeup != GQ_WAKE_CANCELLED)
            `uvm_fatal("WAIT_POLICY_CANCEL", $sformatf(
                "expected 6ns/CANCELLED, got %0t/%0d", elapsed, wakeup))
        cancel_event.reset();

        fixed_policy.note_idle();
        check_poll_timer(fixed_policy, fixed_cfg, cancel_event,
                         new_work_event, 100ns, "fixed_after_idle");

        irq_cfg = make_irq_cfg("irq_cfg", 2, 50ns);
        start_time = $time;
        fork
            begin
                irq_policy.wait_for_wakeup(irq_cfg, adapter, cancel_event,
                                           new_work_event, wakeup);
            end
            begin
                #20ns;
                adapter.trigger_irq(irq_cfg.role, irq_cfg.queue_id);
            end
        join
        elapsed = $time - start_time;
        `uvm_info("WAIT_POLICY_TRACE", $sformatf(
            "irq timestamp=%0t delta=%0t wakeup=%0d ack_count=%0d",
            $time, elapsed, wakeup, adapter.ack_irq_calls), UVM_LOW)
        if (elapsed != 20ns || wakeup != GQ_WAKE_IRQ)
            `uvm_fatal("WAIT_POLICY_IRQ", $sformatf(
                "expected 20ns/IRQ, got %0t/%0d", elapsed, wakeup))

        watchdog_cfg = make_irq_cfg("watchdog_cfg", 3, 50ns);
        start_time = $time;
        irq_policy.wait_for_wakeup(watchdog_cfg, adapter, cancel_event,
                                   new_work_event, wakeup);
        elapsed = $time - start_time;
        `uvm_info("WAIT_POLICY_TRACE", $sformatf(
            "watchdog timestamp=%0t delta=%0t wakeup=%0d ack_count=%0d",
            $time, elapsed, wakeup, adapter.ack_irq_calls), UVM_LOW)
        if (elapsed != 50ns || wakeup != GQ_WAKE_WATCHDOG)
            `uvm_fatal("WAIT_POLICY_WATCHDOG", $sformatf(
                "expected 50ns/WATCHDOG, got %0t/%0d", elapsed, wakeup))
        if (adapter.ack_irq_calls != 0)
            `uvm_fatal("WAIT_POLICY_ACK", $sformatf(
                "wait policy called ACK %0d times", adapter.ack_irq_calls))

        irq_new_work_cfg = make_irq_cfg("irq_new_work_cfg", 6, 50ns);
        start_time = $time;
        fork
            begin
                irq_policy.wait_for_wakeup(
                    irq_new_work_cfg, adapter, cancel_event,
                    new_work_event, wakeup);
            end
            begin
                #7ns;
                new_work_event.trigger();
            end
        join
        elapsed = $time - start_time;
        `uvm_info("WAIT_POLICY_TRACE", $sformatf(
            "irq_new_work timestamp=%0t delta=%0t wakeup=%0d",
            $time, elapsed, wakeup), UVM_LOW)
        if (elapsed != 7ns || wakeup != GQ_WAKE_NEW_WORK)
            `uvm_fatal("WAIT_POLICY_IRQ_NEW_WORK", $sformatf(
                "expected 7ns/NEW_WORK, got %0t/%0d", elapsed, wakeup))
        new_work_event.reset();

        irq_cancel_cfg = make_irq_cfg("irq_cancel_cfg", 7, 0);
        start_time = $time;
        fork
            begin
                irq_policy.wait_for_wakeup(irq_cancel_cfg, adapter,
                                           cancel_event, new_work_event,
                                           wakeup);
            end
            begin
                #6ns;
                cancel_event.trigger();
            end
        join
        elapsed = $time - start_time;
        `uvm_info("WAIT_POLICY_TRACE", $sformatf(
            "irq_cancel timestamp=%0t delta=%0t wakeup=%0d",
            $time, elapsed, wakeup), UVM_LOW)
        if (elapsed != 6ns || wakeup != GQ_WAKE_CANCELLED)
            `uvm_fatal("WAIT_POLICY_IRQ_CANCEL", $sformatf(
                "expected 6ns/CANCELLED, got %0t/%0d", elapsed, wakeup))
        cancel_event.reset();

        concurrent_irq_cfg = make_irq_cfg("concurrent_irq_cfg", 4, 40ns);
        concurrent_watchdog_cfg = make_irq_cfg(
            "concurrent_watchdog_cfg", 5, 40ns);
        concurrent_cancel_a = new("concurrent_cancel_a");
        concurrent_cancel_b = new("concurrent_cancel_b");
        concurrent_new_work_a = new("concurrent_new_work_a");
        concurrent_new_work_b = new("concurrent_new_work_b");
        concurrent_elapsed_a = 0;
        concurrent_elapsed_b = 0;
        start_time = $time;
        fork
            begin
                irq_policy.wait_for_wakeup(
                    concurrent_irq_cfg, adapter, concurrent_cancel_a,
                    concurrent_new_work_a, concurrent_wakeup_a);
                concurrent_elapsed_a = $time - start_time;
            end
            begin
                irq_policy.wait_for_wakeup(
                    concurrent_watchdog_cfg, adapter, concurrent_cancel_b,
                    concurrent_new_work_b, concurrent_wakeup_b);
                concurrent_elapsed_b = $time - start_time;
            end
            begin
                #5ns;
                adapter.trigger_irq(concurrent_irq_cfg.role,
                                    concurrent_irq_cfg.queue_id);
            end
        join
        `uvm_info("WAIT_POLICY_TRACE", $sformatf(
            "concurrent irq_delta=%0t irq_wakeup=%0d watchdog_delta=%0t watchdog_wakeup=%0d ack_count=%0d",
            concurrent_elapsed_a, concurrent_wakeup_a,
            concurrent_elapsed_b, concurrent_wakeup_b,
            adapter.ack_irq_calls), UVM_LOW)
        if (concurrent_elapsed_a != 5ns ||
            concurrent_wakeup_a != GQ_WAKE_IRQ ||
            concurrent_elapsed_b != 40ns ||
            concurrent_wakeup_b != GQ_WAKE_WATCHDOG)
            `uvm_fatal("WAIT_POLICY_ISOLATION", $sformatf(
                "concurrent waits returned %0t/%0d and %0t/%0d",
                concurrent_elapsed_a, concurrent_wakeup_a,
                concurrent_elapsed_b, concurrent_wakeup_b))
        if (adapter.ack_irq_calls != 0)
            `uvm_fatal("WAIT_POLICY_ACK", $sformatf(
                "concurrent policy waits called ACK %0d times",
                adapter.ack_irq_calls))
        if (adapter.wait_irq_calls != 6 ||
            adapter.wait_irq_count[gq_queue_key(GQ_TX, 2)] != 1 ||
            adapter.wait_irq_count[gq_queue_key(GQ_TX, 3)] != 1 ||
            adapter.wait_irq_count[gq_queue_key(GQ_TX, 4)] != 1 ||
            adapter.wait_irq_count[gq_queue_key(GQ_TX, 5)] != 1 ||
            adapter.wait_irq_count[gq_queue_key(GQ_TX, 6)] != 1 ||
            adapter.wait_irq_count[gq_queue_key(GQ_TX, 7)] != 1)
            `uvm_fatal("WAIT_POLICY_IRQ_CALLS", $sformatf(
                "expected one wait_irq per case (total 6), got %0d",
                adapter.wait_irq_calls))

        phase.drop_objection(this);
    endtask
endclass

`endif
