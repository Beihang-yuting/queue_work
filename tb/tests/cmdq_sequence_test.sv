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

class cmdq_sequence_mem extends host_mem_manager;
    bit freed_addresses[gq_addr_t];

    function new(string name = "cmdq_sequence_mem");
        super.new(name);
    endfunction

    virtual function bit [63:0] alloc(int unsigned size,
                                      int unsigned align = 1,
                                      string file = "", int line = 0);
        gq_addr_t addr;

        addr = super.alloc(size, align, file, line);
        freed_addresses.delete(addr);
        return addr;
    endfunction

    virtual function void free(bit [63:0] addr, string file = "",
                               int line = 0);
        freed_addresses[addr] = 1;
        super.free(addr, file, line);
    endfunction

    function bit was_freed(gq_addr_t addr);
        return freed_addresses.exists(addr) && freed_addresses[addr];
    endfunction
endclass

class cmdq_sequence_timeout_catcher extends uvm_report_catcher;
    `uvm_object_utils(cmdq_sequence_timeout_catcher)

    int unsigned timeout_count;

    function new(string name = "cmdq_sequence_timeout_catcher");
        super.new(name);
        timeout_count = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR &&
            get_id() == "GQ_COMPLETION_TIMEOUT") begin
            timeout_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class cmdq_scripted_driver extends uvm_driver #(gq_request, gq_response);
    `uvm_component_utils(cmdq_scripted_driver)

    cmdq_sequence_mem mem;
    byte expected_request[];
    bit [15:0] expected_dst_id;
    byte completion_bytes[];
    time completion_delay;
    bit complete_after_nba;
    bit complete_one_step_late;
    bit return_submit_error;
    int unsigned request_count;
    bit saw_submit;
    bit completed_before_response;
    gq_addr_t captured_tx_addr;
    gq_addr_t captured_rx_addr;

    function new(string name = "cmdq_scripted_driver",
                 uvm_component parent = null);
        super.new(name, parent);
        expected_request = new[0];
        completion_bytes = new[0];
        completion_delay = 0;
        complete_after_nba = 0;
        complete_one_step_late = 0;
        return_submit_error = 0;
        request_count = 0;
        saw_submit = 0;
        completed_before_response = 0;
        captured_tx_addr = '1;
        captured_rx_addr = '1;
    endfunction

    protected task complete_desc(cmdq_tx_desc desc);
        if (completion_delay != 0)
            #(completion_delay);
        if (complete_after_nba)
            uvm_wait_for_nba_region();
        if (complete_one_step_late)
            #1step;
        if (completion_bytes.size() != 0)
            mem.write_mem(desc.rx_buf_addr, completion_bytes,
                          `__FILE__, `__LINE__);
        desc.flags = CMDQ_DESC_AVAIL | CMDQ_DESC_USED;
        desc.rx_buf_len = completion_bytes.size();
        if (!desc.parse_completion())
            `uvm_fatal("CMDQ_SEQUENCE_PARSE",
                       "scripted completion did not parse")
        desc.release_owned();
        completed_before_response = desc.completion_event.is_on() &&
                                    desc.owned_allocation_count() == 0;
    endtask

    task run_phase(uvm_phase phase);
        gq_request request;
        gq_response response;
        cmdq_tx_desc desc;

        forever begin
            seq_item_port.get_next_item(request);
            request_count++;
            if (request == null || request.kind != GQ_SUBMIT ||
                request.size() != 1 || !$cast(desc, request.descs[0]))
                `uvm_fatal("CMDQ_SEQUENCE_REQUEST",
                           "sequence did not submit exactly one CMDQ descriptor")
            saw_submit = 1;
            if (desc.dst_id != expected_dst_id ||
                desc.request.size() != expected_request.size())
                `uvm_fatal("CMDQ_SEQUENCE_REQUEST",
                           "sequence descriptor metadata is incorrect")
            foreach (expected_request[i]) begin
                if (desc.request[i] !== expected_request[i])
                    `uvm_fatal("CMDQ_SEQUENCE_REQUEST", $sformatf(
                        "request byte %0d is 0x%02h, expected 0x%02h",
                        i, desc.request[i], expected_request[i]))
            end

            response = gq_response::type_id::create("response");
            response.set_id_info(request);
            if (return_submit_error) begin
                response.status = GQ_RESOURCE_ERROR;
                response.committed_count = 0;
            end else begin
                desc.attach_mem(mem);
                if (!desc.prepare())
                    `uvm_fatal("CMDQ_SEQUENCE_PREPARE",
                               "scripted completion could not prepare descriptor")
                captured_tx_addr = desc.tx_buf_addr;
                captured_rx_addr = desc.rx_buf_addr;
                if (completion_delay == 0)
                    complete_desc(desc);
                else begin
                    fork
                        complete_desc(desc);
                    join_none
                end
                response.status = GQ_OK;
                response.committed_count = 1;
            end
            seq_item_port.item_done(response);
        end
    endtask
endclass

class cmdq_sequence_adapter extends cmdq_mock_adapter;
    `uvm_object_utils(cmdq_sequence_adapter)

    host_mem_manager mem;
    gq_addr_t ring_base;
    byte expected_request[];
    bit [15:0] expected_dst_id;
    byte completion_bytes[];
    bit auto_complete;
    time completion_delay;
    int unsigned observed_submits;
    gq_addr_t captured_tx_addr;
    gq_addr_t captured_rx_addr;

    function new(string name = "cmdq_sequence_adapter");
        super.new(name);
        expected_request = new[0];
        completion_bytes = new[0];
        auto_complete = 0;
        completion_delay = 0;
        observed_submits = 0;
        captured_tx_addr = '1;
        captured_rx_addr = '1;
    endfunction

    protected function bit [15:0] decode_u16(input byte data[],
                                             int unsigned offset);
        return {data[offset + 1], data[offset]};
    endfunction

    protected function gq_addr_t decode_u64(input byte data[],
                                             int unsigned offset);
        gq_addr_t value;

        value = '0;
        for (int unsigned i = 0; i < 8; i++)
            value[i*8 +: 8] = data[offset + i];
        return value;
    endfunction

    protected task inspect_slot(int unsigned slot, output byte raw[]);
        byte tx_storage[];
        bit [15:0] tx_len;

        mem.read_mem(ring_base + (slot * CMDQ_DESC_BYTES), CMDQ_DESC_BYTES,
                     raw, `__FILE__, `__LINE__);
        tx_len = decode_u16(raw, 2);
        captured_tx_addr = decode_u64(raw, 4);
        captured_rx_addr = decode_u64(raw, 16);
        if (decode_u16(raw, 0) != CMDQ_DESC_AVAIL ||
            tx_len != expected_request.size() ||
            decode_u16(raw, 12) != expected_dst_id ||
            decode_u16(raw, 14) != CMDQ_BUFFER_BYTES)
            `uvm_fatal("CMDQ_SEQUENCE_SLOT",
                       "published CMDQ descriptor fields are incorrect")
        mem.read_mem(captured_tx_addr, CMDQ_BUFFER_BYTES, tx_storage,
                     `__FILE__, `__LINE__);
        foreach (expected_request[i]) begin
            if (tx_storage[i] !== expected_request[i])
                `uvm_fatal("CMDQ_SEQUENCE_SLOT", $sformatf(
                    "published request byte %0d is 0x%02h, expected 0x%02h",
                    i, tx_storage[i], expected_request[i]))
        end
        for (int unsigned i = expected_request.size();
             i < CMDQ_BUFFER_BYTES; i++) begin
            if (tx_storage[i] !== 0)
                `uvm_fatal("CMDQ_SEQUENCE_SLOT", $sformatf(
                    "published request padding byte %0d is not zero", i))
        end
    endtask

    protected task complete_slot(int unsigned slot, byte raw[]);
        if (completion_delay != 0)
            #(completion_delay);
        if (completion_bytes.size() != 0)
            mem.write_mem(captured_rx_addr, completion_bytes,
                          `__FILE__, `__LINE__);
        raw[0] = byte'(CMDQ_DESC_AVAIL | CMDQ_DESC_USED);
        raw[1] = 0;
        raw[14] = byte'(completion_bytes.size());
        raw[15] = byte'(completion_bytes.size() >> 8);
        mem.write_mem(ring_base + (slot * CMDQ_DESC_BYTES), raw,
                      `__FILE__, `__LINE__);
    endtask

    virtual task write_cmdq_tail(int unsigned queue_id, bit [15:0] tail);
        int unsigned slot;
        byte raw[];

        slot = observed_submits;
        inspect_slot(slot, raw);
        observed_submits++;
        if (auto_complete) begin
            fork
                complete_slot(slot, raw);
            join_none
        end
        super.write_cmdq_tail(queue_id, tail);
    endtask
endclass

class cmdq_sequence_test extends uvm_test;
    `uvm_component_utils(cmdq_sequence_test)

    cmdq_sequence_mem mem;
    cmdq_sequence_adapter adapter;
    cmdq_env_cfg env_cfg;
    gq_env env;
    gq_sequencer early_sequencer;
    cmdq_scripted_driver early_driver;
    gq_sequencer error_sequencer;
    cmdq_scripted_driver error_driver;

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
        cmdq_env_cfg null_adapter_cfg;
        cmdq_env_cfg wrong_adapter_cfg;
        cmdq_env_cfg irq_env_cfg;
        cmdq_mock_adapter irq_adapter;
        cmdq_wrong_adapter wrong_adapter;
        cmdq_hw_cfg_t hw_cfg;
        cmdq_hw_cfg_t duplicate_hw_cfg;
        cmdq_hw_cfg_t distinct_hw_cfg;
        gq_queue_cfg cfg;
        gq_queue_cfg irq_cfg;
        cmdq_ptr_codec installed_codec;
        cmdq_completion installed_completion;
        string reason;
        string key;
        int unsigned queue_count;

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_8000_0000,
                        64'h0000_0001_80ff_ffff, MODE_LINEAR, 16);
        adapter = cmdq_sequence_adapter::type_id::create("adapter");
        adapter.mem = mem;
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

        distinct_hw_cfg.host_id     = 8'h3c;
        distinct_hw_cfg.function_id = 16'h2468;
        distinct_hw_cfg.msix_index  = 16'h1357;
        distinct_hw_cfg.msix_valid  = 1'b1;
        if (env_cfg.add_cmdq(1, distinct_hw_cfg, reason) || reason == "")
            `uvm_fatal("CMDQ_PROFILE_CARDINALITY",
                       "a second distinct standard CMDQ ring was accepted")
        if (env_cfg.queues.num() != queue_count ||
            !env_cfg.queues.exists(key) || env_cfg.queues[key] != cfg ||
            env_cfg.queues.exists(gq_queue_key(GQ_TX, 1)) ||
            adapter.hw_cfg != hw_cfg)
            `uvm_fatal("CMDQ_PROFILE_CARDINALITY_STATE",
                       {"distinct-ID rejection changed the original queue ",
                        "map or adapter metadata"})

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

        uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", env_cfg);
        env = gq_env::type_id::create("env", this);

        early_sequencer = gq_sequencer::type_id::create(
            "early_sequencer", this);
        early_driver = cmdq_scripted_driver::type_id::create(
            "early_driver", this);
        early_driver.mem = mem;
        error_sequencer = gq_sequencer::type_id::create(
            "error_sequencer", this);
        error_driver = cmdq_scripted_driver::type_id::create(
            "error_driver", this);
        error_driver.mem = mem;
        error_driver.return_submit_error = 1;

    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        early_driver.seq_item_port.connect(early_sequencer.seq_item_export);
        error_driver.seq_item_port.connect(error_sequencer.seq_item_export);
    endfunction

    task expect_released(gq_addr_t tx_addr, gq_addr_t rx_addr,
                         string check_name);
        if (!mem.was_freed(tx_addr) || !mem.was_freed(rx_addr))
            `uvm_fatal("CMDQ_SEQUENCE_LIFETIME",
                       {check_name, " did not release both owned host buffers"})
    endtask

    task run_phase(uvm_phase phase);
        uvm_component component_handle;
        gq_sequencer sequencer;
        gq_queue_engine engine;
        cmdq_command_sequence command_seq;
        cmdq_sequence_timeout_catcher timeout_catcher;
        byte fse_request[] = '{8'h17, 8'h2a, 8'hc4, 8'h09};
        byte pstat_request[] = '{8'h81, 8'h00, 8'h5e};
        byte pstat_result[] = '{8'hd3, 8'h14, 8'h59, 8'h26,
                                8'h53, 8'h58, 8'h97};
        byte failed_request[] = '{8'he1, 8'h7b};
        byte timeout_request[] = '{8'h44, 8'h20, 8'h10, 8'h08, 8'h04};
        time started_at;
        time returned_at;
        int unsigned submit_count_before;

        phase.raise_objection(this);
        env_cfg.wait_ready();
        adapter.ring_base = env.ring_base(gq_queue_key(GQ_TX, 0));
        component_handle = uvm_root::get().find(
            "uvm_test_top.env.tx_0.sequencer");
        if (!$cast(sequencer, component_handle))
            `uvm_fatal("CMDQ_SEQUENCE_PATH", "could not find CMDQ sequencer")
        component_handle = uvm_root::get().find(
            "uvm_test_top.env.tx_0.engine");
        if (!$cast(engine, component_handle))
            `uvm_fatal("CMDQ_SEQUENCE_PATH", "could not find CMDQ engine")

        // Mutation caught: using a transient trigger wait loses completion;
        // omitting payload/destination copies changes the submitted descriptor.
        early_driver.expected_request = fse_request;
        early_driver.expected_dst_id = CMDQ_DST_FSE;
        early_driver.completion_bytes = new[0];
        command_seq = cmdq_command_sequence::type_id::create("early_sequence");
        command_seq.request_payload = fse_request;
        command_seq.dst_id = CMDQ_DST_FSE;
        started_at = $time;
        command_seq.start(early_sequencer);
        if (!early_driver.completed_before_response ||
            command_seq.result_status != CMDQ_RESULT_OK ||
            command_seq.result.size() != 0 || $time != started_at ||
            early_driver.request_count != 1)
            `uvm_fatal("CMDQ_SEQUENCE_EARLY",
                       "early FSE completion was lost or returned incorrectly")
        expect_released(early_driver.captured_tx_addr,
                        early_driver.captured_rx_addr, "early_completion");

        // Mutation caught: copying the result after GQ releases descriptor
        // buffers loses the independently derived seven PSTAT result bytes.
        adapter.expected_request = pstat_request;
        adapter.expected_dst_id = CMDQ_DST_PSTAT;
        adapter.completion_bytes = pstat_result;
        adapter.completion_delay = 100ns;
        adapter.auto_complete = 1;
        command_seq = cmdq_command_sequence::type_id::create("pstat_sequence");
        command_seq.request_payload = pstat_request;
        command_seq.dst_id = CMDQ_DST_PSTAT;
        command_seq.start(sequencer);
        if (command_seq.result_status != CMDQ_RESULT_OK ||
            command_seq.result.size() != 7 ||
            adapter.observed_submits != 1)
            `uvm_fatal("CMDQ_SEQUENCE_PSTAT",
                       "PSTAT result or submit count is incorrect")
        foreach (pstat_result[i]) begin
            if (command_seq.result[i] !== pstat_result[i])
                `uvm_fatal("CMDQ_SEQUENCE_PSTAT", $sformatf(
                    "PSTAT result byte %0d is 0x%02h, expected 0x%02h",
                    i, command_seq.result[i], pstat_result[i]))
        end
        while (engine.outstanding_count() != 0)
            #10ns;
        expect_released(adapter.captured_tx_addr,
                        adapter.captured_rx_addr, "pstat_completion");
        if (command_seq.result_status != CMDQ_RESULT_OK ||
            command_seq.result.size() != 7)
            `uvm_fatal("CMDQ_SEQUENCE_PSTAT_RELEASED",
                       "released PSTAT result status or length is incorrect")
        foreach (pstat_result[i]) begin
            if (command_seq.result[i] !== pstat_result[i])
                `uvm_fatal("CMDQ_SEQUENCE_PSTAT_RELEASED", $sformatf(
                    {"released PSTAT result byte %0d is 0x%02h, ",
                     "expected 0x%02h"},
                    i, command_seq.result[i], pstat_result[i]))
        end

        // Mutation caught: timeout winning solely because its delay wakes in
        // the deadline slot violates the inclusive completion deadline.
        early_driver.expected_request = pstat_request;
        early_driver.expected_dst_id = CMDQ_DST_PSTAT;
        early_driver.completion_bytes = pstat_result;
        early_driver.completion_delay = 10us;
        early_driver.complete_after_nba = 1;
        command_seq = cmdq_command_sequence::type_id::create(
            "deadline_sequence");
        command_seq.request_payload = pstat_request;
        command_seq.dst_id = CMDQ_DST_PSTAT;
        started_at = $time;
        command_seq.start(early_sequencer);
        if (command_seq.result_status != CMDQ_RESULT_OK ||
            command_seq.result.size() != 7 || $time - started_at != 10us ||
            early_driver.request_count != 2)
            `uvm_fatal("CMDQ_SEQUENCE_DEADLINE",
                       "completion did not win at the inclusive deadline")
        foreach (pstat_result[i]) begin
            if (command_seq.result[i] !== pstat_result[i])
                `uvm_fatal("CMDQ_SEQUENCE_DEADLINE", $sformatf(
                    "deadline result byte %0d is 0x%02h, expected 0x%02h",
                    i, command_seq.result[i], pstat_result[i]))
        end
        expect_released(early_driver.captured_tx_addr,
                        early_driver.captured_rx_addr,
                        "deadline_completion");

        // Mutation caught: accepting any event observed after settlement lets
        // a completion one timeprecision beyond the deadline win.
        early_driver.complete_after_nba = 0;
        early_driver.complete_one_step_late = 1;
        command_seq = cmdq_command_sequence::type_id::create(
            "late_completion_sequence");
        command_seq.request_payload = pstat_request;
        command_seq.dst_id = CMDQ_DST_PSTAT;
        command_seq.start(early_sequencer);
        #1step;
        if (command_seq.result_status != CMDQ_RESULT_TIMEOUT ||
            command_seq.result.size() != 0 ||
            early_driver.request_count != 3)
            `uvm_fatal("CMDQ_SEQUENCE_LATE",
                       "after-deadline completion did not remain a timeout")
        expect_released(early_driver.captured_tx_addr,
                        early_driver.captured_rx_addr,
                        "late_completion");

        // Mutation caught: treating a failed response as committed waits for
        // completion (or times out) instead of returning a submit error now.
        error_driver.expected_request = failed_request;
        error_driver.expected_dst_id = CMDQ_DST_FSE;
        command_seq = cmdq_command_sequence::type_id::create("error_sequence");
        command_seq.request_payload = failed_request;
        command_seq.dst_id = CMDQ_DST_FSE;
        started_at = $time;
        command_seq.start(error_sequencer);
        if (command_seq.result_status != CMDQ_RESULT_SUBMIT_ERROR ||
            command_seq.result.size() != 0 || $time != started_at ||
            error_driver.request_count != 1 || !error_driver.saw_submit)
            `uvm_fatal("CMDQ_SEQUENCE_SUBMIT_ERROR",
                       "failed submit did not return immediately and empty")

        // Mutation caught: a wrong/default delay, status, or stale result
        // violates the exact 10 us no-completion contract.
        adapter.expected_request = timeout_request;
        adapter.expected_dst_id = CMDQ_DST_FSE;
        adapter.completion_bytes = new[0];
        adapter.auto_complete = 0;
        timeout_catcher = cmdq_sequence_timeout_catcher::type_id::create(
            "timeout_catcher");
        uvm_report_cb::add(null, timeout_catcher);
        submit_count_before = adapter.observed_submits;
        command_seq = cmdq_command_sequence::type_id::create("timeout_sequence");
        command_seq.request_payload = timeout_request;
        command_seq.dst_id = CMDQ_DST_FSE;
        started_at = $time;
        command_seq.start(sequencer);
        returned_at = $time;
        #1ns;
        uvm_report_cb::delete(null, timeout_catcher);
        if (command_seq.result_status != CMDQ_RESULT_TIMEOUT ||
            command_seq.result.size() != 0 ||
            returned_at - started_at != 10us ||
            adapter.observed_submits != submit_count_before + 1 ||
            timeout_catcher.timeout_count != 1)
            `uvm_fatal("CMDQ_SEQUENCE_TIMEOUT", $sformatf(
                {"timeout result mismatch: status=%0d size=%0d elapsed=%0t ",
                 "submits=%0d engine_timeouts=%0d"},
                command_seq.result_status, command_seq.result.size(),
                returned_at - started_at,
                adapter.observed_submits - submit_count_before,
                timeout_catcher.timeout_count))

        phase.drop_objection(this);
    endtask
endclass

`endif
