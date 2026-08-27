`ifndef CMDQ_DRIVER_CONFORMANCE_TEST_SV
`define CMDQ_DRIVER_CONFORMANCE_TEST_SV

class cmdq_driver_observation extends uvm_object;
    `uvm_object_utils(cmdq_driver_observation)

    byte request_bytes[];
    byte result_bytes[];
    bit [15:0] flags;
    bit [15:0] rx_buf_len;
    gq_addr_t tx_buf_addr;
    gq_addr_t rx_buf_addr;
    int unsigned owned_allocation_count;
    time callback_time;

    function new(string name = "cmdq_driver_observation");
        super.new(name);
        request_bytes = new[0];
        result_bytes = new[0];
        flags = 0;
        rx_buf_len = 0;
        tx_buf_addr = 0;
        rx_buf_addr = 0;
        owned_allocation_count = 0;
        callback_time = 0;
    endfunction
endclass

class cmdq_driver_collector extends uvm_component;
    `uvm_component_utils(cmdq_driver_collector)

    uvm_analysis_imp #(gq_desc_base, cmdq_driver_collector) analysis_export;
    cmdq_driver_observation observations[$];
    uvm_event observation_event;

    function new(string name = "cmdq_driver_collector",
                 uvm_component parent = null);
        super.new(name, parent);
        analysis_export = new("analysis_export", this);
        observation_event = new({name, "_observation"});
    endfunction

    function void write(gq_desc_base base_desc);
        cmdq_tx_desc desc;
        cmdq_driver_observation observation;

        if (!$cast(desc, base_desc))
            `uvm_fatal("CMDQ_DRIVER_CALLBACK",
                       "completion callback was not a CMDQ descriptor")
        observation = cmdq_driver_observation::type_id::create(
            $sformatf("observation_%0d", observations.size()));
        observation.request_bytes = new[desc.request.size()];
        foreach (desc.request[i])
            observation.request_bytes[i] = desc.request[i];
        observation.result_bytes = new[desc.result.size()];
        foreach (desc.result[i])
            observation.result_bytes[i] = desc.result[i];
        observation.flags = desc.flags;
        observation.rx_buf_len = desc.rx_buf_len;
        observation.tx_buf_addr = desc.tx_buf_addr;
        observation.rx_buf_addr = desc.rx_buf_addr;
        observation.owned_allocation_count = desc.owned_allocation_count();
        observation.callback_time = $time;
        observations.push_back(observation);
        observation_event.trigger();
    endfunction
endclass

class cmdq_driver_report_catcher extends uvm_report_catcher;
    `uvm_object_utils(cmdq_driver_report_catcher)

    int unsigned invalid_query_count;
    int unsigned parse_error_count;
    int unsigned timeout_count;
    uvm_event timeout_event;

    function new(string name = "cmdq_driver_report_catcher");
        super.new(name);
        invalid_query_count = 0;
        parse_error_count = 0;
        timeout_count = 0;
        timeout_event = new({name, "_timeout"});
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_WARNING &&
            get_id() == "GQ_COMPLETION_QUERY") begin
            invalid_query_count++;
            return CAUGHT;
        end
        if (get_severity() == UVM_ERROR &&
            get_id() == "GQ_COMPLETION_PARSE") begin
            parse_error_count++;
            return CAUGHT;
        end
        if (get_severity() == UVM_ERROR &&
            get_id() == "GQ_COMPLETION_TIMEOUT") begin
            timeout_count++;
            timeout_event.trigger();
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class cmdq_driver_conformance_test extends uvm_test;
    `uvm_component_utils(cmdq_driver_conformance_test)

    localparam int unsigned SEQUENCE_Q   = 0;
    localparam int unsigned WRAP_Q       = 1;
    localparam int unsigned ADAPTIVE_Q   = 2;
    localparam int unsigned TIMEOUT_Q    = 3;
    localparam int unsigned IRQ_Q        = 4;
    localparam int unsigned ERROR_Q      = 5;
    localparam int unsigned RESET_READ_Q = 6;
    localparam int unsigned RESET_ACK_Q  = 7;
    localparam int unsigned QUEUE_COUNT  = 8;

    cmdq_driver_mem mem;
    cmdq_mock_adapter adapter;
    cmdq_mock_dut dut;
    gq_queue_cfg cfgs[int unsigned];
    cmdq_mock_completion completions[int unsigned];
    gq_queue_engine engines[int unsigned];
    cmdq_driver_collector collectors[int unsigned];
    bit worker_started[int unsigned];
    bit worker_returned[int unsigned];
    gq_sequencer sequence_sequencer;
    gq_driver sequence_driver;
    cmdq_driver_report_catcher report_catcher;

    function new(string name = "cmdq_driver_conformance_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function bit bytes_equal(input byte lhs[], input byte rhs[]);
        if (lhs.size() != rhs.size())
            return 0;
        foreach (lhs[i]) begin
            if (lhs[i] !== rhs[i])
                return 0;
        end
        return 1;
    endfunction

    function gq_queue_cfg make_cfg(int unsigned queue_id);
        gq_queue_cfg cfg;

        cfg = gq_queue_cfg::type_id::create(
            $sformatf("tx_%0d_cfg", queue_id));
        cfg.queue_id = queue_id;
        cfg.role = GQ_TX;
        cfg.depth = 32;
        cfg.desc_size = 32;
        cfg.alignment = 64;
        cfg.status_area_size = 0;
        cfg.wait_mode = (queue_id == IRQ_Q || queue_id == RESET_ACK_Q) ?
                        GQ_IRQ : GQ_POLL;
        cfg.poll_policy = queue_id == ADAPTIVE_Q ?
                          GQ_POLL_ADAPTIVE : GQ_POLL_FIXED;
        cfg.poll_min_interval = 10ns;
        cfg.poll_max_interval = queue_id == ADAPTIVE_Q ? 100ns : 10ns;
        cfg.poll_backoff_factor = 2;
        cfg.irq_watchdog_interval =
            (queue_id == IRQ_Q || queue_id == RESET_ACK_Q) ? 1us : 0;
        cfg.completion_timeout = queue_id == TIMEOUT_Q ? 100ns : 10us;
        cfg.ptr_codec = cmdq_ptr_codec::type_id::create(
            $sformatf("tx_%0d_ptr_codec", queue_id));
        completions[queue_id] = cmdq_mock_completion::type_id::create(
            $sformatf("tx_%0d_completion", queue_id));
        cfg.completion_source = completions[queue_id];
        completions[queue_id].queue_id = queue_id;
        return cfg;
    endfunction

    function void build_phase(uvm_phase phase);
        cmdq_hw_cfg_t hw_cfg;
        string engine_name;
        string collector_name;
        string reason;

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_e000_0000,
                        64'h0000_0001_e0ff_ffff, MODE_LINEAR, 16);
        adapter = cmdq_mock_adapter::type_id::create("adapter");
        hw_cfg.host_id = 8'h5a;
        hw_cfg.function_id = 16'h1234;
        hw_cfg.msix_index = 16'h0042;
        hw_cfg.msix_valid = 1'b1;
        adapter.hw_cfg = hw_cfg;
        dut = cmdq_mock_dut::type_id::create("dut");
        dut.mem = mem;
        dut.adapter = adapter;

        for (int unsigned queue_id = 0; queue_id < QUEUE_COUNT;
             queue_id++) begin
            cfgs[queue_id] = make_cfg(queue_id);
            if (!cfgs[queue_id].validate(reason))
                `uvm_fatal("CMDQ_DRIVER_CFG", $sformatf(
                    "queue %0d configuration rejected: %s",
                    queue_id, reason))
            engine_name = $sformatf("engine_%0d", queue_id);
            collector_name = $sformatf("collector_%0d", queue_id);
            uvm_config_db#(gq_queue_cfg)::set(
                this, engine_name, "cfg", cfgs[queue_id]);
            uvm_config_db#(host_mem_api)::set(
                this, engine_name, "mem", mem);
            uvm_config_db#(gq_hw_adapter)::set(
                this, engine_name, "adapter", adapter);
            engines[queue_id] = gq_queue_engine::type_id::create(
                engine_name, this);
            collectors[queue_id] = cmdq_driver_collector::type_id::create(
                collector_name, this);
            worker_started[queue_id] = 0;
            worker_returned[queue_id] = 0;
        end

        sequence_sequencer = gq_sequencer::type_id::create(
            "sequence_sequencer", this);
        sequence_driver = gq_driver::type_id::create(
            "sequence_driver", this);
        report_catcher = cmdq_driver_report_catcher::type_id::create(
            "report_catcher");
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        for (int unsigned queue_id = 0; queue_id < QUEUE_COUNT;
             queue_id++)
            engines[queue_id].completion_ap.connect(
                collectors[queue_id].analysis_export);
        sequence_driver.engine = engines[SEQUENCE_Q];
        sequence_driver.seq_item_port.connect(
            sequence_sequencer.seq_item_export);
    endfunction

    task initialize_queue(int unsigned queue_id);
        int unsigned reset_before;
        int unsigned configure_before;
        int unsigned enable_before;

        reset_before = adapter.reset_count.exists(queue_id) ?
                       adapter.reset_count[queue_id] : 0;
        configure_before = adapter.configure_count.exists(queue_id) ?
                           adapter.configure_count[queue_id] : 0;
        enable_before = adapter.enable_count.exists(queue_id) ?
                        adapter.enable_count[queue_id] : 0;
        engines[queue_id].initialize();
        if (!engines[queue_id].is_ready() ||
            adapter.reset_count[queue_id] != reset_before + 1 ||
            adapter.configure_count[queue_id] != configure_before + 1 ||
            adapter.enable_count[queue_id] != enable_before + 1 ||
            adapter.configured_depth[queue_id] != 32 ||
            adapter.configured_desc_size[queue_id] != 32)
            `uvm_fatal("CMDQ_DRIVER_SETUP", $sformatf(
                "queue %0d did not RESET,CONFIGURE(32,32),ENABLE",
                queue_id))
    endtask

    task start_worker(int unsigned queue_id);
        automatic int unsigned worker_queue = queue_id;

        if (worker_started[queue_id])
            return;
        worker_started[queue_id] = 1;
        fork
            begin
                engines[worker_queue].run_completion_worker();
                worker_returned[worker_queue] = 1;
            end
        join_none
    endtask

    task wait_for_publish_count(int unsigned queue_id,
                                int unsigned expected_count,
                                string label);
        while (adapter.published_tails[queue_id].size() < expected_count) begin
            adapter.publish_events[queue_id].reset();
            if (adapter.published_tails[queue_id].size() < expected_count)
                adapter.publish_events[queue_id].wait_on();
        end
        if (adapter.published_tails[queue_id].size() != expected_count)
            `uvm_fatal("CMDQ_DRIVER_PUBLISH", {label,
                       " observed an unexpected extra publish"})
    endtask

    task wait_for_queries(int unsigned queue_id,
                          int unsigned expected_count,
                          string label);
        while (completions[queue_id].query_times.size() < expected_count) begin
            completions[queue_id].query_event.reset();
            if (completions[queue_id].query_times.size() < expected_count)
                completions[queue_id].query_event.wait_on();
        end
        if (completions[queue_id].query_times.size() != expected_count)
            `uvm_fatal("CMDQ_DRIVER_QUERY", {label,
                       " observed an unexpected extra query"})
    endtask

    task wait_for_observations(int unsigned queue_id,
                               int unsigned expected_count,
                               string label);
        while (collectors[queue_id].observations.size() < expected_count) begin
            collectors[queue_id].observation_event.reset();
            if (collectors[queue_id].observations.size() < expected_count)
                collectors[queue_id].observation_event.wait_on();
        end
        if (collectors[queue_id].observations.size() != expected_count)
            `uvm_fatal("CMDQ_DRIVER_CALLBACK", {label,
                       " observed an unexpected extra callback"})
    endtask

    task wait_for_irq_waits(int unsigned queue_id,
                            int unsigned expected_count,
                            string label);
        while (adapter.wait_irq_count[queue_id] < expected_count) begin
            adapter.irq_wait_events[queue_id].reset();
            if (adapter.wait_irq_count[queue_id] < expected_count)
                adapter.irq_wait_events[queue_id].wait_on();
        end
        if (adapter.wait_irq_count[queue_id] != expected_count)
            `uvm_fatal("CMDQ_DRIVER_IRQ_WAIT", {label,
                       " observed an unexpected IRQ wait count"})
    endtask

    task submit_one(int unsigned queue_id,
                    input byte payload[], bit [15:0] dst_id,
                    output cmdq_tx_desc desc,
                    output gq_response response);
        gq_request request;

        desc = cmdq_tx_desc::type_id::create(
            $sformatf("queue_%0d_desc", queue_id));
        desc.request = new[payload.size()];
        foreach (payload[i])
            desc.request[i] = payload[i];
        desc.dst_id = dst_id;
        request = gq_request::type_id::create(
            $sformatf("queue_%0d_request", queue_id));
        request.kind = GQ_SUBMIT;
        request.add_desc(desc);
        engines[queue_id].submit_batch(request, response);
        if (response == null || response.status != GQ_OK ||
            response.committed_count != 1)
            `uvm_fatal("CMDQ_DRIVER_SUBMIT", $sformatf(
                "queue %0d did not commit exactly one descriptor",
                queue_id))
    endtask

    function void check_callback(cmdq_driver_observation observation,
                                 input byte request_bytes[],
                                 input byte result_bytes[],
                                 string label);
        if (observation == null ||
            !bytes_equal(observation.request_bytes, request_bytes) ||
            !bytes_equal(observation.result_bytes, result_bytes) ||
            observation.flags !=
                (CMDQ_DESC_AVAIL | CMDQ_DESC_USED) ||
            observation.rx_buf_len != result_bytes.size() ||
            observation.owned_allocation_count != 2)
            `uvm_fatal("CMDQ_DRIVER_CALLBACK", {label,
                       " callback content/order/lifetime diverged"})
    endfunction

    task run_fse_pstat_sequences();
        byte fse_request[] = '{8'h17, 8'h2a, 8'hc4, 8'h09, 8'h7e};
        byte empty_result[] = '{};
        byte pstat_request[] = '{8'h81, 8'h00, 8'h5e};
        byte pstat_result[] = '{8'hd3, 8'h14, 8'h59, 8'h26,
                                8'h53, 8'h58, 8'h97};
        byte expected_fse_desc[] = '{
            8'h01, 8'h00, 8'h05, 8'h00,
            8'h00, 8'h04, 8'h00, 8'he0, 8'h01, 8'h00, 8'h00, 8'h00,
            8'h02, 8'h00, 8'h00, 8'h01,
            8'h00, 8'h05, 8'h00, 8'he0, 8'h01, 8'h00, 8'h00, 8'h00,
            8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
        byte expected_pstat_desc[] = '{
            8'h01, 8'h00, 8'h03, 8'h00,
            8'h00, 8'h04, 8'h00, 8'he0, 8'h01, 8'h00, 8'h00, 8'h00,
            8'h03, 8'h00, 8'h00, 8'h01,
            8'h00, 8'h05, 8'h00, 8'he0, 8'h01, 8'h00, 8'h00, 8'h00,
            8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
        byte raw[];
        byte storage[];
        cmdq_command_sequence command_seq;
        uvm_event sequence_done;
        gq_addr_t tx_addr;
        gq_addr_t rx_addr;
        int unsigned tx_free_before;
        int unsigned rx_free_before;

        initialize_queue(SEQUENCE_Q);
        start_worker(SEQUENCE_Q);
        if (engines[SEQUENCE_Q].ring_base() !=
                64'h0000_0001_e000_0000)
            `uvm_fatal("CMDQ_DRIVER_LITERAL",
                       "first linear ring address broke literal vectors")

        // Mutation caught: publishing before RESET/CONFIGURE/ENABLE, using
        // the wrong 32x32 profile, destination, descriptor bytes, or payload.
        command_seq = cmdq_command_sequence::type_id::create("fse_sequence");
        command_seq.request_payload = fse_request;
        command_seq.dst_id = CMDQ_DST_FSE;
        command_seq.completion_timeout = 2us;
        sequence_done = new("fse_sequence_done");
        fork
            begin
                command_seq.start(sequence_sequencer);
                sequence_done.trigger();
            end
        join_none
        wait_for_publish_count(SEQUENCE_Q, 1, "FSE");
        dut.read_slot(engines[SEQUENCE_Q], 0, raw);
        if (sequence_done.is_on() || !bytes_equal(raw, expected_fse_desc) ||
            adapter.trace.size() != 4 ||
            adapter.trace[0] != "RESET(queue=0)" ||
            adapter.trace[1] !=
                {"CONFIGURE(queue=0,base=0x00000001e0000000,depth=32,",
                 "size=32,hid=0x5a,fid=0x1234,msix=0x0042,valid=1)"} ||
            adapter.trace[2] != "ENABLE(queue=0)" ||
            adapter.trace[3] != "PUBLISH(queue=0,tail=0x0001)")
            `uvm_fatal("CMDQ_DRIVER_FSE_SETUP",
                       "FSE setup/publish/AVAIL bytes diverged")
        dut.decode_buffer_addresses(raw, tx_addr, rx_addr);
        if (tx_addr != 64'h0000_0001_e000_0400 ||
            rx_addr != 64'h0000_0001_e000_0500)
            `uvm_fatal("CMDQ_DRIVER_FSE_ADDR",
                       "FSE descriptor buffer addresses diverged")
        dut.read_buffer(tx_addr, CMDQ_BUFFER_BYTES, storage);
        if (storage.size() != CMDQ_BUFFER_BYTES)
            `uvm_fatal("CMDQ_DRIVER_FSE_TX", "FSE TX buffer was truncated")
        foreach (fse_request[i]) begin
            if (storage[i] !== fse_request[i])
                `uvm_fatal("CMDQ_DRIVER_FSE_TX",
                           "FSE TX payload bytes diverged")
        end
        for (int unsigned i = fse_request.size();
             i < CMDQ_BUFFER_BYTES; i++) begin
            if (storage[i] !== 0)
                `uvm_fatal("CMDQ_DRIVER_FSE_TX",
                           "FSE TX padding was not zero")
        end
        tx_free_before = mem.free_count(tx_addr);
        rx_free_before = mem.free_count(rx_addr);
        if (!dut.complete_slot(engines[SEQUENCE_Q], 0,
                               empty_result, 0, -1))
            `uvm_fatal("CMDQ_DRIVER_DUT", "FSE completion was rejected")
        dut.read_slot(engines[SEQUENCE_Q], 0, raw);
        if (raw[0] != 8'h03 || raw[1] != 8'h00)
            `uvm_fatal("CMDQ_DRIVER_FSE_USED",
                       "FSE hardware completion did not set USED")
        if (!sequence_done.is_on())
            sequence_done.wait_on();
        if (command_seq.result_status != CMDQ_RESULT_OK ||
            command_seq.result.size() != 0 ||
            collectors[SEQUENCE_Q].observations.size() != 1 ||
            mem.free_count(tx_addr) != tx_free_before + 1 ||
            mem.free_count(rx_addr) != rx_free_before + 1)
            `uvm_fatal("CMDQ_DRIVER_FSE_RESULT",
                       "FSE sequence outcome/callback/release diverged")
        check_callback(collectors[SEQUENCE_Q].observations[0],
                       fse_request, empty_result, "FSE");

        // Mutation caught: forcing a fixed 256-byte PSTAT result instead of
        // honoring the hardware-written shorter RX length.
        command_seq = cmdq_command_sequence::type_id::create("pstat_sequence");
        command_seq.request_payload = pstat_request;
        command_seq.dst_id = CMDQ_DST_PSTAT;
        command_seq.completion_timeout = 2us;
        sequence_done = new("pstat_sequence_done");
        fork
            begin
                command_seq.start(sequence_sequencer);
                sequence_done.trigger();
            end
        join_none
        wait_for_publish_count(SEQUENCE_Q, 2, "PSTAT");
        dut.read_slot(engines[SEQUENCE_Q], 1, raw);
        if (sequence_done.is_on() || !bytes_equal(raw, expected_pstat_desc) ||
            adapter.published_tails[SEQUENCE_Q][1] != 16'h0002)
            `uvm_fatal("CMDQ_DRIVER_PSTAT_DESC",
                       "PSTAT destination/descriptor/publication diverged")
        dut.decode_buffer_addresses(raw, tx_addr, rx_addr);
        tx_free_before = mem.free_count(tx_addr);
        rx_free_before = mem.free_count(rx_addr);
        if (!dut.complete_slot(engines[SEQUENCE_Q], 1,
                               pstat_result, 7, -1))
            `uvm_fatal("CMDQ_DRIVER_DUT", "PSTAT completion was rejected")
        dut.read_buffer(rx_addr, CMDQ_BUFFER_BYTES, storage);
        if (storage.size() != CMDQ_BUFFER_BYTES)
            `uvm_fatal("CMDQ_DRIVER_PSTAT_RX",
                       "PSTAT RX buffer was truncated")
        foreach (pstat_result[i]) begin
            if (storage[i] !== pstat_result[i])
                `uvm_fatal("CMDQ_DRIVER_PSTAT_RX",
                           "PSTAT RX payload bytes diverged")
        end
        for (int unsigned i = pstat_result.size();
             i < CMDQ_BUFFER_BYTES; i++) begin
            if (storage[i] !== 0)
                `uvm_fatal("CMDQ_DRIVER_PSTAT_RX",
                           "PSTAT RX tail was not zero")
        end
        if (!sequence_done.is_on())
            sequence_done.wait_on();
        if (command_seq.result_status != CMDQ_RESULT_OK ||
            !bytes_equal(command_seq.result, pstat_result) ||
            command_seq.result.size() != 7 ||
            collectors[SEQUENCE_Q].observations.size() != 2 ||
            mem.free_count(tx_addr) != tx_free_before + 1 ||
            mem.free_count(rx_addr) != rx_free_before + 1)
            `uvm_fatal("CMDQ_DRIVER_PSTAT_RESULT",
                       "PSTAT short result/callback/release diverged")
        check_callback(collectors[SEQUENCE_Q].observations[1],
                       pstat_request, pstat_result, "PSTAT");
    endtask

    task run_wrap_scenario();
        byte literal_payloads[32] = '{
            8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26, 8'h27,
            8'h28, 8'h29, 8'h2a, 8'h2b, 8'h2c, 8'h2d, 8'h2e, 8'h2f,
            8'h30, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36, 8'h37,
            8'h38, 8'h39, 8'h3a, 8'h3b, 8'h3c, 8'h3d, 8'h3e, 8'h3f};
        bit [15:0] literal_tails[32] = '{
            16'h0001, 16'h0002, 16'h0003, 16'h0004,
            16'h0005, 16'h0006, 16'h0007, 16'h0008,
            16'h0009, 16'h000a, 16'h000b, 16'h000c,
            16'h000d, 16'h000e, 16'h000f, 16'h0010,
            16'h0011, 16'h0012, 16'h0013, 16'h0014,
            16'h0015, 16'h0016, 16'h0017, 16'h0018,
            16'h0019, 16'h001a, 16'h001b, 16'h001c,
            16'h001d, 16'h001e, 16'h001f, 16'h8000};
        byte payload[];
        byte empty_result[] = '{};
        byte raw[];
        byte tx_storage[];
        cmdq_tx_desc desc;
        gq_response response;
        gq_addr_t tx_addr;
        gq_addr_t rx_addr;
        int unsigned tx_free_before;
        int unsigned rx_free_before;

        initialize_queue(WRAP_Q);
        start_worker(WRAP_Q);
        // Mutation caught: incrementing only the slot and dropping the phase
        // bit publishes 0x0000 rather than the independently listed 0x8000.
        for (int unsigned i = 0; i < 32; i++) begin
            payload = new[1];
            payload[0] = literal_payloads[i];
            submit_one(WRAP_Q, payload, CMDQ_DST_FSE, desc, response);
            if (adapter.published_tails[WRAP_Q].size() != i + 1 ||
                adapter.published_tails[WRAP_Q][i] != literal_tails[i])
                `uvm_fatal("CMDQ_DRIVER_WRAP_TAIL", $sformatf(
                    "publication %0d was not literal tail 0x%04h",
                    i, literal_tails[i]))
            dut.read_slot(engines[WRAP_Q], i, raw);
            if (raw.size() != CMDQ_DESC_BYTES || raw[0] != 8'h01 ||
                raw[1] != 8'h00 || raw[2] != 8'h01 || raw[3] != 8'h00 ||
                raw[12] != 8'h02 || raw[13] != 8'h00 ||
                raw[14] != 8'h00 || raw[15] != 8'h01)
                `uvm_fatal("CMDQ_DRIVER_WRAP_BYTES",
                           "wrap descriptor bytes diverged before completion")
            dut.decode_buffer_addresses(raw, tx_addr, rx_addr);
            dut.read_buffer(tx_addr, CMDQ_BUFFER_BYTES, tx_storage);
            if (tx_storage[0] !== literal_payloads[i])
                `uvm_fatal("CMDQ_DRIVER_WRAP_PAYLOAD",
                           "wrap TX payload order diverged")
            tx_free_before = mem.free_count(tx_addr);
            rx_free_before = mem.free_count(rx_addr);
            if (!dut.complete_slot(engines[WRAP_Q], i,
                                   empty_result, 0, -1))
                `uvm_fatal("CMDQ_DRIVER_DUT",
                           "wrap completion was rejected")
            wait_for_observations(WRAP_Q, i + 1, "wrap");
            if (collectors[WRAP_Q].observations[i].request_bytes.size() != 1 ||
                collectors[WRAP_Q].observations[i].request_bytes[0] !=
                    literal_payloads[i] ||
                mem.free_count(tx_addr) != tx_free_before + 1 ||
                mem.free_count(rx_addr) != rx_free_before + 1)
                `uvm_fatal("CMDQ_DRIVER_WRAP_ORDER",
                           "wrap callback order or release diverged")
        end
        dut.read_slot(engines[WRAP_Q], 31, raw);
        if (raw[0] != 8'h03 ||
            engines[WRAP_Q].head_seq() != 32 ||
            engines[WRAP_Q].tail_seq() != 32 ||
            engines[WRAP_Q].outstanding_count() != 0)
            `uvm_fatal("CMDQ_DRIVER_WRAP_STATE",
                       "slot-31 completion did not close the wrapped window")
    endtask

    task run_adaptive_poll_scenario();
        byte payload_a[] = '{8'ha1};
        byte payload_b[] = '{8'hb2};
        byte payload_c[] = '{8'hc3};
        byte empty_result[] = '{};
        cmdq_tx_desc desc_a;
        cmdq_tx_desc desc_b;
        cmdq_tx_desc desc_c;
        gq_response response;
        time published_at;
        time wake_submit_at;
        time progress_submit_at;
        int unsigned idle_query_count;

        initialize_queue(ADAPTIVE_Q);
        start_worker(ADAPTIVE_Q);
        // Mutation caught: fixed polling, wrong backoff factor, or failure to
        // saturate produces a vector other than 10/20/40/80/100 ns.
        published_at = $time;
        submit_one(ADAPTIVE_Q, payload_a, CMDQ_DST_FSE, desc_a, response);
        wait_for_queries(ADAPTIVE_Q, 5, "adaptive saturation");
        if (completions[ADAPTIVE_Q].query_times[0] - published_at != 10ns ||
            completions[ADAPTIVE_Q].query_times[1] -
                completions[ADAPTIVE_Q].query_times[0] != 20ns ||
            completions[ADAPTIVE_Q].query_times[2] -
                completions[ADAPTIVE_Q].query_times[1] != 40ns ||
            completions[ADAPTIVE_Q].query_times[3] -
                completions[ADAPTIVE_Q].query_times[2] != 80ns ||
            completions[ADAPTIVE_Q].query_times[4] -
                completions[ADAPTIVE_Q].query_times[3] != 100ns)
            `uvm_fatal("CMDQ_DRIVER_ADAPTIVE",
                       "adaptive query timestamps diverged")

        // Mutation caught: NEW_WORK that does not interrupt a saturated wait,
        // or that queries at zero time instead of restoring the 10 ns floor.
        #25ns;
        wake_submit_at = $time;
        submit_one(ADAPTIVE_Q, payload_b, CMDQ_DST_FSE, desc_b, response);
        wait_for_queries(ADAPTIVE_Q, 6, "adaptive NEW_WORK");
        if (completions[ADAPTIVE_Q].query_times[5] != wake_submit_at + 10ns)
            `uvm_fatal("CMDQ_DRIVER_IDLE_WAKE",
                       "NEW_WORK did not wake then honor the 10 ns floor")

        if (!dut.complete_slot(engines[ADAPTIVE_Q], 0,
                               empty_result, 0, -1) ||
            !dut.complete_slot(engines[ADAPTIVE_Q], 1,
                               empty_result, 0, -1))
            `uvm_fatal("CMDQ_DRIVER_DUT",
                       "adaptive completions were rejected")
        wait_for_queries(ADAPTIVE_Q, 7, "adaptive completion");
        wait_for_observations(ADAPTIVE_Q, 2, "adaptive completion");

        // Mutation caught: progress that leaves the policy saturated delays
        // the next descriptor rather than resetting it to the 10 ns minimum.
        progress_submit_at = $time;
        submit_one(ADAPTIVE_Q, payload_c, CMDQ_DST_FSE, desc_c, response);
        if (!dut.complete_slot(engines[ADAPTIVE_Q], 2,
                               empty_result, 0, -1))
            `uvm_fatal("CMDQ_DRIVER_DUT",
                       "post-progress completion was rejected")
        wait_for_queries(ADAPTIVE_Q, 8, "adaptive reset");
        wait_for_observations(ADAPTIVE_Q, 3, "adaptive reset");
        if (completions[ADAPTIVE_Q].query_times[7] !=
                progress_submit_at + 10ns)
            `uvm_fatal("CMDQ_DRIVER_PROGRESS_RESET",
                       "progress did not restore the 10 ns interval")

        // Mutation caught: an idle TX worker that continues polling performs
        // completion queries despite having zero published outstanding work.
        idle_query_count = completions[ADAPTIVE_Q].query_times.size();
        #1us;
        if (engines[ADAPTIVE_Q].outstanding_count() != 0 ||
            completions[ADAPTIVE_Q].query_times.size() != idle_query_count)
            `uvm_fatal("CMDQ_DRIVER_IDLE_POLL",
                       "zero-outstanding queue queried during 1 us idle")
    endtask

    task run_error_scenarios();
        byte corrupt_payload[] = '{8'hde, 8'had};
        byte oversized_payload[] = '{8'hfa, 8'hce};
        byte empty_result[] = '{};
        cmdq_tx_desc desc;
        gq_response response;
        gq_addr_t tx_addr;
        gq_addr_t rx_addr;
        int unsigned tx_free_before;
        int unsigned rx_free_before;

        initialize_queue(ERROR_Q);
        // Mutation caught: accepting hardware corruption of a stable field
        // retires the wrong descriptor and exposes a fabricated result.
        submit_one(ERROR_Q, corrupt_payload, CMDQ_DST_FSE, desc, response);
        tx_addr = desc.tx_buf_addr;
        rx_addr = desc.rx_buf_addr;
        tx_free_before = mem.free_count(tx_addr);
        rx_free_before = mem.free_count(rx_addr);
        if (!dut.complete_slot(engines[ERROR_Q], 0,
                               empty_result, 0, 2))
            `uvm_fatal("CMDQ_DRIVER_DUT",
                       "stable-field corruption injection failed")
        engines[ERROR_Q].drain_completed();
        if (report_catcher.invalid_query_count != 1 ||
            collectors[ERROR_Q].observations.size() != 0 ||
            desc.result.size() != 0 || engines[ERROR_Q].head_seq() != 0 ||
            engines[ERROR_Q].outstanding_count() != 1 ||
            mem.free_count(tx_addr) != tx_free_before ||
            mem.free_count(rx_addr) != rx_free_before)
            `uvm_fatal("CMDQ_DRIVER_STABLE_ERROR",
                       "stable-field corruption retired or returned data")
        engines[ERROR_Q].begin_reset();
        engines[ERROR_Q].finish_reset();
        if (mem.free_count(tx_addr) != tx_free_before + 1 ||
            mem.free_count(rx_addr) != rx_free_before + 1)
            `uvm_fatal("CMDQ_DRIVER_STABLE_RELEASE",
                       "corrupt descriptor allocations were not released once")
        engines[ERROR_Q].release_reset();

        // Mutation caught: copying an RX length of 257 overruns the fixed
        // 256-byte result buffer and incorrectly retires the descriptor.
        submit_one(ERROR_Q, oversized_payload, CMDQ_DST_PSTAT,
                   desc, response);
        tx_addr = desc.tx_buf_addr;
        rx_addr = desc.rx_buf_addr;
        tx_free_before = mem.free_count(tx_addr);
        rx_free_before = mem.free_count(rx_addr);
        if (!dut.complete_slot(engines[ERROR_Q], 0,
                               empty_result, 257, -1))
            `uvm_fatal("CMDQ_DRIVER_DUT",
                       "oversized RX-length injection failed")
        engines[ERROR_Q].drain_completed();
        if (report_catcher.parse_error_count != 1 ||
            collectors[ERROR_Q].observations.size() != 0 ||
            desc.result.size() != 0 || engines[ERROR_Q].head_seq() != 0 ||
            engines[ERROR_Q].outstanding_count() != 1 ||
            mem.free_count(tx_addr) != tx_free_before ||
            mem.free_count(rx_addr) != rx_free_before)
            `uvm_fatal("CMDQ_DRIVER_RX_LENGTH",
                       "RX length 257 retired or returned data")
        engines[ERROR_Q].begin_reset();
        engines[ERROR_Q].finish_reset();
        if (mem.free_count(tx_addr) != tx_free_before + 1 ||
            mem.free_count(rx_addr) != rx_free_before + 1)
            `uvm_fatal("CMDQ_DRIVER_RX_RELEASE",
                       "oversized descriptor allocations were not released once")
    endtask

    task run_timeout_scenario();
        byte payload_0[] = '{8'h40};
        byte payload_1[] = '{8'h41};
        byte empty_result[] = '{};
        cmdq_tx_desc desc_0;
        cmdq_tx_desc desc_1;
        gq_response response;

        initialize_queue(TIMEOUT_Q);
        submit_one(TIMEOUT_Q, payload_0, CMDQ_DST_FSE, desc_0, response);
        submit_one(TIMEOUT_Q, payload_1, CMDQ_DST_FSE, desc_1, response);
        start_worker(TIMEOUT_Q);
        // Mutation caught: per-query timeout spam or timing the newest entry
        // reports more than once instead of reserving the published oldest.
        while (report_catcher.timeout_count < 1) begin
            report_catcher.timeout_event.reset();
            if (report_catcher.timeout_count < 1)
                report_catcher.timeout_event.wait_on();
        end
        #250ns;
        if (report_catcher.timeout_count != 1 ||
            engines[TIMEOUT_Q].head_seq() != 0 ||
            engines[TIMEOUT_Q].outstanding_count() != 2)
            `uvm_fatal("CMDQ_DRIVER_TIMEOUT_ONCE",
                       "oldest published descriptor did not time out once")
        if (!dut.complete_slot(engines[TIMEOUT_Q], 0,
                               empty_result, 0, -1) ||
            !dut.complete_slot(engines[TIMEOUT_Q], 1,
                               empty_result, 0, -1))
            `uvm_fatal("CMDQ_DRIVER_DUT",
                       "timeout recovery completions were rejected")
        wait_for_observations(TIMEOUT_Q, 2, "timeout recovery");
        if (report_catcher.timeout_count != 1 ||
            engines[TIMEOUT_Q].outstanding_count() != 0)
            `uvm_fatal("CMDQ_DRIVER_TIMEOUT_RECOVERY",
                       "timeout recovery changed one-shot outcome")
    endtask

    task run_irq_scenarios();
        byte real_payload[] = '{8'h61};
        byte watchdog_payload[] = '{8'h62};
        byte empty_result[] = '{};
        cmdq_tx_desc desc;
        gq_response response;
        int unsigned ack_before;
        int unsigned query_before;
        int unsigned trigger_before;

        initialize_queue(IRQ_Q);
        start_worker(IRQ_Q);
        // Mutation caught: a real IRQ that is queried before ACK, ACKed more
        // than once, or not delivered violates callback and interrupt order.
        submit_one(IRQ_Q, real_payload, CMDQ_DST_FSE, desc, response);
        wait_for_irq_waits(IRQ_Q, 1, "real IRQ");
        if (!dut.complete_slot(engines[IRQ_Q], 0,
                               empty_result, 0, -1))
            `uvm_fatal("CMDQ_DRIVER_DUT", "real IRQ completion failed")
        ack_before = adapter.ack_irq_count.exists(IRQ_Q) ?
                     adapter.ack_irq_count[IRQ_Q] : 0;
        query_before = completions[IRQ_Q].query_times.size();
        dut.trigger_irq(IRQ_Q);
        wait_for_observations(IRQ_Q, 1, "real IRQ");
        if (adapter.ack_irq_count[IRQ_Q] != ack_before + 1 ||
            completions[IRQ_Q].query_times.size() != query_before + 1 ||
            completions[IRQ_Q].ack_counts_at_query[query_before] !=
                ack_before + 1)
            `uvm_fatal("CMDQ_DRIVER_REAL_IRQ",
                       "real IRQ ACK/query counts diverged")

        // Mutation caught: treating a spurious IRQ as progress either skips
        // its one ACK or produces a completion callback for an AVAIL entry.
        submit_one(IRQ_Q, watchdog_payload, CMDQ_DST_PSTAT, desc, response);
        wait_for_irq_waits(IRQ_Q, 2, "spurious IRQ");
        ack_before = adapter.ack_irq_count[IRQ_Q];
        query_before = completions[IRQ_Q].query_times.size();
        dut.trigger_irq(IRQ_Q);
        wait_for_queries(IRQ_Q, query_before + 1, "spurious IRQ");
        if (adapter.ack_irq_count[IRQ_Q] != ack_before + 1 ||
            completions[IRQ_Q].ack_counts_at_query[query_before] !=
                ack_before + 1 ||
            collectors[IRQ_Q].observations.size() != 1 ||
            engines[IRQ_Q].head_seq() != 1 ||
            engines[IRQ_Q].outstanding_count() != 1)
            `uvm_fatal("CMDQ_DRIVER_SPURIOUS_IRQ",
                       "spurious IRQ ACKed/delivered incorrectly")

        // Mutation caught: requiring an IRQ edge forever loses a completion;
        // watchdog recovery queries without acknowledging a nonexistent IRQ.
        wait_for_irq_waits(IRQ_Q, 3, "lost IRQ watchdog");
        if (!dut.complete_slot(engines[IRQ_Q], 1,
                               empty_result, 0, -1))
            `uvm_fatal("CMDQ_DRIVER_DUT",
                       "lost-IRQ completion failed")
        ack_before = adapter.ack_irq_count[IRQ_Q];
        query_before = completions[IRQ_Q].query_times.size();
        trigger_before = adapter.trigger_irq_count[IRQ_Q];
        wait_for_observations(IRQ_Q, 2, "lost IRQ watchdog");
        if (adapter.ack_irq_count[IRQ_Q] != ack_before ||
            completions[IRQ_Q].ack_counts_at_query[query_before] !=
                ack_before ||
            adapter.trigger_irq_count[IRQ_Q] != trigger_before ||
            engines[IRQ_Q].outstanding_count() != 0)
            `uvm_fatal("CMDQ_DRIVER_LOST_IRQ",
                       "watchdog recovery ACKed or failed to retire")
    endtask

    task run_reset_read_scenario();
        byte payload[] = '{8'h71, 8'h72};
        byte empty_result[] = '{};
        cmdq_tx_desc desc;
        gq_response response;
        gq_addr_t ring_addr;
        gq_addr_t tx_addr;
        gq_addr_t rx_addr;
        int unsigned ring_free_before;
        int unsigned tx_free_before;
        int unsigned rx_free_before;
        longint unsigned epoch_before;

        initialize_queue(RESET_READ_Q);
        submit_one(RESET_READ_Q, payload, CMDQ_DST_FSE, desc, response);
        ring_addr = engines[RESET_READ_Q].ring_base();
        tx_addr = desc.tx_buf_addr;
        rx_addr = desc.rx_buf_addr;
        ring_free_before = mem.free_count(ring_addr);
        tx_free_before = mem.free_count(tx_addr);
        rx_free_before = mem.free_count(rx_addr);
        if (!dut.complete_slot(engines[RESET_READ_Q], 0,
                               empty_result, 0, -1))
            `uvm_fatal("CMDQ_DRIVER_DUT",
                       "reset-read completion failed")
        completions[RESET_READ_Q].block_next_query();
        start_worker(RESET_READ_Q);
        completions[RESET_READ_Q].query_blocked.wait_on();

        // Mutation caught: committing a writeback read captured before reset
        // delivers stale work or leaks/double-frees descriptor/ring ownership.
        epoch_before = engines[RESET_READ_Q].reset_epoch();
        engines[RESET_READ_Q].begin_reset();
        if (engines[RESET_READ_Q].reset_epoch() != epoch_before + 1)
            `uvm_fatal("CMDQ_DRIVER_RESET_READ_EPOCH",
                       "reset did not advance while writeback read blocked")
        completions[RESET_READ_Q].release_query();
        wait_for_queries(RESET_READ_Q, 1, "reset blocked read");
        engines[RESET_READ_Q].finish_reset();
        if (collectors[RESET_READ_Q].observations.size() != 0 ||
            engines[RESET_READ_Q].outstanding_count() != 0 ||
            engines[RESET_READ_Q].ring_base() != 0 ||
            mem.free_count(ring_addr) != ring_free_before + 1 ||
            mem.free_count(tx_addr) != tx_free_before + 1 ||
            mem.free_count(rx_addr) != rx_free_before + 1)
            `uvm_fatal("CMDQ_DRIVER_RESET_READ",
                       "stale read retired work or released ownership wrongly")
        engines[RESET_READ_Q].cleanup();
        if (mem.free_count(ring_addr) != ring_free_before + 1 ||
            mem.free_count(tx_addr) != tx_free_before + 1 ||
            mem.free_count(rx_addr) != rx_free_before + 1)
            `uvm_fatal("CMDQ_DRIVER_RESET_READ_ONCE",
                       "cleanup released reset-read ownership twice")
    endtask

    task run_reset_ack_scenario();
        byte payload[] = '{8'h81, 8'h82};
        byte empty_result[] = '{};
        cmdq_tx_desc desc;
        gq_response response;
        gq_addr_t ring_addr;
        gq_addr_t tx_addr;
        gq_addr_t rx_addr;
        int unsigned ring_free_before;
        int unsigned tx_free_before;
        int unsigned rx_free_before;
        int unsigned query_before;
        longint unsigned epoch_before;

        initialize_queue(RESET_ACK_Q);
        start_worker(RESET_ACK_Q);
        submit_one(RESET_ACK_Q, payload, CMDQ_DST_FSE, desc, response);
        ring_addr = engines[RESET_ACK_Q].ring_base();
        tx_addr = desc.tx_buf_addr;
        rx_addr = desc.rx_buf_addr;
        ring_free_before = mem.free_count(ring_addr);
        tx_free_before = mem.free_count(tx_addr);
        rx_free_before = mem.free_count(rx_addr);
        if (!dut.complete_slot(engines[RESET_ACK_Q], 0,
                               empty_result, 0, -1))
            `uvm_fatal("CMDQ_DRIVER_DUT", "reset-ACK completion failed")
        wait_for_irq_waits(RESET_ACK_Q, 1, "reset ACK");
        adapter.block_next_irq_ack(RESET_ACK_Q);
        query_before = completions[RESET_ACK_Q].query_times.size();
        dut.trigger_irq(RESET_ACK_Q);
        adapter.irq_ack_blocked[RESET_ACK_Q].wait_on();

        // Mutation caught: reset racing a blocked ACK may query and retire the
        // stale USED entry, fail to quiesce ACK, or release ownership twice.
        epoch_before = engines[RESET_ACK_Q].reset_epoch();
        engines[RESET_ACK_Q].begin_reset();
        if (engines[RESET_ACK_Q].reset_epoch() != epoch_before + 1)
            `uvm_fatal("CMDQ_DRIVER_RESET_ACK_EPOCH",
                       "reset did not advance while IRQ ACK blocked")
        adapter.release_irq_ack(RESET_ACK_Q);
        engines[RESET_ACK_Q].finish_reset();
        if (adapter.ack_irq_count[RESET_ACK_Q] != 1 ||
            completions[RESET_ACK_Q].query_times.size() != query_before ||
            collectors[RESET_ACK_Q].observations.size() != 0 ||
            engines[RESET_ACK_Q].outstanding_count() != 0 ||
            engines[RESET_ACK_Q].ring_base() != 0 ||
            mem.free_count(ring_addr) != ring_free_before + 1 ||
            mem.free_count(tx_addr) != tx_free_before + 1 ||
            mem.free_count(rx_addr) != rx_free_before + 1)
            `uvm_fatal("CMDQ_DRIVER_RESET_ACK",
                       "blocked ACK retired stale work or leaked ownership")
        engines[RESET_ACK_Q].cleanup();
        if (mem.free_count(ring_addr) != ring_free_before + 1 ||
            mem.free_count(tx_addr) != tx_free_before + 1 ||
            mem.free_count(rx_addr) != rx_free_before + 1)
            `uvm_fatal("CMDQ_DRIVER_RESET_ACK_ONCE",
                       "cleanup released reset-ACK ownership twice")
    endtask

    task cleanup_all();
        for (int unsigned queue_id = 0; queue_id < QUEUE_COUNT;
             queue_id++)
            engines[queue_id].cleanup();
        for (int unsigned queue_id = 0; queue_id < QUEUE_COUNT;
             queue_id++) begin
            if (!worker_started[queue_id])
                continue;
            for (int unsigned observation = 0; observation < 1000;
                 observation++) begin
                #1ns;
                if (worker_returned[queue_id])
                    break;
            end
            if (!worker_returned[queue_id])
                `uvm_fatal("CMDQ_DRIVER_WORKER", $sformatf(
                    "queue %0d worker did not terminate", queue_id))
        end
        mem.leak_check(`__FILE__, `__LINE__);
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        uvm_report_cb::add(null, report_catcher);
        fork : conformance_watchdog
            begin
                #100us;
                `uvm_fatal("CMDQ_DRIVER_TEST_TIMEOUT",
                           "CMDQ driver conformance exceeded 100 us")
            end
        join_none

        run_fse_pstat_sequences();
        run_wrap_scenario();
        run_adaptive_poll_scenario();
        run_error_scenarios();
        run_timeout_scenario();
        run_irq_scenarios();
        run_reset_read_scenario();
        run_reset_ack_scenario();
        cleanup_all();

        if (report_catcher.invalid_query_count != 1 ||
            report_catcher.parse_error_count != 1 ||
            report_catcher.timeout_count != 1)
            `uvm_fatal("CMDQ_DRIVER_REPORTS",
                       "expected error-path report counts diverged")
        uvm_report_cb::delete(null, report_catcher);
        disable conformance_watchdog;
        phase.drop_objection(this);
    endtask
endclass

`endif
