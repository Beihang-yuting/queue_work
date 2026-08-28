`ifndef GQ_WORKER_WAKEUP_TEST_SV
`define GQ_WORKER_WAKEUP_TEST_SV

class gq_worker_trace_adapter extends mailbox_mock_adapter;
    `uvm_object_utils(gq_worker_trace_adapter)

    string event_trace[$];
    time event_times[$];

    function new(string name = "gq_worker_trace_adapter");
        super.new(name);
    endfunction

    function void record_event(string event_name);
        event_trace.push_back(event_name);
        event_times.push_back($time);
    endfunction

    virtual task wait_irq(gq_role_e role, int unsigned queue_id);
        record_event("WAIT_IRQ");
        super.wait_irq(role, queue_id);
    endtask

    virtual task ack_irq(gq_role_e role, int unsigned queue_id);
        record_event("ACK_IRQ");
        super.ack_irq(role, queue_id);
    endtask
endclass

class gq_worker_trace_completion extends mailbox_completion;
    `uvm_object_utils(gq_worker_trace_completion)

    int unsigned query_calls;
    int unsigned forced_invalid_queries;
    time query_times[$];
    bit query_valids[$];
    int unsigned query_counts[$];

    function new(string name = "gq_worker_trace_completion");
        super.new(name);
        query_calls = 0;
        forced_invalid_queries = 0;
    endfunction

    virtual task query_completed(
        host_mem_api mem,
        gq_hw_adapter adapter,
        gq_addr_t ring_base,
        gq_addr_t status_addr,
        int unsigned depth,
        int unsigned desc_size,
        gq_logical_seq_t logical_head,
        input gq_desc_base pending[$],
        output bit valid,
        output int unsigned completed_count);
        gq_worker_trace_adapter trace_adapter;

        query_calls++;
        query_times.push_back($time);
        if ($cast(trace_adapter, adapter))
            trace_adapter.record_event("QUERY");
        if (forced_invalid_queries != 0) begin
            forced_invalid_queries--;
            valid = 0;
            completed_count = 0;
        end else begin
            super.query_completed(mem, adapter, ring_base, status_addr,
                                  depth, desc_size, logical_head, pending,
                                  valid, completed_count);
        end
        query_valids.push_back(valid);
        query_counts.push_back(completed_count);
    endtask
endclass

class gq_worker_recording_poll_policy extends gq_poll_wait_policy;
    `uvm_object_utils(gq_worker_recording_poll_policy)

    gq_wakeup_e observed_wakeup;

    function new(string name = "gq_worker_recording_poll_policy");
        super.new(name);
        observed_wakeup = GQ_WAKE_CANCELLED;
    endfunction

    virtual task wait_for_wakeup(gq_queue_cfg cfg,
                                 gq_hw_adapter adapter,
                                 uvm_event cancel_event,
                                 uvm_event new_work_event,
                                 output gq_wakeup_e wakeup);
        super.wait_for_wakeup(cfg, adapter, cancel_event, new_work_event,
                              wakeup);
        observed_wakeup = wakeup;
    endtask
endclass

class gq_worker_recording_irq_policy extends gq_irq_wait_policy;
    `uvm_object_utils(gq_worker_recording_irq_policy)

    gq_wakeup_e observed_wakeup;

    function new(string name = "gq_worker_recording_irq_policy");
        super.new(name);
        observed_wakeup = GQ_WAKE_CANCELLED;
    endfunction

    virtual task wait_for_wakeup(gq_queue_cfg cfg,
                                 gq_hw_adapter adapter,
                                 uvm_event cancel_event,
                                 uvm_event new_work_event,
                                 output gq_wakeup_e wakeup);
        super.wait_for_wakeup(cfg, adapter, cancel_event, new_work_event,
                              wakeup);
        observed_wakeup = wakeup;
    endtask
endclass

class gq_worker_test_engine extends gq_queue_engine;
    `uvm_component_utils(gq_worker_test_engine)

    function new(string name = "gq_worker_test_engine",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function gq_wakeup_e observed_wakeup();
        gq_worker_recording_poll_policy poll;
        gq_worker_recording_irq_policy irq;

        if ($cast(poll, wait_policy))
            return poll.observed_wakeup;
        if ($cast(irq, wait_policy))
            return irq.observed_wakeup;
        return GQ_WAKE_CANCELLED;
    endfunction

    function time current_poll_interval();
        gq_worker_recording_poll_policy poll;

        if ($cast(poll, wait_policy))
            return poll.current_interval;
        return 0;
    endfunction

    function bit try_state_lock_for_test();
        bit acquired;

        acquired = state_lock.try_get(1);
        if (acquired)
            state_lock.put(1);
        return acquired;
    endfunction
endclass

class gq_worker_lock_probe_mem extends host_mem_manager;
    `uvm_object_utils(gq_worker_lock_probe_mem)

    gq_worker_test_engine engine;
    bit probe_reads;
    int unsigned locked_read_callbacks;

    function new(string name = "gq_worker_lock_probe_mem");
        super.new(name);
        engine = null;
        probe_reads = 0;
        locked_read_callbacks = 0;
    endfunction

    virtual function void read_mem(
        bit [63:0] addr,
        int unsigned size,
        ref byte data[],
        input string file = "",
        input int line = 0);
        if (probe_reads && engine != null &&
            !engine.try_state_lock_for_test())
            locked_read_callbacks++;
        super.read_mem(addr, size, data, file, line);
    endfunction
endclass

class gq_worker_report_catcher extends uvm_report_catcher;
    `uvm_object_utils(gq_worker_report_catcher)

    int unsigned timeout_count;
    int unsigned invalid_query_count;
    time timeout_times[$];

    function new(string name = "gq_worker_report_catcher");
        super.new(name);
        timeout_count = 0;
        invalid_query_count = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR &&
            get_id() == "GQ_COMPLETION_TIMEOUT") begin
            timeout_count++;
            timeout_times.push_back($time);
            return CAUGHT;
        end
        if (get_severity() == UVM_WARNING &&
            get_id() == "GQ_COMPLETION_QUERY") begin
            invalid_query_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class gq_worker_wakeup_test extends uvm_test;
    `uvm_component_utils(gq_worker_wakeup_test)

    gq_test_ptr_codec ptr_codec;

    host_mem_manager idle_mem;
    gq_worker_trace_adapter idle_adapter;
    gq_worker_trace_completion idle_source;
    gq_queue_cfg idle_cfg;
    gq_worker_test_engine idle_engine;

    host_mem_manager adaptive_mem;
    gq_worker_trace_adapter adaptive_adapter;
    gq_worker_trace_completion adaptive_source;
    gq_queue_cfg adaptive_cfg;
    gq_worker_test_engine adaptive_engine;
    mailbox_mock_dut adaptive_dut;

    host_mem_manager irq_mem;
    gq_worker_trace_adapter irq_adapter;
    gq_worker_trace_completion irq_source;
    gq_queue_cfg irq_cfg;
    gq_worker_test_engine irq_engine;
    mailbox_mock_dut irq_dut;

    host_mem_manager poll_reset_mem;
    gq_worker_trace_adapter poll_reset_adapter;
    gq_worker_trace_completion poll_reset_source;
    gq_queue_cfg poll_reset_cfg;
    gq_worker_test_engine poll_reset_engine;

    host_mem_manager irq_reset_mem;
    gq_worker_trace_adapter irq_reset_adapter;
    gq_worker_trace_completion irq_reset_source;
    gq_queue_cfg irq_reset_cfg;
    gq_worker_test_engine irq_reset_engine;

    gq_worker_lock_probe_mem timeout_mem;
    gq_worker_trace_adapter timeout_adapter;
    gq_worker_trace_completion timeout_source;
    gq_queue_cfg timeout_cfg;
    gq_worker_test_engine timeout_engine;

    host_mem_manager lost_irq_mem;
    gq_worker_trace_adapter lost_irq_adapter;
    gq_worker_trace_completion lost_irq_source;
    gq_queue_cfg lost_irq_cfg;
    gq_worker_test_engine lost_irq_engine;

    host_mem_manager late_watchdog_mem;
    gq_worker_trace_adapter late_watchdog_adapter;
    gq_worker_trace_completion late_watchdog_source;
    gq_queue_cfg late_watchdog_cfg;
    gq_worker_test_engine late_watchdog_engine;

    host_mem_manager invalid_deadline_mem;
    gq_worker_trace_adapter invalid_deadline_adapter;
    gq_worker_trace_completion invalid_deadline_source;
    gq_queue_cfg invalid_deadline_cfg;
    gq_worker_test_engine invalid_deadline_engine;

    host_mem_manager rx_mem;
    gq_worker_trace_adapter rx_adapter;
    gq_worker_trace_completion rx_source;
    gq_queue_cfg rx_cfg;
    gq_worker_test_engine rx_engine;

    gq_worker_report_catcher report_catcher;
    int unsigned expectation_failures;

    bit idle_worker_returned;
    bit adaptive_worker_returned;
    bit irq_worker_returned;
    bit timeout_worker_returned;
    bit lost_irq_worker_returned;
    bit late_watchdog_worker_returned;
    bit invalid_deadline_worker_returned;
    bit rx_worker_returned;

    function new(string name = "gq_worker_wakeup_test",
                 uvm_component parent = null);
        super.new(name, parent);
        expectation_failures = 0;
    endfunction

    function void initialize_mem(host_mem_manager target_mem,
                                 gq_addr_t base_addr);
        target_mem.init_region(base_addr, base_addr + 64'h000f_ffff,
                               MODE_LINEAR, 16);
    endfunction

    function gq_queue_cfg make_cfg(
        string name,
        int unsigned queue_id,
        gq_role_e role,
        gq_wait_mode_e wait_mode,
        gq_poll_policy_e poll_policy,
        time poll_min_interval,
        time poll_max_interval,
        time irq_watchdog_interval,
        time completion_timeout,
        gq_completion_source completion_source);
        gq_queue_cfg result;

        result = gq_queue_cfg::type_id::create(name);
        result.queue_id = queue_id;
        result.role = role;
        result.depth = 32;
        result.desc_size = role == GQ_TX ? 64 : 16;
        result.alignment = 64;
        result.status_area_size = 0;
        result.wait_mode = wait_mode;
        result.poll_policy = poll_policy;
        result.poll_min_interval = poll_min_interval;
        result.poll_max_interval = poll_max_interval;
        result.poll_backoff_factor = 2;
        result.irq_watchdog_interval = irq_watchdog_interval;
        result.completion_timeout = completion_timeout;
        result.ptr_codec = ptr_codec;
        result.completion_source = completion_source;
        return result;
    endfunction

    function void configure_engine(string path,
                                   gq_queue_cfg target_cfg,
                                   host_mem_manager target_mem,
                                   gq_hw_adapter target_adapter);
        uvm_config_db#(gq_queue_cfg)::set(this, path, "cfg", target_cfg);
        uvm_config_db#(host_mem_api)::set(this, path, "mem", target_mem);
        uvm_config_db#(gq_hw_adapter)::set(this, path, "adapter",
                                           target_adapter);
    endfunction

    function mailbox_tx_desc make_tx(string name, int unsigned index);
        mailbox_tx_desc desc;

        desc = mailbox_tx_desc::type_id::create(name);
        desc.srcid = 16'h9000 + index;
        desc.dstid = 16'ha000 + index;
        desc.msg_type = 16'hb000 + index;
        desc.buf_len = 0;
        desc.data_len = 1;
        desc.data[0] = byte'(index);
        return desc;
    endfunction

    function void check_expectation(bit condition, string message);
        if (!condition) begin
            expectation_failures++;
            `uvm_error("GQ_WORKER_EXPECT", message)
        end
    endfunction

    function bit trace_matches(gq_worker_trace_adapter target_adapter,
                               int unsigned base_index,
                               string first,
                               string second,
                               string third = "");
        int unsigned needed;

        needed = third == "" ? 2 : 3;
        if (target_adapter.event_trace.size() < base_index + needed)
            return 0;
        if (target_adapter.event_trace[base_index] != first ||
            target_adapter.event_trace[base_index + 1] != second)
            return 0;
        if (third != "" &&
            target_adapter.event_trace[base_index + 2] != third)
            return 0;
        return 1;
    endfunction

    function string trace_text(gq_worker_trace_adapter target_adapter);
        string result;

        result = "";
        foreach (target_adapter.event_trace[i]) begin
            if (i != 0)
                result = {result, ","};
            result = {result, target_adapter.event_trace[i]};
        end
        return result;
    endfunction

    task wait_for_query_count(input gq_worker_trace_completion source,
                              input int unsigned expected_count,
                              input string label,
                              input int unsigned limit = 200);
        for (int unsigned observation = 0; observation < limit;
             observation++) begin
            #10ns;
            if (source.query_calls >= expected_count)
                return;
        end
        `uvm_fatal("GQ_WORKER_STALL", $sformatf(
            "%s observed %0d queries, expected at least %0d",
            label, source.query_calls, expected_count))
    endtask

    task wait_for_irq_waits(input gq_worker_trace_adapter target_adapter,
                            input int unsigned expected_count,
                            input string label);
        for (int unsigned observation = 0; observation < 200;
             observation++) begin
            #10ns;
            if (target_adapter.wait_irq_calls >= expected_count)
                return;
        end
        `uvm_fatal("GQ_WORKER_STALL", $sformatf(
            "%s observed %0d IRQ waits, expected at least %0d",
            label, target_adapter.wait_irq_calls, expected_count))
    endtask

    task wait_for_worker_stop(ref bit returned, input string label);
        for (int unsigned observation = 0; observation < 20;
             observation++) begin
            #10ns;
            if (returned)
                return;
        end
        check_expectation(returned,
                          {label, " worker did not stop after cleanup"});
    endtask

    task submit_one(input gq_queue_engine target_engine,
                    input gq_desc_base desc,
                    input string label);
        gq_request request;
        gq_response response;

        request = gq_request::type_id::create({label, "_request"});
        request.add_desc(desc);
        response = gq_response::type_id::create({label, "_response"});
        target_engine.submit_batch(request, response);
        if (response.status != GQ_OK || response.committed_count != 1)
            `uvm_fatal("GQ_WORKER_SETUP", $sformatf(
                "%s submit failed status=%0d committed=%0d",
                label, response.status, response.committed_count))
    endtask

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        gq_poll_wait_policy::type_id::set_type_override(
            gq_worker_recording_poll_policy::get_type());
        gq_irq_wait_policy::type_id::set_type_override(
            gq_worker_recording_irq_policy::get_type());
        ptr_codec = gq_test_ptr_codec::type_id::create("ptr_codec");

        idle_mem = new("idle_mem");
        initialize_mem(idle_mem, 64'h0000_0001_8000_0000);
        idle_adapter = gq_worker_trace_adapter::type_id::create("idle_adapter");
        idle_source = gq_worker_trace_completion::type_id::create("idle_source");
        idle_cfg = make_cfg("idle_cfg", 40, GQ_TX, GQ_POLL,
                            GQ_POLL_FIXED, 10ns, 10ns, 0, 1us,
                            idle_source);
        configure_engine("idle_engine", idle_cfg, idle_mem, idle_adapter);
        idle_engine = gq_worker_test_engine::type_id::create("idle_engine", this);

        adaptive_mem = new("adaptive_mem");
        initialize_mem(adaptive_mem, 64'h0000_0001_8100_0000);
        adaptive_adapter = gq_worker_trace_adapter::type_id::create(
            "adaptive_adapter");
        adaptive_source = gq_worker_trace_completion::type_id::create(
            "adaptive_source");
        adaptive_cfg = make_cfg("adaptive_cfg", 41, GQ_TX, GQ_POLL,
                                GQ_POLL_ADAPTIVE, 10ns, 100ns, 0, 10us,
                                adaptive_source);
        configure_engine("adaptive_engine", adaptive_cfg, adaptive_mem,
                         adaptive_adapter);
        adaptive_engine = gq_worker_test_engine::type_id::create(
            "adaptive_engine", this);
        adaptive_dut = mailbox_mock_dut::type_id::create("adaptive_dut");
        adaptive_dut.mem = adaptive_mem;
        adaptive_dut.adapter = adaptive_adapter;

        irq_mem = new("irq_mem");
        initialize_mem(irq_mem, 64'h0000_0001_8200_0000);
        irq_adapter = gq_worker_trace_adapter::type_id::create("irq_adapter");
        irq_source = gq_worker_trace_completion::type_id::create("irq_source");
        irq_cfg = make_cfg("irq_cfg", 42, GQ_TX, GQ_IRQ, GQ_POLL_FIXED,
                           10ns, 10ns, 100ns, 1us, irq_source);
        configure_engine("irq_engine", irq_cfg, irq_mem, irq_adapter);
        irq_engine = gq_worker_test_engine::type_id::create("irq_engine", this);
        irq_dut = mailbox_mock_dut::type_id::create("irq_dut");
        irq_dut.mem = irq_mem;
        irq_dut.adapter = irq_adapter;

        poll_reset_mem = new("poll_reset_mem");
        initialize_mem(poll_reset_mem, 64'h0000_0001_8300_0000);
        poll_reset_adapter = gq_worker_trace_adapter::type_id::create(
            "poll_reset_adapter");
        poll_reset_source = gq_worker_trace_completion::type_id::create(
            "poll_reset_source");
        poll_reset_cfg = make_cfg("poll_reset_cfg", 43, GQ_TX, GQ_POLL,
                                  GQ_POLL_FIXED, 100ns, 100ns, 0, 1us,
                                  poll_reset_source);
        configure_engine("poll_reset_engine", poll_reset_cfg, poll_reset_mem,
                         poll_reset_adapter);
        poll_reset_engine = gq_worker_test_engine::type_id::create(
            "poll_reset_engine", this);

        irq_reset_mem = new("irq_reset_mem");
        initialize_mem(irq_reset_mem, 64'h0000_0001_8400_0000);
        irq_reset_adapter = gq_worker_trace_adapter::type_id::create(
            "irq_reset_adapter");
        irq_reset_source = gq_worker_trace_completion::type_id::create(
            "irq_reset_source");
        irq_reset_cfg = make_cfg("irq_reset_cfg", 44, GQ_TX, GQ_IRQ,
                                 GQ_POLL_FIXED, 10ns, 10ns, 1us, 2us,
                                 irq_reset_source);
        configure_engine("irq_reset_engine", irq_reset_cfg, irq_reset_mem,
                         irq_reset_adapter);
        irq_reset_engine = gq_worker_test_engine::type_id::create(
            "irq_reset_engine", this);

        timeout_mem = new("timeout_mem");
        initialize_mem(timeout_mem, 64'h0000_0001_8500_0000);
        timeout_adapter = gq_worker_trace_adapter::type_id::create(
            "timeout_adapter");
        timeout_source = gq_worker_trace_completion::type_id::create(
            "timeout_source");
        timeout_cfg = make_cfg("timeout_cfg", 45, GQ_TX, GQ_POLL,
                               GQ_POLL_FIXED, 10ns, 10ns, 0, 50ns,
                               timeout_source);
        configure_engine("timeout_engine", timeout_cfg, timeout_mem,
                         timeout_adapter);
        timeout_engine = gq_worker_test_engine::type_id::create(
            "timeout_engine", this);
        timeout_mem.engine = timeout_engine;

        lost_irq_mem = new("lost_irq_mem");
        initialize_mem(lost_irq_mem, 64'h0000_0001_8700_0000);
        lost_irq_adapter = gq_worker_trace_adapter::type_id::create(
            "lost_irq_adapter");
        lost_irq_source = gq_worker_trace_completion::type_id::create(
            "lost_irq_source");
        lost_irq_cfg = make_cfg("lost_irq_cfg", 47, GQ_TX, GQ_IRQ,
                                GQ_POLL_FIXED, 10ns, 10ns, 0, 50ns,
                                lost_irq_source);
        configure_engine("lost_irq_engine", lost_irq_cfg, lost_irq_mem,
                         lost_irq_adapter);
        lost_irq_engine = gq_worker_test_engine::type_id::create(
            "lost_irq_engine", this);

        late_watchdog_mem = new("late_watchdog_mem");
        initialize_mem(late_watchdog_mem, 64'h0000_0001_8800_0000);
        late_watchdog_adapter = gq_worker_trace_adapter::type_id::create(
            "late_watchdog_adapter");
        late_watchdog_source = gq_worker_trace_completion::type_id::create(
            "late_watchdog_source");
        late_watchdog_cfg = make_cfg("late_watchdog_cfg", 48, GQ_TX, GQ_IRQ,
                                     GQ_POLL_FIXED, 10ns, 10ns, 200ns, 60ns,
                                     late_watchdog_source);
        configure_engine("late_watchdog_engine", late_watchdog_cfg,
                         late_watchdog_mem, late_watchdog_adapter);
        late_watchdog_engine = gq_worker_test_engine::type_id::create(
            "late_watchdog_engine", this);

        invalid_deadline_mem = new("invalid_deadline_mem");
        initialize_mem(invalid_deadline_mem, 64'h0000_0001_8900_0000);
        invalid_deadline_adapter = gq_worker_trace_adapter::type_id::create(
            "invalid_deadline_adapter");
        invalid_deadline_source = gq_worker_trace_completion::type_id::create(
            "invalid_deadline_source");
        invalid_deadline_cfg = make_cfg(
            "invalid_deadline_cfg", 49, GQ_TX, GQ_POLL, GQ_POLL_FIXED,
            30ns, 30ns, 0, 130ns, invalid_deadline_source);
        configure_engine("invalid_deadline_engine", invalid_deadline_cfg,
                         invalid_deadline_mem, invalid_deadline_adapter);
        invalid_deadline_engine = gq_worker_test_engine::type_id::create(
            "invalid_deadline_engine", this);

        rx_mem = new("rx_mem");
        initialize_mem(rx_mem, 64'h0000_0001_8600_0000);
        rx_adapter = gq_worker_trace_adapter::type_id::create("rx_adapter");
        rx_source = gq_worker_trace_completion::type_id::create("rx_source");
        rx_cfg = make_cfg("rx_cfg", 46, GQ_RX, GQ_POLL, GQ_POLL_FIXED,
                          10ns, 10ns, 0, 0, rx_source);
        configure_engine("rx_engine", rx_cfg, rx_mem, rx_adapter);
        rx_engine = gq_worker_test_engine::type_id::create("rx_engine", this);
    endfunction

    task run_phase(uvm_phase phase);
        mailbox_tx_desc tx_desc;
        mailbox_rx_desc rx_desc;
        int unsigned trace_base;
        int unsigned ack_before;
        int unsigned timeout_before;
        int unsigned query_before;
        time publish_time;
        time rx_start;
        bit poll_wait_returned;
        bit irq_wait_returned;

        phase.raise_objection(this);
        report_catcher = new("report_catcher");
        uvm_report_cb::add(null, report_catcher);

        idle_engine.initialize();
        idle_worker_returned = 0;
        fork : idle_worker
            begin
                idle_engine.run_completion_worker();
                idle_worker_returned = 1;
            end
        join_none
        #1us;
        `uvm_info("GQ_WORKER_TRACE", $sformatf(
            "idle_tx duration=1us queries=%0d", idle_source.query_calls),
            UVM_LOW)
        check_expectation(idle_source.query_calls == 0,
               $sformatf("idle TX issued %0d completion queries in 1us",
                         idle_source.query_calls));
        idle_engine.cleanup();
        wait_for_worker_stop(idle_worker_returned, "idle TX");
        disable idle_worker;
        idle_mem.leak_check(`__FILE__, `__LINE__);

        adaptive_engine.initialize();
        adaptive_source.forced_invalid_queries = 1;
        adaptive_worker_returned = 0;
        fork : adaptive_worker
            begin
                adaptive_engine.run_completion_worker();
                adaptive_worker_returned = 1;
            end
        join_none
        tx_desc = make_tx("adaptive_first", 1);
        submit_one(adaptive_engine, tx_desc, "adaptive_first");
        wait_for_query_count(adaptive_source, 1, "adaptive invalid query");
        wait_for_query_count(adaptive_source, 2, "adaptive retry");
        wait_for_query_count(adaptive_source, 3, "adaptive idle 1");
        wait_for_query_count(adaptive_source, 4, "adaptive idle 2");
        wait_for_query_count(adaptive_source, 5, "adaptive idle 3");
        check_expectation(adaptive_source.query_times[1] -
                   adaptive_source.query_times[0] == 10ns,
               $sformatf("invalid query advanced backoff: retry delta=%0t",
                         adaptive_source.query_times[1] -
                         adaptive_source.query_times[0]));
        check_expectation(adaptive_source.query_times[2] -
                   adaptive_source.query_times[1] == 20ns &&
               adaptive_source.query_times[3] -
                   adaptive_source.query_times[2] == 40ns &&
               adaptive_source.query_times[4] -
                   adaptive_source.query_times[3] == 80ns,
               $sformatf("valid zero queries did not back off 20/40/80ns: %0t/%0t/%0t",
                         adaptive_source.query_times[2] -
                             adaptive_source.query_times[1],
                         adaptive_source.query_times[3] -
                             adaptive_source.query_times[2],
                         adaptive_source.query_times[4] -
                             adaptive_source.query_times[3]));
        check_expectation(adaptive_engine.current_poll_interval() == 100ns,
               $sformatf("adaptive interval did not saturate at 100ns (got %0t)",
                         adaptive_engine.current_poll_interval()));

        #20ns;
        tx_desc = make_tx("adaptive_second", 2);
        submit_one(adaptive_engine, tx_desc, "adaptive_second");
        publish_time = $time;
        query_before = adaptive_source.query_calls;
        #1ns;
        check_expectation(adaptive_source.query_calls == query_before,
               "new work queried immediately instead of beginning a fresh wait");
        wait_for_query_count(adaptive_source, query_before + 1,
                             "adaptive new-work query");
        check_expectation(adaptive_source.query_times[query_before] -
                              publish_time == 10ns,
               $sformatf("new work did not replace 100ns wait with 10ns wait: delta=%0t",
                         adaptive_source.query_times[query_before] -
                         publish_time));
        `uvm_info("GQ_WORKER_TRACE", $sformatf(
            "adaptive invalid_retry=%0t idle_deltas=%0t/%0t/%0t new_work_delta=%0t",
            adaptive_source.query_times[1] - adaptive_source.query_times[0],
            adaptive_source.query_times[2] - adaptive_source.query_times[1],
            adaptive_source.query_times[3] - adaptive_source.query_times[2],
            adaptive_source.query_times[4] - adaptive_source.query_times[3],
            adaptive_source.query_times[query_before] - publish_time), UVM_LOW)

        wait_for_query_count(adaptive_source, query_before + 4,
                             "adaptive pre-retirement backoff");
        check_expectation(adaptive_engine.current_poll_interval() == 100ns,
               $sformatf("adaptive interval was not backed off before retirement (got %0t)",
                         adaptive_engine.current_poll_interval()));
        query_before = adaptive_source.query_calls;
        adaptive_dut.complete_slot(adaptive_engine, 0, 32, 64);
        adaptive_dut.complete_slot(adaptive_engine, 1, 32, 64);
        wait_for_query_count(adaptive_source, query_before + 1,
                             "adaptive progress query");
        for (int unsigned observation = 0; observation < 20;
             observation++) begin
            #10ns;
            if (adaptive_engine.outstanding_count() == 0 &&
                adaptive_engine.current_poll_interval() == 10ns)
                break;
        end
        check_expectation(adaptive_engine.outstanding_count() == 0,
               "progress query did not retire both published descriptors");
        check_expectation(adaptive_engine.current_poll_interval() == 10ns,
               $sformatf("retirement did not independently reset adaptive polling to 10ns (got %0t)",
                         adaptive_engine.current_poll_interval()));
        query_before = adaptive_source.query_calls;
        #1us;
        check_expectation(adaptive_source.query_calls == query_before,
               $sformatf("TX worker did not enter idle gate after retirement: before=%0d after=%0d",
                         query_before, adaptive_source.query_calls));

        tx_desc = make_tx("adaptive_reset_backoff", 6);
        submit_one(adaptive_engine, tx_desc, "adaptive_reset_backoff");
        query_before = adaptive_source.query_calls;
        wait_for_query_count(adaptive_source, query_before + 1,
                             "adaptive reset idle 1");
        wait_for_query_count(adaptive_source, query_before + 2,
                             "adaptive reset idle 2");
        wait_for_query_count(adaptive_source, query_before + 3,
                             "adaptive reset idle 3");
        wait_for_query_count(adaptive_source, query_before + 4,
                             "adaptive reset idle 4");
        check_expectation(adaptive_engine.current_poll_interval() == 100ns,
               $sformatf("pre-reset adaptive interval did not reach 100ns (got %0t)",
                         adaptive_engine.current_poll_interval()));

        adaptive_engine.assert_reset();
        adaptive_engine.release_reset();
        #10ns;
        check_expectation(adaptive_engine.current_poll_interval() == 100ns,
               $sformatf("reset/release changed adaptive interval before new work (got %0t)",
                         adaptive_engine.current_poll_interval()));
        tx_desc = make_tx("adaptive_post_reset", 7);
        submit_one(adaptive_engine, tx_desc, "adaptive_post_reset");
        publish_time = $time;
        query_before = adaptive_source.query_calls;
        #1ns;
        check_expectation(adaptive_source.query_calls == query_before,
               "post-reset publish queried immediately instead of beginning a fresh wait");
        check_expectation(adaptive_engine.current_poll_interval() == 10ns,
               $sformatf("idle-gate new work did not restore 10ns interval (got %0t)",
                         adaptive_engine.current_poll_interval()));
        wait_for_query_count(adaptive_source, query_before + 1,
                             "adaptive post-reset new-work query");
        check_expectation(adaptive_source.query_times[query_before] -
                              publish_time == 10ns,
               $sformatf("post-reset new work used stale adaptive interval: delta=%0t",
                         adaptive_source.query_times[query_before] -
                         publish_time));
        `uvm_info("GQ_WORKER_TRACE", $sformatf(
            "adaptive_reset pre_publish_interval=100ns post_publish_interval=10ns query_delta=%0t",
            adaptive_source.query_times[query_before] - publish_time), UVM_LOW)
        adaptive_engine.cleanup();
        wait_for_worker_stop(adaptive_worker_returned, "adaptive TX");
        disable adaptive_worker;
        adaptive_mem.leak_check(`__FILE__, `__LINE__);

        irq_engine.initialize();
        irq_worker_returned = 0;
        fork : irq_worker
            begin
                irq_engine.run_completion_worker();
                irq_worker_returned = 1;
            end
        join_none
        trace_base = irq_adapter.event_trace.size();
        tx_desc = make_tx("irq_real", 3);
        submit_one(irq_engine, tx_desc, "irq_real");
        wait_for_irq_waits(irq_adapter, 1, "real IRQ arm");
        irq_dut.complete_slot(irq_engine, 0, 32, 64);
        irq_adapter.trigger_irq(GQ_TX, irq_cfg.queue_id);
        wait_for_query_count(irq_source, 1, "real IRQ query");
        check_expectation(trace_matches(irq_adapter, trace_base,
                             "WAIT_IRQ", "ACK_IRQ", "QUERY"),
               $sformatf("real IRQ trace was not WAIT_IRQ, ACK_IRQ, QUERY: base=%0d trace=%s",
                         trace_base, trace_text(irq_adapter)));
        check_expectation(irq_adapter.ack_irq_calls == 1 &&
               irq_engine.outstanding_count() == 0,
               $sformatf("real IRQ ack/retire mismatch ack=%0d outstanding=%0d",
                         irq_adapter.ack_irq_calls,
                         irq_engine.outstanding_count()));

        trace_base = irq_adapter.event_trace.size();
        tx_desc = make_tx("irq_spurious", 4);
        submit_one(irq_engine, tx_desc, "irq_spurious");
        wait_for_irq_waits(irq_adapter, 2, "spurious IRQ arm");
        irq_adapter.trigger_irq(GQ_TX, irq_cfg.queue_id);
        wait_for_query_count(irq_source, 2, "spurious IRQ query");
        check_expectation(trace_matches(irq_adapter, trace_base,
                             "WAIT_IRQ", "ACK_IRQ", "QUERY"),
               "spurious IRQ trace was not WAIT_IRQ, ACK_IRQ, QUERY");
        check_expectation(irq_adapter.ack_irq_calls == 2 &&
               irq_source.query_valids[1] && irq_source.query_counts[1] == 0 &&
               irq_engine.outstanding_count() == 1,
               $sformatf("spurious IRQ ack/query/retire mismatch ack=%0d valid=%0d count=%0d outstanding=%0d",
                         irq_adapter.ack_irq_calls,
                         irq_source.query_valids[1], irq_source.query_counts[1],
                         irq_engine.outstanding_count()));

        wait_for_irq_waits(irq_adapter, 3, "watchdog arm");
        trace_base = irq_adapter.event_trace.size() - 1;
        ack_before = irq_adapter.ack_irq_calls;
        wait_for_query_count(irq_source, 3, "watchdog query");
        check_expectation(trace_matches(irq_adapter, trace_base,
                                        "WAIT_IRQ", "QUERY"),
               "watchdog trace was not WAIT_IRQ, QUERY");
        check_expectation(irq_adapter.ack_irq_calls == ack_before &&
               irq_engine.observed_wakeup() == GQ_WAKE_WATCHDOG,
               $sformatf("watchdog ack/wakeup mismatch ack_before=%0d ack_after=%0d wakeup=%0d",
                         ack_before, irq_adapter.ack_irq_calls,
                         irq_engine.observed_wakeup()));
        `uvm_info("GQ_WORKER_TRACE", $sformatf(
            "irq real=WAIT_IRQ,ACK_IRQ,QUERY ack=1 spurious_valid=%0d spurious_count=%0d watchdog=WAIT_IRQ,QUERY watchdog_ack_delta=%0d",
            irq_source.query_valids[1], irq_source.query_counts[1],
            irq_adapter.ack_irq_calls - ack_before), UVM_LOW)
        irq_engine.cleanup();
        wait_for_worker_stop(irq_worker_returned, "IRQ");
        disable irq_worker;
        irq_mem.leak_check(`__FILE__, `__LINE__);

        poll_reset_engine.initialize();
        poll_wait_returned = 0;
        fork : poll_reset_wait
            begin
                poll_reset_engine.wait_and_drain_once();
                poll_wait_returned = 1;
            end
        join_none
        #10ns;
        poll_reset_engine.assert_reset();
        check_expectation(poll_wait_returned &&
                          poll_reset_source.query_calls == 0,
               $sformatf("poll reset did not cancel cleanly returned=%0d queries=%0d",
                         poll_wait_returned, poll_reset_source.query_calls));
        `uvm_info("GQ_WORKER_TRACE", $sformatf(
            "poll_reset wakeup=GQ_WAKE_CANCELLED queries=%0d",
            poll_reset_source.query_calls), UVM_LOW)
        disable poll_reset_wait;
        poll_reset_engine.cleanup();
        poll_reset_mem.leak_check(`__FILE__, `__LINE__);

        irq_reset_engine.initialize();
        irq_wait_returned = 0;
        fork : irq_reset_wait
            begin
                irq_reset_engine.wait_and_drain_once();
                irq_wait_returned = 1;
            end
        join_none
        wait_for_irq_waits(irq_reset_adapter, 1, "reset IRQ arm");
        irq_reset_engine.assert_reset();
        check_expectation(irq_wait_returned &&
                          irq_reset_source.query_calls == 0 &&
               irq_reset_adapter.ack_irq_calls == 0,
               $sformatf("IRQ reset did not cancel cleanly returned=%0d queries=%0d ack=%0d",
                         irq_wait_returned, irq_reset_source.query_calls,
                         irq_reset_adapter.ack_irq_calls));
        `uvm_info("GQ_WORKER_TRACE", $sformatf(
            "irq_reset wakeup=GQ_WAKE_CANCELLED queries=%0d ack=%0d",
            irq_reset_source.query_calls,
            irq_reset_adapter.ack_irq_calls), UVM_LOW)
        disable irq_reset_wait;
        irq_reset_engine.cleanup();
        irq_reset_mem.leak_check(`__FILE__, `__LINE__);

        timeout_engine.initialize();
        timeout_mem.probe_reads = 1;
        timeout_worker_returned = 0;
        fork : timeout_worker
            begin
                timeout_engine.run_completion_worker();
                timeout_worker_returned = 1;
            end
        join_none
        timeout_before = report_catcher.timeout_count;
        tx_desc = make_tx("timeout_oldest", 5);
        submit_one(timeout_engine, tx_desc, "timeout_oldest");
        #200ns;
        check_expectation(report_catcher.timeout_count - timeout_before == 1,
               $sformatf("oldest published TX timeout reported %0d times",
                         report_catcher.timeout_count - timeout_before));
        check_expectation(timeout_mem.locked_read_callbacks == 0,
               $sformatf("host-memory read callback ran under state_lock %0d time(s)",
                         timeout_mem.locked_read_callbacks));
        `uvm_info("GQ_WORKER_TRACE", $sformatf(
            "tx_timeout reports=%0d queries=%0d",
            report_catcher.timeout_count - timeout_before,
            timeout_source.query_calls), UVM_LOW)
        timeout_engine.cleanup();
        wait_for_worker_stop(timeout_worker_returned, "timeout TX");
        disable timeout_worker;
        timeout_mem.leak_check(`__FILE__, `__LINE__);

        lost_irq_engine.initialize();
        lost_irq_worker_returned = 0;
        fork : lost_irq_worker
            begin
                lost_irq_engine.run_completion_worker();
                lost_irq_worker_returned = 1;
            end
        join_none
        timeout_before = report_catcher.timeout_count;
        tx_desc = make_tx("lost_irq_timeout", 8);
        submit_one(lost_irq_engine, tx_desc, "lost_irq_timeout");
        publish_time = $time;
        for (int unsigned observation = 0; observation < 10;
             observation++) begin
            #10ns;
            if (report_catcher.timeout_count != timeout_before)
                break;
        end
        check_expectation(report_catcher.timeout_count - timeout_before == 1,
               $sformatf("watchdog-zero lost IRQ reported %0d timeout(s)",
                         report_catcher.timeout_count - timeout_before));
        if (report_catcher.timeout_count - timeout_before == 1)
            check_expectation(
                report_catcher.timeout_times[timeout_before] - publish_time ==
                    50ns,
                $sformatf("watchdog-zero timeout arrived at delta %0t",
                    report_catcher.timeout_times[timeout_before] -
                        publish_time));
        check_expectation(lost_irq_source.query_calls == 1 &&
                          lost_irq_adapter.ack_irq_calls == 0,
               $sformatf("watchdog-zero deadline queried/ACKed: queries=%0d ack=%0d",
                         lost_irq_source.query_calls,
                         lost_irq_adapter.ack_irq_calls));
        #50ns;
        check_expectation(report_catcher.timeout_count - timeout_before == 1,
               "watchdog-zero deadline repeated for the same oldest entry");
        lost_irq_engine.cleanup();
        wait_for_worker_stop(lost_irq_worker_returned, "watchdog-zero IRQ");
        disable lost_irq_worker;
        lost_irq_mem.leak_check(`__FILE__, `__LINE__);

        late_watchdog_engine.initialize();
        late_watchdog_worker_returned = 0;
        fork : late_watchdog_worker
            begin
                late_watchdog_engine.run_completion_worker();
                late_watchdog_worker_returned = 1;
            end
        join_none
        timeout_before = report_catcher.timeout_count;
        tx_desc = make_tx("late_watchdog_timeout", 9);
        submit_one(late_watchdog_engine, tx_desc, "late_watchdog_timeout");
        publish_time = $time;
        for (int unsigned observation = 0; observation < 10;
             observation++) begin
            #10ns;
            if (report_catcher.timeout_count != timeout_before)
                break;
        end
        check_expectation(report_catcher.timeout_count - timeout_before == 1,
               $sformatf("late-watchdog case reported %0d timeout(s)",
                         report_catcher.timeout_count - timeout_before));
        if (report_catcher.timeout_count - timeout_before == 1)
            check_expectation(
                report_catcher.timeout_times[timeout_before] - publish_time ==
                    60ns,
                $sformatf("late-watchdog timeout arrived at delta %0t",
                    report_catcher.timeout_times[timeout_before] -
                        publish_time));
        check_expectation(late_watchdog_source.query_calls == 1 &&
                          late_watchdog_adapter.ack_irq_calls == 0,
               $sformatf("deadline later than watchdog ordering was wrong: queries=%0d ack=%0d",
                         late_watchdog_source.query_calls,
                         late_watchdog_adapter.ack_irq_calls));
        late_watchdog_engine.cleanup();
        wait_for_worker_stop(late_watchdog_worker_returned,
                             "late-watchdog IRQ");
        disable late_watchdog_worker;
        late_watchdog_mem.leak_check(`__FILE__, `__LINE__);

        invalid_deadline_engine.initialize();
        invalid_deadline_source.forced_invalid_queries = 32'hffff_ffff;
        invalid_deadline_worker_returned = 0;
        fork : invalid_deadline_worker
            begin
                invalid_deadline_engine.run_completion_worker();
                invalid_deadline_worker_returned = 1;
            end
        join_none
        timeout_before = report_catcher.timeout_count;
        query_before = report_catcher.invalid_query_count;
        tx_desc = make_tx("invalid_query_timeout", 10);
        submit_one(invalid_deadline_engine, tx_desc, "invalid_query_timeout");
        publish_time = $time;
        for (int unsigned observation = 0; observation < 20;
             observation++) begin
            #10ns;
            if (report_catcher.timeout_count != timeout_before)
                break;
        end
        check_expectation(report_catcher.timeout_count - timeout_before == 1,
               $sformatf("persistent invalid queries reported %0d timeout(s)",
                         report_catcher.timeout_count - timeout_before));
        if (report_catcher.timeout_count - timeout_before == 1)
            check_expectation(
                report_catcher.timeout_times[timeout_before] - publish_time ==
                    130ns,
                $sformatf("invalid-query timeout arrived at delta %0t",
                    report_catcher.timeout_times[timeout_before] -
                        publish_time));
        check_expectation(
            report_catcher.invalid_query_count - query_before == 5,
            $sformatf("persistent-invalid case caught %0d query warnings instead of 5 including deadline settlement",
                report_catcher.invalid_query_count - query_before));
        invalid_deadline_engine.cleanup();
        wait_for_worker_stop(invalid_deadline_worker_returned,
                             "persistent-invalid Poll");
        disable invalid_deadline_worker;
        invalid_deadline_mem.leak_check(`__FILE__, `__LINE__);

        rx_engine.initialize();
        rx_desc = mailbox_rx_desc::type_id::create("rx_zero_timeout_desc");
        rx_desc.buf_len = 16;
        submit_one(rx_engine, rx_desc, "rx_zero_timeout");
        timeout_before = report_catcher.timeout_count;
        rx_start = $time;
        rx_worker_returned = 0;
        fork : rx_worker
            begin
                rx_engine.run_completion_worker();
                rx_worker_returned = 1;
            end
        join_none
        #20us;
        check_expectation(report_catcher.timeout_count == timeout_before,
               $sformatf("RX completion_timeout=0 reported %0d timeout(s)",
                         report_catcher.timeout_count - timeout_before));
        check_expectation(rx_source.query_calls >= 1900 &&
                          rx_source.query_calls <= 2100,
               $sformatf("RX idle polling was not bounded at 10ns: queries=%0d",
                         rx_source.query_calls));
        `uvm_info("GQ_WORKER_TRACE", $sformatf(
            "rx_zero_timeout duration=%0t reports=%0d queries=%0d",
            $time - rx_start,
            report_catcher.timeout_count - timeout_before,
            rx_source.query_calls), UVM_LOW)
        rx_engine.cleanup();
        wait_for_worker_stop(rx_worker_returned, "RX zero-timeout");
        disable rx_worker;
        rx_mem.leak_check(`__FILE__, `__LINE__);

        uvm_report_cb::delete(null, report_catcher);
        check_expectation(report_catcher.invalid_query_count == 6,
               $sformatf("expected six caught invalid-query warnings, got %0d",
                         report_catcher.invalid_query_count));
        if (expectation_failures != 0)
            `uvm_fatal("GQ_WORKER_WAKEUP", $sformatf(
                "%0d worker wakeup expectation(s) failed",
                expectation_failures))
        phase.drop_objection(this);
    endtask
endclass

`endif
