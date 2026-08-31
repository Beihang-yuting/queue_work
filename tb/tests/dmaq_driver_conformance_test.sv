`ifndef DMAQ_DRIVER_CONFORMANCE_TEST_SV
`define DMAQ_DRIVER_CONFORMANCE_TEST_SV

class dmaq_test_engine extends gq_queue_engine;
    `uvm_component_utils(dmaq_test_engine)
    function new(string name = "dmaq_test_engine", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    task invoke_deadline_check();
        check_completion_deadline();
    endtask
endclass

class dmaq_driver_observation extends uvm_object;
    `uvm_object_utils(dmaq_driver_observation)

    dmaq_operation_e operation;
    dmaq_endpoint_t source;
    dmaq_endpoint_t destination;
    int unsigned transfer_length;
    bit [15:0] flags;
    int unsigned owned_allocation_count;
    time callback_time;

    function new(string name = "dmaq_driver_observation");
        super.new(name);
        operation = DMAQ_AF_TO_HOST;
        source = '0;
        destination = '0;
        transfer_length = 0;
        flags = 0;
        owned_allocation_count = 0;
        callback_time = 0;
    endfunction
endclass

class dmaq_driver_collector extends uvm_component;
    `uvm_component_utils(dmaq_driver_collector)

    uvm_analysis_imp #(gq_desc_base, dmaq_driver_collector) analysis_export;
    dmaq_driver_observation observations[$];
    uvm_event observation_event;

    function new(string name = "dmaq_driver_collector",
                 uvm_component parent = null);
        super.new(name, parent);
        analysis_export = new("analysis_export", this);
        observation_event = new({name, "_observation"});
    endfunction

    function void write(gq_desc_base base_desc);
        dmaq_tx_desc desc;
        dmaq_driver_observation observation;

        if (!$cast(desc, base_desc))
            `uvm_fatal("DMAQ_DRIVER_CALLBACK",
                       "completion callback was not a DMAQ descriptor")
        observation = dmaq_driver_observation::type_id::create(
            $sformatf("observation_%0d", observations.size()));
        observation.operation = desc.operation;
        observation.source = desc.source;
        observation.destination = desc.destination;
        observation.transfer_length = desc.transfer_length;
        observation.flags = desc.flags;
        observation.owned_allocation_count = desc.owned_allocation_count();
        observation.callback_time = $time;
        observations.push_back(observation);
        observation_event.trigger();
    endfunction
endclass

class dmaq_driver_report_catcher extends uvm_report_catcher;
    `uvm_object_utils(dmaq_driver_report_catcher)

    bit expect_invalid_query;
    bit expect_timeout;
    int unsigned invalid_query_count;
    int unsigned timeout_count;
    string timeout_messages[$];
    uvm_event timeout_event;

    function new(string name = "dmaq_driver_report_catcher");
        super.new(name);
        expect_invalid_query = 0;
        expect_timeout = 0;
        invalid_query_count = 0;
        timeout_count = 0;
        timeout_event = new({name, "_timeout"});
    endfunction

    virtual function action_e catch();
        if (get_id() == "GQ_COMPLETION_QUERY" &&
            get_severity() == UVM_WARNING && expect_invalid_query) begin
            invalid_query_count++;
            expect_invalid_query = 0;
            return CAUGHT;
        end
        if (get_id() == "GQ_COMPLETION_TIMEOUT" &&
            get_severity() == UVM_ERROR) begin
            timeout_count++;
            timeout_messages.push_back(get_message());
            timeout_event.trigger();
            if (expect_timeout) begin
                if (uvm_re_match(".*head=31.*slot=31.*",
                                 get_message()) != 0)
                    `uvm_fatal("DMAQ_TIMEOUT_DIAGNOSTIC",
                               "timeout diagnostic lost configured logical identity")
                return CAUGHT;
            end
        end
        return THROW;
    endfunction
endclass

class dmaq_driver_conformance_test extends uvm_test;
    `uvm_component_utils(dmaq_driver_conformance_test)

    localparam int unsigned MAIN_Q            = 0;
    localparam int unsigned CUSTOM_Q          = 1;
    localparam int unsigned ZERO_Q            = 2;
    localparam int unsigned TIME_BEFORE_Q     = 3;
    localparam int unsigned TIME_AT_Q         = 4;
    localparam int unsigned TIME_AFTER_Q      = 5;
    localparam int unsigned IRQ_Q             = 6;
    localparam int unsigned RESET_IRQ_Q       = 7;
    localparam int unsigned RESET_QUERY_Q     = 8;
    localparam int unsigned RESET_ACK_Q       = 9;
    localparam int unsigned CLEANUP_PUBLISH_Q = 10;
    localparam int unsigned ERROR_Q           = 11;
    localparam int unsigned QUEUE_COUNT       = 12;

    dmaq_driver_mem mem;
    dmaq_mock_adapter adapters[int unsigned];
    dmaq_mock_dut dut;
    gq_queue_cfg cfgs[int unsigned];
    dmaq_mock_completion completions[int unsigned];
    gq_queue_engine engines[int unsigned];
    gq_sequencer sequencers[int unsigned];
    gq_driver drivers[int unsigned];
    gq_completion_worker workers[int unsigned];
    dmaq_driver_collector collectors[int unsigned];
    dmaq_driver_report_catcher report_catcher;
    dmaq_hw_cfg_t hw_cfg;

    function new(string name = "dmaq_driver_conformance_test",
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

    function void copy_bytes(input byte source[], ref byte destination[]);
        destination = new[source.size()];
        foreach (source[i])
            destination[i] = source[i];
    endfunction

    function dmaq_endpoint_t endpoint(dmaq_endpoint_role_e role,
                                      gq_addr_t address,
                                      bit [15:0] host_id,
                                      bit [15:0] bdf_raw);
        dmaq_endpoint_t value;

        value.role = role;
        value.address = address;
        value.host_id = host_id;
        value.bdf_raw = bdf_raw;
        return value;
    endfunction

    function void select_literal_transfer(
        int unsigned index,
        output dmaq_operation_e operation,
        output dmaq_endpoint_t source,
        output dmaq_endpoint_t destination,
        output int unsigned transfer_length,
        ref byte expected[]);
        dmaq_operation_e operations[3] = '{
            DMAQ_AF_TO_HOST, DMAQ_HOST_TO_AF, DMAQ_HOST_TO_HOST};
        dmaq_endpoint_role_e source_roles[3] = '{
            DMAQ_ENDPOINT_AF, DMAQ_ENDPOINT_HOST, DMAQ_ENDPOINT_HOST};
        dmaq_endpoint_role_e destination_roles[3] = '{
            DMAQ_ENDPOINT_HOST, DMAQ_ENDPOINT_AF, DMAQ_ENDPOINT_HOST};
        byte expected_af_to_host[] = '{
            8'h01,8'h00, 8'hee,8'hdd, 8'hcc,8'hbb, 8'h34,8'h12,
            8'h11,8'h22,8'h33,8'h44,8'h55,8'h66,8'h77,8'h88,
            8'h88,8'h77,8'h66,8'h55,8'h44,8'h33,8'h22,8'h11,
            8'hca,8'h1b, 8'haa,8'h99, 8'h34,8'h12, 8'h00,8'h00};
        byte expected_host_to_af[] = '{
            8'h01,8'h00, 8'h55,8'h66, 8'h77,8'h88, 8'h01,8'h00,
            8'h80,8'h70,8'h60,8'h50,8'h40,8'h30,8'h20,8'h10,
            8'h08,8'h07,8'h06,8'h05,8'h04,8'h03,8'h02,8'h01,
            8'h11,8'h22, 8'h33,8'h44, 8'h01,8'h00, 8'h00,8'h00};
        byte expected_host_to_host[] = '{
            8'h01,8'h00, 8'h68,8'h24, 8'hef,8'hbe, 8'hff,8'hff,
            8'h78,8'h69,8'h5a,8'h4b,8'h3c,8'h2d,8'h1e,8'h0f,
            8'h80,8'h90,8'ha0,8'hb0,8'hc0,8'hd0,8'he0,8'hf0,
            8'hcd,8'hab, 8'h57,8'h13, 8'hff,8'hff, 8'h00,8'h00};

        if (index >= 3)
            `uvm_fatal("DMAQ_DRIVER_LITERAL", "literal transfer index overflow")
        operation = operations[index];
        case (index)
            0: begin
                source = endpoint(source_roles[index],
                    64'h1122_3344_5566_7788, 16'h99aa, 16'h1bca);
                destination = endpoint(destination_roles[index],
                    64'h8877_6655_4433_2211, 16'hbbcc, 16'hddee);
                transfer_length = 16'h1234;
                copy_bytes(expected_af_to_host, expected);
            end
            1: begin
                source = endpoint(source_roles[index],
                    64'h0102_0304_0506_0708, 16'h4433, 16'h2211);
                destination = endpoint(destination_roles[index],
                    64'h1020_3040_5060_7080, 16'h8877, 16'h6655);
                transfer_length = 1;
                copy_bytes(expected_host_to_af, expected);
            end
            default: begin
                source = endpoint(source_roles[index],
                    64'hf0e0_d0c0_b0a0_9080, 16'h1357, 16'habcd);
                destination = endpoint(destination_roles[index],
                    64'h0f1e_2d3c_4b5a_6978, 16'hbeef, 16'h2468);
                transfer_length = 16'hffff;
                copy_bytes(expected_host_to_host, expected);
            end
        endcase
    endfunction

    function gq_queue_cfg make_default_cfg(int unsigned queue_id);
        dmaq_env_cfg profile;
        gq_queue_cfg cfg;
        string reason;
        string key;

        profile = dmaq_env_cfg::type_id::create(
            $sformatf("default_profile_%0d", queue_id));
        profile.mem = mem;
        profile.adapter = adapters[queue_id];
        if (!profile.add_dmaq(queue_id, hw_cfg, reason))
            `uvm_fatal("DMAQ_DRIVER_PROFILE", $sformatf(
                "default queue %0d was rejected: %s", queue_id, reason))
        key = gq_queue_key(GQ_TX, queue_id);
        cfg = profile.queues[key];
        if (!$cast(completions[queue_id], cfg.completion_source))
            `uvm_fatal("DMAQ_DRIVER_PROFILE",
                       "DMAQ completion factory override was not installed")
        completions[queue_id].queue_id = queue_id;
        return cfg;
    endfunction

    function gq_queue_cfg make_custom_cfg(int unsigned queue_id);
        gq_queue_cfg custom_cfg;
        string reason;

        if (!adapters[queue_id].reserve_queue_binding(queue_id, hw_cfg,
                                                       reason))
            `uvm_fatal("DMAQ_DRIVER_BIND", reason)

        custom_cfg = gq_queue_cfg::type_id::create(
            $sformatf("custom_cfg_%0d", queue_id));
        custom_cfg.queue_id = queue_id;
        custom_cfg.role = GQ_TX;
        custom_cfg.depth = 64;
        custom_cfg.initial_logical_seq = 5;
        custom_cfg.poll_min_interval = 25ns;
        custom_cfg.poll_max_interval = 25ns;
        custom_cfg.poll_backoff_factor = 1;
        custom_cfg.completion_timeout = 750ns;
        custom_cfg.desc_size = DMAQ_DESC_BYTES;
        custom_cfg.alignment = 64;
        custom_cfg.status_area_size = 0;
        custom_cfg.wait_mode = GQ_POLL;
        custom_cfg.poll_policy = GQ_POLL_FIXED;
        custom_cfg.irq_watchdog_interval = 0;
        custom_cfg.ptr_codec = dmaq_ptr_codec::type_id::create(
            $sformatf("custom_codec_%0d", queue_id));
        completions[queue_id] = dmaq_mock_completion::type_id::create(
            $sformatf("custom_completion_%0d", queue_id));
        completions[queue_id].queue_id = queue_id;
        custom_cfg.completion_source = completions[queue_id];
        return custom_cfg;
    endfunction

    function gq_queue_cfg make_zero_cfg(int unsigned queue_id);
        gq_queue_cfg zero_cfg;

        zero_cfg = make_custom_cfg(queue_id);
        zero_cfg.depth = 32;
        zero_cfg.initial_logical_seq = 0;
        zero_cfg.poll_min_interval = DMAQ_DEFAULT_POLL_INTERVAL;
        zero_cfg.poll_max_interval = DMAQ_DEFAULT_POLL_INTERVAL;
        zero_cfg.completion_timeout = DMAQ_DEFAULT_COMPLETION_TIMEOUT;
        return zero_cfg;
    endfunction

    function gq_queue_cfg make_irq_cfg(int unsigned queue_id);
        gq_queue_cfg irq_cfg;
        dmaq_mock_completion irq_completion;
        string reason;

        if (!adapters[queue_id].reserve_queue_binding(queue_id, hw_cfg,
                                                       reason))
            `uvm_fatal("DMAQ_DRIVER_BIND", reason)

        irq_cfg = gq_queue_cfg::type_id::create(
            $sformatf("irq_cfg_%0d", queue_id));
        irq_cfg.queue_id = queue_id;
        irq_cfg.role = GQ_TX;
        irq_cfg.depth = DMAQ_DEFAULT_DEPTH;
        irq_cfg.initial_logical_seq = DMAQ_DEFAULT_INITIAL_LOGICAL_SEQ;
        irq_cfg.alignment = 64;
        irq_cfg.status_area_size = 0;
        irq_cfg.poll_policy = GQ_POLL_FIXED;
        irq_cfg.wait_mode = GQ_IRQ;
        irq_cfg.irq_watchdog_interval = 100ns;
        irq_cfg.poll_min_interval = 10ns;
        irq_cfg.poll_max_interval = 10ns;
        irq_cfg.poll_backoff_factor = 1;
        irq_cfg.completion_timeout = 500ns;
        irq_cfg.desc_size = DMAQ_DESC_BYTES;
        irq_cfg.ptr_codec = dmaq_ptr_codec::type_id::create(
            $sformatf("irq_ptr_codec_%0d", queue_id));
        irq_completion = dmaq_mock_completion::type_id::create(
            $sformatf("irq_completion_%0d", queue_id));
        irq_completion.queue_id = queue_id;
        completions[queue_id] = irq_completion;
        irq_cfg.completion_source = irq_completion;
        return irq_cfg;
    endfunction

    function void build_phase(uvm_phase phase);
        string reason;
        string engine_name;
        string sequencer_name;
        string driver_name;
        string worker_name;
        string collector_name;

        super.build_phase(phase);
        gq_queue_engine::type_id::set_type_override(dmaq_test_engine::get_type());
        dmaq_completion::type_id::set_type_override(
            dmaq_mock_completion::get_type());
        mem = new("mem");
        mem.init_region(64'h0000_0001_d000_0000,
                        64'h0000_0001_d0ff_ffff, MODE_LINEAR, 16);
        hw_cfg.queue_hid = 32'h5aa5_5aa5;
        hw_cfg.queue_bdf = 16'h2345;
        hw_cfg.msix_index = 16'h0042;
        hw_cfg.msix_valid = 1'b1;
        dut = dmaq_mock_dut::type_id::create("dut");
        dut.mem = mem;

        for (int unsigned queue_id = 0; queue_id < QUEUE_COUNT;
             queue_id++) begin
            adapters[queue_id] = dmaq_mock_adapter::type_id::create(
                $sformatf("adapter_%0d", queue_id));
            adapters[queue_id].mem = mem;
            dut.adapters[queue_id] = adapters[queue_id];
            if (queue_id == CUSTOM_Q)
                cfgs[queue_id] = make_custom_cfg(queue_id);
            else if (queue_id == ZERO_Q)
                cfgs[queue_id] = make_zero_cfg(queue_id);
            else if (queue_id == IRQ_Q || queue_id == RESET_IRQ_Q ||
                     queue_id == RESET_ACK_Q)
                cfgs[queue_id] = make_irq_cfg(queue_id);
            else
                cfgs[queue_id] = make_default_cfg(queue_id);
            if (!cfgs[queue_id].validate(reason))
                `uvm_fatal("DMAQ_DRIVER_CFG", $sformatf(
                    "queue %0d configuration rejected: %s",
                    queue_id, reason))

            engine_name = $sformatf("engine_%0d", queue_id);
            sequencer_name = $sformatf("sequencer_%0d", queue_id);
            driver_name = $sformatf("driver_%0d", queue_id);
            worker_name = $sformatf("worker_%0d", queue_id);
            collector_name = $sformatf("collector_%0d", queue_id);
            uvm_config_db#(gq_queue_cfg)::set(
                this, engine_name, "cfg", cfgs[queue_id]);
            uvm_config_db#(host_mem_api)::set(
                this, engine_name, "mem", mem);
            uvm_config_db#(gq_hw_adapter)::set(
                this, engine_name, "adapter", adapters[queue_id]);
            engines[queue_id] = gq_queue_engine::type_id::create(
                engine_name, this);
            sequencers[queue_id] = gq_sequencer::type_id::create(
                sequencer_name, this);
            drivers[queue_id] = gq_driver::type_id::create(
                driver_name, this);
            workers[queue_id] = gq_completion_worker::type_id::create(
                worker_name, this);
            collectors[queue_id] = dmaq_driver_collector::type_id::create(
                collector_name, this);
        end
        report_catcher = dmaq_driver_report_catcher::type_id::create(
            "report_catcher");
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        for (int unsigned queue_id = 0; queue_id < QUEUE_COUNT;
             queue_id++) begin
            engines[queue_id].completion_ap.connect(
                collectors[queue_id].analysis_export);
            drivers[queue_id].engine = engines[queue_id];
            drivers[queue_id].seq_item_port.connect(
                sequencers[queue_id].seq_item_export);
            workers[queue_id].engine = engines[queue_id];
        end
    endfunction

    task initialize_queue(int unsigned queue_id);
        int unsigned reset_before;
        int unsigned configure_before;
        int unsigned enable_before;

        reset_before = adapters[queue_id].reset_count.exists(queue_id) ?
                       adapters[queue_id].reset_count[queue_id] : 0;
        configure_before =
            adapters[queue_id].configure_count.exists(queue_id) ?
            adapters[queue_id].configure_count[queue_id] : 0;
        enable_before = adapters[queue_id].enable_count.exists(queue_id) ?
                        adapters[queue_id].enable_count[queue_id] : 0;
        engines[queue_id].initialize();
        if (!engines[queue_id].is_ready() ||
            adapters[queue_id].reset_count[queue_id] != reset_before + 1 ||
            adapters[queue_id].configure_count[queue_id] !=
                configure_before + 1 ||
            adapters[queue_id].enable_count[queue_id] != enable_before + 1 ||
            adapters[queue_id].configured_depth[queue_id] !=
                cfgs[queue_id].depth ||
            adapters[queue_id].configured_desc_size[queue_id] !=
                DMAQ_DESC_BYTES ||
            adapters[queue_id].configured_hw_cfg[queue_id] != hw_cfg)
            `uvm_fatal("DMAQ_DRIVER_SETUP", $sformatf(
                "queue %0d did not reset/configure/enable its public profile",
                queue_id))
    endtask

    task wait_for_publish_count(int unsigned queue_id,
                                int unsigned expected_count,
                                string label);
        while (adapters[queue_id].published_tails[queue_id].size() <
               expected_count) begin
            adapters[queue_id].publish_events[queue_id].reset();
            if (adapters[queue_id].published_tails[queue_id].size() <
                expected_count)
                adapters[queue_id].publish_events[queue_id].wait_on();
        end
        if (adapters[queue_id].published_tails[queue_id].size() !=
            expected_count)
            `uvm_fatal("DMAQ_DRIVER_PUBLISH", {label,
                       " observed an unexpected extra tail write"})
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
            `uvm_fatal("DMAQ_DRIVER_QUERY", {label,
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
            `uvm_fatal("DMAQ_DRIVER_CALLBACK", {label,
                       " observed an unexpected extra callback"})
    endtask

    task wait_for_irq_waits(int unsigned queue_id,
                            int unsigned expected_count,
                            string label);
        while (adapters[queue_id].wait_irq_count[queue_id] <
               expected_count) begin
            adapters[queue_id].irq_wait_events[queue_id].reset();
            if (adapters[queue_id].wait_irq_count[queue_id] < expected_count)
                adapters[queue_id].irq_wait_events[queue_id].wait_on();
        end
        if (adapters[queue_id].wait_irq_count[queue_id] != expected_count)
            `uvm_fatal("DMAQ_DRIVER_IRQ_WAIT", {label,
                       " observed an unexpected IRQ wait count"})
    endtask

    task wait_for_disable_count(int unsigned queue_id,
                                int unsigned expected_count,
                                string label);
        while (adapters[queue_id].disable_count[queue_id] < expected_count) begin
            adapters[queue_id].disable_events[queue_id].reset();
            if (adapters[queue_id].disable_count[queue_id] < expected_count)
                adapters[queue_id].disable_events[queue_id].wait_on();
        end
        if (adapters[queue_id].disable_count[queue_id] != expected_count)
            `uvm_fatal("DMAQ_DRIVER_DISABLE", {label,
                       " observed an unexpected disable count"})
    endtask

    function dmaq_transfer_sequence make_sequence(
        string name, dmaq_operation_e operation,
        dmaq_endpoint_t source, dmaq_endpoint_t destination,
        int unsigned transfer_length, time completion_timeout);
        dmaq_transfer_sequence transfer_seq;

        transfer_seq = dmaq_transfer_sequence::type_id::create(name);
        transfer_seq.operation = operation;
        transfer_seq.source = source;
        transfer_seq.destination = destination;
        transfer_seq.transfer_length = transfer_length;
        transfer_seq.completion_timeout = completion_timeout;
        mem.register_borrowed(source.address);
        mem.register_borrowed(destination.address);
        return transfer_seq;
    endfunction

    task submit_one(int unsigned queue_id,
                    dmaq_operation_e operation,
                    dmaq_endpoint_t source,
                    dmaq_endpoint_t destination,
                    int unsigned transfer_length,
                    output dmaq_tx_desc desc,
                    output gq_response response,
                    input bit require_success = 1);
        gq_request request;

        desc = dmaq_tx_desc::type_id::create(
            $sformatf("queue_%0d_desc", queue_id));
        desc.operation = operation;
        desc.source = source;
        desc.destination = destination;
        desc.transfer_length = transfer_length;
        mem.register_borrowed(source.address);
        mem.register_borrowed(destination.address);
        request = gq_request::type_id::create(
            $sformatf("queue_%0d_request", queue_id));
        request.kind = GQ_SUBMIT;
        request.add_desc(desc);
        engines[queue_id].submit_batch(request, response);
        if (require_success &&
            (response == null || response.status != GQ_OK ||
             response.committed_count != 1))
            `uvm_fatal("DMAQ_DRIVER_SUBMIT", $sformatf(
                "queue %0d did not commit exactly one descriptor",
                queue_id))
    endtask

    function void check_observation(dmaq_driver_observation observation,
                                    dmaq_operation_e operation,
                                    dmaq_endpoint_t source,
                                    dmaq_endpoint_t destination,
                                    int unsigned transfer_length,
                                    string label);
        if (observation == null ||
            observation.operation != operation ||
            observation.source !== source ||
            observation.destination !== destination ||
            observation.transfer_length != transfer_length ||
            observation.flags != (DMAQ_DESC_AVAIL | DMAQ_DESC_USED) ||
            observation.owned_allocation_count != 0)
            `uvm_fatal("DMAQ_DRIVER_CALLBACK", {label,
                       " callback content or borrowed ownership diverged"})
    endfunction

    task run_literal_sequences_and_wrap();
        bit [15:0] literal_tails[33] = '{
            16'h8000, 16'h8001, 16'h8002, 16'h8003,
            16'h8004, 16'h8005, 16'h8006, 16'h8007,
            16'h8008, 16'h8009, 16'h800a, 16'h800b,
            16'h800c, 16'h800d, 16'h800e, 16'h800f,
            16'h8010, 16'h8011, 16'h8012, 16'h8013,
            16'h8014, 16'h8015, 16'h8016, 16'h8017,
            16'h8018, 16'h8019, 16'h801a, 16'h801b,
            16'h801c, 16'h801d, 16'h801e, 16'h801f,
            16'h0000};
        dmaq_operation_e operation;
        dmaq_endpoint_t source;
        dmaq_endpoint_t destination;
        int unsigned transfer_length;
        byte expected[];
        byte raw[];
        dmaq_transfer_sequence transfer_seq;
        uvm_event sequence_done;
        int unsigned allocation_before;
        int unsigned free_before;
        int unsigned query_before;
        dmaq_tx_desc desc;
        gq_response response;

        adapters[MAIN_Q].clear_trace();
        initialize_queue(MAIN_Q);
        if (engines[MAIN_Q].head_seq() != 31 ||
            engines[MAIN_Q].tail_seq() != 31 ||
            engines[MAIN_Q].outstanding_count() != 0 ||
            engines[MAIN_Q].ring_base() != 64'h0000_0001_d000_0000)
            `uvm_fatal("DMAQ_DRIVER_DEFAULT",
                       "default queue did not begin empty at logical 31")
        if (cfgs[MAIN_Q].wait_mode != GQ_POLL ||
            cfgs[MAIN_Q].poll_policy != GQ_POLL_FIXED ||
            cfgs[MAIN_Q].poll_min_interval != 10ns ||
            cfgs[MAIN_Q].poll_max_interval != 10ns ||
            cfgs[MAIN_Q].poll_backoff_factor != 1)
            `uvm_fatal("DMAQ_DRIVER_DEFAULT_POLL",
                       "default queue did not select fixed 10 ns Poll cadence")

        for (int unsigned index = 0; index < 3; index++) begin
            select_literal_transfer(index, operation, source, destination,
                                    transfer_length, expected);
            transfer_seq = make_sequence(
                $sformatf("literal_sequence_%0d", index), operation,
                source, destination, transfer_length, 400ns);
            sequence_done = new($sformatf("literal_sequence_%0d_done", index));
            allocation_before = mem.allocation_calls;
            free_before = mem.free_calls;
            fork
                begin
                    automatic dmaq_transfer_sequence launched_sequence =
                        transfer_seq;
                    automatic uvm_event launched_done = sequence_done;
                    launched_sequence.start(sequencers[MAIN_Q]);
                    launched_done.trigger();
                end
            join_none

            wait_for_publish_count(MAIN_Q, index + 1, "literal transfer");
            dut.read_slot(engines[MAIN_Q], 31 + index, 32, raw);
            if (sequence_done.is_on() || !bytes_equal(raw, expected) ||
                adapters[MAIN_Q].published_tails[MAIN_Q][index] !=
                    literal_tails[index] ||
                mem.allocation_calls != allocation_before ||
                mem.free_calls != free_before)
                `uvm_fatal("DMAQ_DRIVER_LITERAL",
                           "literal descriptor, tail, block, or ownership diverged")

            if (index == 0) begin
                if (adapters[MAIN_Q].trace.size() != 4 ||
                    adapters[MAIN_Q].trace[0] != "RESET(queue=0)" ||
                    adapters[MAIN_Q].trace[1] !=
                        {"CONFIGURE(queue=0,base=0x00000001d0000000,",
                         "depth=32,size=32,hid=0x5aa55aa5,bdf=0x2345,",
                         "msix=0x0042,valid=1)"} ||
                    adapters[MAIN_Q].trace[2] != "ENABLE(queue=0)" ||
                    adapters[MAIN_Q].trace[3] !=
                        "PUBLISH(queue=0,tail=0x8000)" ||
                    adapters[MAIN_Q].publish_inspection_count[MAIN_Q] != 1 ||
                    !bytes_equal(adapters[MAIN_Q].last_published_slot[MAIN_Q],
                                 expected))
                    `uvm_fatal("DMAQ_DRIVER_ORDER",
                               "first publish did not follow reset/configure/enable or inspect committed bytes")
                query_before = completions[MAIN_Q].query_times.size();
                wait_for_queries(MAIN_Q, query_before + 3,
                                 "default fixed poll");
                if (adapters[MAIN_Q].published_tails[MAIN_Q].size() != 1 ||
                    sequence_done.is_on() ||
                    completions[MAIN_Q].query_times[query_before + 1] -
                        completions[MAIN_Q].query_times[query_before] != 10ns ||
                    completions[MAIN_Q].query_times[query_before + 2] -
                        completions[MAIN_Q].query_times[query_before + 1] !=
                            10ns)
                    `uvm_fatal("DMAQ_DRIVER_TAIL_ON_CHANGE",
                               {"default pending polls were not exactly 10 ns ",
                                "apart or rewrote the unchanged tail"})
            end

            if (!dut.complete_slot(engines[MAIN_Q], 31 + index, 32))
                `uvm_fatal("DMAQ_DRIVER_DUT",
                           "literal transfer completion was rejected")
            if (!sequence_done.is_on())
                sequence_done.wait_on();
            wait_for_observations(MAIN_Q, index + 1, "literal transfer");
            if (transfer_seq.result_status != DMAQ_RESULT_OK ||
                engines[MAIN_Q].head_seq() != 32 + index ||
                engines[MAIN_Q].tail_seq() != 32 + index ||
                engines[MAIN_Q].outstanding_count() != 0 ||
                mem.allocation_calls != allocation_before ||
                mem.free_calls != free_before)
                `uvm_fatal("DMAQ_DRIVER_RESULT",
                           "literal result, single retirement, or ownership diverged")
            check_observation(collectors[MAIN_Q].observations[index],
                              operation, source, destination,
                              transfer_length, "literal transfer");
        end

        source = endpoint(DMAQ_ENDPOINT_AF,
                          64'h1234_0000_0000_0001, 16'h1010, 16'h2020);
        destination = endpoint(DMAQ_ENDPOINT_HOST,
                               64'habcd_0000_0000_0002,
                               16'h3030, 16'h4040);
        for (gq_logical_seq_t logical_seq = 34; logical_seq < 64;
             logical_seq++) begin
            allocation_before = mem.allocation_calls;
            free_before = mem.free_calls;
            submit_one(MAIN_Q, DMAQ_AF_TO_HOST, source, destination,
                       int'(logical_seq - 33), desc, response);
            if (adapters[MAIN_Q].published_tails[MAIN_Q].size() !=
                    int'(logical_seq - 30) ||
                adapters[MAIN_Q].published_tails[MAIN_Q][logical_seq - 31] !=
                    literal_tails[logical_seq - 31] ||
                mem.allocation_calls != allocation_before ||
                mem.free_calls != free_before)
                `uvm_fatal("DMAQ_DRIVER_WRAP_TAIL", $sformatf(
                    "logical sequence %0d did not add its one literal tail",
                    logical_seq))
            if (!dut.complete_slot(engines[MAIN_Q], logical_seq, 32))
                `uvm_fatal("DMAQ_DRIVER_DUT",
                           "wrap completion was rejected")
            wait_for_observations(MAIN_Q, logical_seq - 30, "wrap");
            if (engines[MAIN_Q].head_seq() != logical_seq + 1 ||
                engines[MAIN_Q].tail_seq() != logical_seq + 1 ||
                mem.allocation_calls != allocation_before ||
                mem.free_calls != free_before)
                `uvm_fatal("DMAQ_DRIVER_WRAP_STATE",
                           "wrap did not retire once without business buffers")
        end
        if (adapters[MAIN_Q].published_tails[MAIN_Q].size() != 33 ||
            adapters[MAIN_Q].published_tails[MAIN_Q][0] != 16'h8000 ||
            adapters[MAIN_Q].published_tails[MAIN_Q][1] != 16'h8001 ||
            adapters[MAIN_Q].published_tails[MAIN_Q][31] != 16'h801f ||
            adapters[MAIN_Q].published_tails[MAIN_Q][32] != 16'h0000 ||
            engines[MAIN_Q].head_seq() != 64 ||
            engines[MAIN_Q].tail_seq() != 64)
            `uvm_fatal("DMAQ_DRIVER_WRAP",
                       "logical tail 64 did not publish the exact phase series")
        query_before = completions[MAIN_Q].query_times.size();
        #100ns;
        if (adapters[MAIN_Q].published_tails[MAIN_Q].size() != 33 ||
            completions[MAIN_Q].query_times.size() != query_before)
            `uvm_fatal("DMAQ_DRIVER_IDLE",
                       "idle time queried or rewrote a zero-outstanding queue")
    endtask

    task run_custom_and_zero_profiles();
        dmaq_operation_e operation;
        dmaq_endpoint_t source;
        dmaq_endpoint_t destination;
        int unsigned transfer_length;
        byte expected[];
        byte raw[];
        dmaq_transfer_sequence transfer_seq;
        uvm_event sequence_done;
        gq_addr_t custom_ring;
        int unsigned custom_ring_free_before;
        int unsigned query_before;

        initialize_queue(CUSTOM_Q);
        if (engines[CUSTOM_Q].head_seq() != 5 ||
            engines[CUSTOM_Q].tail_seq() != 5 ||
            engines[CUSTOM_Q].outstanding_count() != 0)
            `uvm_fatal("DMAQ_DRIVER_CUSTOM",
                       "custom queue did not begin empty at logical five")
        select_literal_transfer(0, operation, source, destination,
                                transfer_length, expected);
        transfer_seq = make_sequence("custom_sequence", operation, source,
                                     destination, transfer_length, 700ns);
        sequence_done = new("custom_sequence_done");
        query_before = completions[CUSTOM_Q].query_times.size();
        fork
            begin
                transfer_seq.start(sequencers[CUSTOM_Q]);
                sequence_done.trigger();
            end
        join_none
        wait_for_publish_count(CUSTOM_Q, 1, "custom first publish");
        dut.read_slot(engines[CUSTOM_Q], 5, 64, raw);
        if (!bytes_equal(raw, expected) ||
            adapters[CUSTOM_Q].published_tails[CUSTOM_Q][0] != 16'h0006)
            `uvm_fatal("DMAQ_DRIVER_CUSTOM_SLOT",
                       "custom descriptor was not in physical slot five")
        wait_for_queries(CUSTOM_Q, query_before + 3, "custom fixed poll");
        if (completions[CUSTOM_Q].query_times[query_before + 1] -
                completions[CUSTOM_Q].query_times[query_before] != 25ns ||
            completions[CUSTOM_Q].query_times[query_before + 2] -
                completions[CUSTOM_Q].query_times[query_before + 1] != 25ns)
            `uvm_fatal("DMAQ_DRIVER_CUSTOM_POLL",
                       "pending custom queries were not exactly 25 ns apart")
        if (!dut.complete_slot(engines[CUSTOM_Q], 5, 64))
            `uvm_fatal("DMAQ_DRIVER_DUT", "custom completion was rejected")
        if (!sequence_done.is_on())
            sequence_done.wait_on();
        if (transfer_seq.result_status != DMAQ_RESULT_OK ||
            engines[CUSTOM_Q].head_seq() != 6 ||
            engines[CUSTOM_Q].tail_seq() != 6)
            `uvm_fatal("DMAQ_DRIVER_CUSTOM_RESULT",
                       "custom completion did not advance both sequences")

        custom_ring = engines[CUSTOM_Q].ring_base();
        custom_ring_free_before = mem.free_count(custom_ring);
        engines[CUSTOM_Q].begin_reset();
        engines[CUSTOM_Q].finish_reset();
        if (engines[CUSTOM_Q].head_seq() != 5 ||
            engines[CUSTOM_Q].tail_seq() != 5 ||
            engines[CUSTOM_Q].ring_base() != 0 ||
            mem.free_count(custom_ring) != custom_ring_free_before + 1)
            `uvm_fatal("DMAQ_DRIVER_CUSTOM_RESET",
                       "custom reset teardown did not restore logical five")
        engines[CUSTOM_Q].release_reset();
        if (!engines[CUSTOM_Q].is_ready() ||
            engines[CUSTOM_Q].head_seq() != 5 ||
            engines[CUSTOM_Q].tail_seq() != 5 ||
            cfgs[CUSTOM_Q].depth != 64 ||
            cfgs[CUSTOM_Q].initial_logical_seq != 5 ||
            cfgs[CUSTOM_Q].poll_min_interval != 25ns ||
            cfgs[CUSTOM_Q].poll_max_interval != 25ns ||
            cfgs[CUSTOM_Q].poll_backoff_factor != 1 ||
            cfgs[CUSTOM_Q].completion_timeout != 750ns ||
            cfgs[CUSTOM_Q].desc_size != DMAQ_DESC_BYTES)
            `uvm_fatal("DMAQ_DRIVER_CUSTOM_RELEASE",
                       "custom reset release did not preserve the public profile")

        initialize_queue(ZERO_Q);
        if (engines[ZERO_Q].head_seq() != 0 ||
            engines[ZERO_Q].tail_seq() != 0)
            `uvm_fatal("DMAQ_DRIVER_ZERO",
                       "generic depth-32 queue did not begin at zero")
        engines[ZERO_Q].begin_reset();
        engines[ZERO_Q].finish_reset();
        if (engines[ZERO_Q].head_seq() != 0 ||
            engines[ZERO_Q].tail_seq() != 0)
            `uvm_fatal("DMAQ_DRIVER_ZERO_RESET",
                       "generic depth-32 reset did not return to zero")
        engines[ZERO_Q].release_reset();
        if (engines[ZERO_Q].head_seq() != 0 ||
            engines[ZERO_Q].tail_seq() != 0 ||
            !engines[ZERO_Q].is_ready())
            `uvm_fatal("DMAQ_DRIVER_ZERO_RELEASE",
                       "generic depth-32 release did not preserve zero origin")
    endtask

    task run_timeout_case(int unsigned queue_id, int unsigned timing_case,
                          dmaq_result_status_e expected_status,
                          string label);
        dmaq_operation_e operation;
        dmaq_endpoint_t source;
        dmaq_endpoint_t destination;
        int unsigned transfer_length;
        byte expected[];
        byte raw[];
        dmaq_transfer_sequence transfer_seq;
        dmaq_tx_desc pending_desc;
        dmaq_test_engine test_engine;
        uvm_event sequence_done;
        uvm_event allow_late_completion;
        uvm_event completion_injected;
        int unsigned allocation_before;
        int unsigned free_before;
        int unsigned timeout_before;

        initialize_queue(queue_id);
        if (!$cast(test_engine, engines[queue_id]))
            `uvm_fatal("DMAQ_DRIVER_ENGINE", "test engine override missing")
        select_literal_transfer(0, operation, source, destination,
                                transfer_length, expected);
        transfer_seq = make_sequence({label, "_sequence"}, operation,
                                     source, destination, transfer_length,
                                     500ns);
        sequence_done = new({label, "_sequence_done"});
        allow_late_completion = new({label, "_allow_late"});
        completion_injected = new({label, "_completion_injected"});
        allocation_before = mem.allocation_calls;
        free_before = mem.free_calls;
        timeout_before = report_catcher.timeout_count;
        if (timing_case == 2) begin
            report_catcher.timeout_event.reset();
            report_catcher.expect_timeout = 1;
        end

        fork
            begin
                automatic dmaq_transfer_sequence launched_sequence =
                    transfer_seq;
                automatic uvm_event launched_done = sequence_done;
                launched_sequence.start(sequencers[queue_id]);
                launched_done.trigger();
            end
            begin
                wait_for_publish_count(queue_id, 1, label);
                case (timing_case)
                    0: #490ns;
                    1: begin
                        #500ns;
                        uvm_wait_for_nba_region();
                        completions[queue_id].query_blocked.wait_on();
                        if (!dut.complete_slot(engines[queue_id], 31, 32))
                            `uvm_fatal("DMAQ_DRIVER_DUT",
                                       {label, " scheduled completion was rejected"})
                        fork
                            test_engine.invoke_deadline_check();
                            test_engine.invoke_deadline_check();
                        join_none
                        #0;
                        uvm_wait_for_nba_region();
                        uvm_wait_for_nba_region();
                        completions[queue_id].release_query();
                        completion_injected.trigger();
                    end
                    default: begin
                        #500ns;
                        #1step;
                        allow_late_completion.wait_on();
                    end
                endcase
                if (timing_case != 1 &&
                    !dut.complete_slot(engines[queue_id], 31, 32))
                    `uvm_fatal("DMAQ_DRIVER_DUT",
                               {label, " scheduled completion was rejected"})
                if (timing_case != 1)
                    engines[queue_id].drain_completed();
                if (timing_case != 1)
                    completion_injected.trigger();
            end
        join_none

        wait_for_publish_count(queue_id, 1, label);
        if (timing_case == 1)
            completions[queue_id].arm_settlement_observation(
                $time + cfgs[queue_id].completion_timeout,
                engines[queue_id].head_seq(),
                engines[queue_id].reset_epoch());
        if (timing_case == 1)
            completions[queue_id].block_next_query();
        dut.read_slot(engines[queue_id], 31, 32, raw);
        if (!bytes_equal(raw, expected) ||
            adapters[queue_id].published_tails[queue_id][0] != 16'h8000)
            `uvm_fatal("DMAQ_DRIVER_TIMEOUT_DESC",
                       {label, " did not publish the default literal slot"})
        if (timing_case == 1) begin
            completion_injected.wait_on();
            #1step;
        end
        if (!sequence_done.is_on())
            sequence_done.wait_on();
        if (transfer_seq.result_status != expected_status)
            `uvm_fatal("DMAQ_DRIVER_TIMEOUT_RESULT", $sformatf(
                "%s returned %0d, expected %0d", label,
                transfer_seq.result_status, expected_status))

        if (timing_case == 2) begin
            if (!report_catcher.timeout_event.is_on())
                report_catcher.timeout_event.wait_on();
            if (engines[queue_id].head_seq() != 31 ||
                engines[queue_id].tail_seq() != 32 ||
                engines[queue_id].outstanding_count() != 1 ||
                adapters[queue_id].published_tails[queue_id].size() != 1 ||
                collectors[queue_id].observations.size() != 0 ||
                report_catcher.timeout_count != timeout_before + 1)
                `uvm_fatal("DMAQ_DRIVER_LATE_STATE",
                           {"deadline settlement did not report exactly once ",
                            "or changed queue state or tail history"})
            dut.read_slot(engines[queue_id], 31, 32, raw);
            if (!bytes_equal(raw, expected))
                `uvm_fatal("DMAQ_DRIVER_LATE_BYTES",
                           "sequence timeout changed descriptor bytes")
            if (!$cast(pending_desc,
                       engines[queue_id].get_outstanding(31)))
                `uvm_fatal("DMAQ_DRIVER_LATE_HANDLE",
                           "late descriptor handle was not outstanding")
            allow_late_completion.trigger();
            completion_injected.wait_on();
            wait_for_observations(queue_id, 1, "late retirement");
            if (!pending_desc.completion_event.is_on() ||
                transfer_seq.result_status != DMAQ_RESULT_TIMEOUT ||
                engines[queue_id].head_seq() != 32 ||
                engines[queue_id].tail_seq() != 32 ||
                engines[queue_id].outstanding_count() != 0 ||
                report_catcher.timeout_count != timeout_before + 1)
                `uvm_fatal("DMAQ_DRIVER_LATE_RETIRE",
                           "one-step-late event did not retire without changing returned status")
            report_catcher.expect_timeout = 0;
        end else begin
            completion_injected.wait_on();
            wait_for_observations(queue_id, 1, label);
            if (engines[queue_id].head_seq() != 32 ||
                engines[queue_id].tail_seq() != 32 ||
                engines[queue_id].outstanding_count() != 0 ||
                report_catcher.timeout_count != timeout_before)
                `uvm_fatal("DMAQ_DRIVER_DEADLINE",
                           {label, " did not honor the inclusive deadline"})
            if (timing_case == 1 &&
                (completions[queue_id].blocked_query_count != 1 ||
                 completions[queue_id].final_settlement_query_count != 1))
                `uvm_fatal("DMAQ_DRIVER_DEADLINE_QUERY_CARDINALITY",
                           $sformatf("%s expected one final settlement query after one normal Poll query at epoch=%0d head=%0d; observed deadline_queries=%0d final_queries=%0d", label,
                                     completions[queue_id].settlement_epoch,
                                     completions[queue_id].settlement_head,
                                     completions[queue_id].blocked_query_count,
                                     completions[queue_id].final_settlement_query_count))
            else if (timing_case == 1)
                `uvm_info("DMAQ_DRIVER_DEADLINE_QUERY_CARDINALITY",
                          $sformatf("normal_queries=%0d final_queries=%0d", completions[queue_id].normal_settlement_query_count, completions[queue_id].final_settlement_query_count), UVM_LOW)
        end
        if (mem.allocation_calls != allocation_before ||
            mem.free_calls != free_before)
            `uvm_fatal("DMAQ_DRIVER_TIMEOUT_OWNER",
                       {label, " allocated or freed a borrowed business buffer"})
    endtask

    task run_timeout_scenarios();
        run_timeout_case(TIME_BEFORE_Q, 0, DMAQ_RESULT_OK,
                         "before deadline");
        run_timeout_case(TIME_AT_Q, 1, DMAQ_RESULT_OK,
                         "at deadline");
        run_timeout_case(TIME_AFTER_Q, 2, DMAQ_RESULT_TIMEOUT,
                         "after deadline");
    endtask

    task run_corruption_scenario();
        dmaq_operation_e operation;
        dmaq_endpoint_t source;
        dmaq_endpoint_t destination;
        int unsigned transfer_length;
        byte expected[];
        dmaq_tx_desc desc;
        gq_response response;
        int unsigned allocation_before;
        int unsigned free_before;
        int unsigned invalid_before;
        int unsigned completion_writes_before;
        byte slot_before[];
        byte slot_after[];
        gq_addr_t slot_addr;

        initialize_queue(ERROR_Q);
        select_literal_transfer(0, operation, source, destination,
                                transfer_length, expected);
        allocation_before = mem.allocation_calls;
        free_before = mem.free_calls;
        submit_one(ERROR_Q, operation, source, destination,
                   transfer_length, desc, response);
        slot_addr = engines[ERROR_Q].ring_base() +
                    (31 * DMAQ_DESC_BYTES);
        dut.read_slot(engines[ERROR_Q], 31, 32, slot_before);
        for (int invalid_offset = 0; invalid_offset <= 1;
             invalid_offset++) begin
            completion_writes_before = dut.completion_write_count;
            if (dut.complete_slot(engines[ERROR_Q], 31, 32,
                                  invalid_offset))
                `uvm_fatal("DMAQ_DRIVER_CORRUPT_FLAGS",
                           "flags-byte corruption was accepted")
            dut.read_slot(engines[ERROR_Q], 31, 32, slot_after);
            if (dut.completion_write_count != completion_writes_before ||
                !bytes_equal(slot_after, slot_before))
                `uvm_fatal("DMAQ_DRIVER_CORRUPT_FLAGS",
                           "rejected flags-byte corruption changed the slot")
        end

        if (!dut.complete_slot(engines[ERROR_Q], 31, 32))
            `uvm_fatal("DMAQ_DRIVER_CORRUPT_SENTINEL",
                       "no-corruption sentinel was rejected")
        mem.write_mem(slot_addr, slot_before, `__FILE__, `__LINE__);
        for (int stable_offset = 2; stable_offset < DMAQ_DESC_BYTES;
             stable_offset++) begin
            if (!dut.complete_slot(engines[ERROR_Q], 31, 32,
                                   stable_offset))
                `uvm_fatal("DMAQ_DRIVER_CORRUPT_STABLE",
                           "stable descriptor corruption was rejected")
            mem.write_mem(slot_addr, slot_before, `__FILE__, `__LINE__);
        end
        report_catcher.expect_invalid_query = 1;
        invalid_before = report_catcher.invalid_query_count;
        if (!dut.complete_slot(engines[ERROR_Q], 31, 32, 2))
            `uvm_fatal("DMAQ_DRIVER_DUT",
                       "stable corruption injection was rejected")
        engines[ERROR_Q].drain_completed();
        if (report_catcher.invalid_query_count != invalid_before + 1 ||
            report_catcher.expect_invalid_query ||
            collectors[ERROR_Q].observations.size() != 0 ||
            engines[ERROR_Q].head_seq() != 31 ||
            engines[ERROR_Q].tail_seq() != 32 ||
            engines[ERROR_Q].outstanding_count() != 1 ||
            mem.allocation_calls != allocation_before ||
            mem.free_calls != free_before)
            `uvm_fatal("DMAQ_DRIVER_CORRUPTION",
                       "stable corruption retired or changed borrowed ownership")
        engines[ERROR_Q].begin_reset();
        engines[ERROR_Q].finish_reset();
        if (engines[ERROR_Q].head_seq() != 31 ||
            engines[ERROR_Q].tail_seq() != 31 ||
            engines[ERROR_Q].outstanding_count() != 0)
            `uvm_fatal("DMAQ_DRIVER_CORRUPT_RESET",
                       "reset did not discard the corrupt outstanding slot")
    endtask

    task run_irq_scenarios();
        dmaq_operation_e operation;
        dmaq_endpoint_t source;
        dmaq_endpoint_t destination;
        int unsigned transfer_length;
        byte expected[];
        dmaq_tx_desc desc;
        gq_response response;
        int unsigned ack_before;
        int unsigned query_before;
        int unsigned trigger_before;

        initialize_queue(IRQ_Q);
        select_literal_transfer(0, operation, source, destination,
                                transfer_length, expected);
        submit_one(IRQ_Q, operation, source, destination,
                   transfer_length, desc, response);
        wait_for_irq_waits(IRQ_Q, 1, "real IRQ");
        if (!dut.complete_slot(engines[IRQ_Q], 31, 32))
            `uvm_fatal("DMAQ_DRIVER_DUT", "real IRQ completion failed")
        ack_before = adapters[IRQ_Q].ack_irq_count.exists(IRQ_Q) ?
                     adapters[IRQ_Q].ack_irq_count[IRQ_Q] : 0;
        query_before = completions[IRQ_Q].query_times.size();
        dut.trigger_irq(IRQ_Q);
        wait_for_observations(IRQ_Q, 1, "real IRQ");
        if (adapters[IRQ_Q].ack_irq_count[IRQ_Q] != ack_before + 1 ||
            completions[IRQ_Q].query_times.size() != query_before + 1 ||
            completions[IRQ_Q].ack_counts_at_query[query_before] !=
                ack_before + 1 ||
            engines[IRQ_Q].head_seq() != 32)
            `uvm_fatal("DMAQ_DRIVER_REAL_IRQ",
                       "real IRQ did not ACK once and query/retire once")

        select_literal_transfer(1, operation, source, destination,
                                transfer_length, expected);
        submit_one(IRQ_Q, operation, source, destination,
                   transfer_length, desc, response);
        wait_for_irq_waits(IRQ_Q, 2, "spurious IRQ");
        ack_before = adapters[IRQ_Q].ack_irq_count[IRQ_Q];
        query_before = completions[IRQ_Q].query_times.size();
        dut.trigger_irq(IRQ_Q);
        wait_for_queries(IRQ_Q, query_before + 1, "spurious IRQ");
        if (adapters[IRQ_Q].ack_irq_count[IRQ_Q] != ack_before + 1 ||
            completions[IRQ_Q].ack_counts_at_query[query_before] !=
                ack_before + 1 ||
            collectors[IRQ_Q].observations.size() != 1 ||
            engines[IRQ_Q].head_seq() != 32 ||
            engines[IRQ_Q].tail_seq() != 33 ||
            engines[IRQ_Q].outstanding_count() != 1)
            `uvm_fatal("DMAQ_DRIVER_SPURIOUS_IRQ",
                       "spurious IRQ was not ACKed once or retired work")

        wait_for_irq_waits(IRQ_Q, 3, "lost IRQ watchdog");
        if (!dut.complete_slot(engines[IRQ_Q], 32, 32))
            `uvm_fatal("DMAQ_DRIVER_DUT", "lost IRQ completion failed")
        ack_before = adapters[IRQ_Q].ack_irq_count[IRQ_Q];
        query_before = completions[IRQ_Q].query_times.size();
        trigger_before = adapters[IRQ_Q].trigger_irq_count[IRQ_Q];
        wait_for_observations(IRQ_Q, 2, "lost IRQ watchdog");
        if (cfgs[IRQ_Q].irq_watchdog_interval != 100ns ||
            adapters[IRQ_Q].ack_irq_count[IRQ_Q] != ack_before ||
            completions[IRQ_Q].query_times.size() < query_before + 1 ||
            completions[IRQ_Q].ack_counts_at_query[query_before] !=
                ack_before ||
            adapters[IRQ_Q].trigger_irq_count[IRQ_Q] != trigger_before ||
            adapters[IRQ_Q].published_tails[IRQ_Q].size() != 2 ||
            engines[IRQ_Q].outstanding_count() != 0)
            `uvm_fatal("DMAQ_DRIVER_LOST_IRQ",
                       "nonzero watchdog failed to recover without an IRQ ACK")
        `uvm_info("DMAQ_GQ_EXTENSION",
                  "IRQ/ACK/watchdog behavior is an explicit GQ extension, not EMP validation",
                  UVM_LOW)
    endtask

    task run_reset_blocked_irq_scenario();
        dmaq_operation_e operation;
        dmaq_endpoint_t source;
        dmaq_endpoint_t destination;
        int unsigned transfer_length;
        byte expected[];
        dmaq_tx_desc desc;
        gq_response response;
        gq_addr_t ring_addr;
        int unsigned ring_free_before;
        int unsigned ack_before;
        longint unsigned epoch_before;

        initialize_queue(RESET_IRQ_Q);
        select_literal_transfer(0, operation, source, destination,
                                transfer_length, expected);
        submit_one(RESET_IRQ_Q, operation, source, destination,
                   transfer_length, desc, response);
        wait_for_irq_waits(RESET_IRQ_Q, 1, "blocked IRQ reset");
        ring_addr = engines[RESET_IRQ_Q].ring_base();
        ring_free_before = mem.free_count(ring_addr);
        ack_before = adapters[RESET_IRQ_Q].ack_irq_count.exists(RESET_IRQ_Q) ?
                     adapters[RESET_IRQ_Q].ack_irq_count[RESET_IRQ_Q] : 0;
        epoch_before = engines[RESET_IRQ_Q].reset_epoch();
        engines[RESET_IRQ_Q].begin_reset();
        if (engines[RESET_IRQ_Q].reset_epoch() != epoch_before + 1)
            `uvm_fatal("DMAQ_DRIVER_RESET_IRQ_EPOCH",
                       "reset did not advance while IRQ wait was blocked")
        engines[RESET_IRQ_Q].finish_reset();
        if (adapters[RESET_IRQ_Q].disable_count[RESET_IRQ_Q] != 1 ||
            adapters[RESET_IRQ_Q].ack_irq_count[RESET_IRQ_Q] != ack_before ||
            collectors[RESET_IRQ_Q].observations.size() != 0 ||
            engines[RESET_IRQ_Q].head_seq() != 31 ||
            engines[RESET_IRQ_Q].tail_seq() != 31 ||
            engines[RESET_IRQ_Q].ring_base() != 0 ||
            mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("DMAQ_DRIVER_RESET_IRQ",
                       "blocked IRQ reset ACKed, retired, or released incorrectly")

        engines[RESET_IRQ_Q].release_reset();
        select_literal_transfer(2, operation, source, destination,
                                transfer_length, expected);
        submit_one(RESET_IRQ_Q, operation, source, destination,
                   transfer_length, desc, response);
        wait_for_irq_waits(RESET_IRQ_Q, 2, "released IRQ recovery");
        if (!dut.complete_slot(engines[RESET_IRQ_Q], 31, 32))
            `uvm_fatal("DMAQ_DRIVER_DUT",
                       "released IRQ recovery completion failed")
        dut.trigger_irq(RESET_IRQ_Q);
        wait_for_observations(RESET_IRQ_Q, 1, "released IRQ recovery");
        if (engines[RESET_IRQ_Q].head_seq() != 32 ||
            engines[RESET_IRQ_Q].tail_seq() != 32)
            `uvm_fatal("DMAQ_DRIVER_RESET_IRQ_RECOVERY",
                       "worker did not recover after reset release")
    endtask

    task run_reset_blocked_query_scenario();
        dmaq_operation_e operation;
        dmaq_endpoint_t source;
        dmaq_endpoint_t destination;
        int unsigned transfer_length;
        byte expected[];
        dmaq_tx_desc desc;
        gq_response response;
        gq_addr_t ring_addr;
        int unsigned ring_free_before;
        longint unsigned epoch_before;
        bit finish_done;

        initialize_queue(RESET_QUERY_Q);
        select_literal_transfer(0, operation, source, destination,
                                transfer_length, expected);
        completions[RESET_QUERY_Q].block_next_query();
        submit_one(RESET_QUERY_Q, operation, source, destination,
                   transfer_length, desc, response);
        if (!dut.complete_slot(engines[RESET_QUERY_Q], 31, 32))
            `uvm_fatal("DMAQ_DRIVER_DUT",
                       "blocked-query completion failed")
        completions[RESET_QUERY_Q].query_blocked.wait_on();
        ring_addr = engines[RESET_QUERY_Q].ring_base();
        ring_free_before = mem.free_count(ring_addr);
        epoch_before = engines[RESET_QUERY_Q].reset_epoch();
        engines[RESET_QUERY_Q].begin_reset();
        if (engines[RESET_QUERY_Q].reset_epoch() != epoch_before + 1 ||
            mem.free_count(ring_addr) != ring_free_before)
            `uvm_fatal("DMAQ_DRIVER_RESET_QUERY_EPOCH",
                       "blocked-query reset did not advance before freeing")
        finish_done = 0;
        fork
            begin
                engines[RESET_QUERY_Q].finish_reset();
                finish_done = 1;
            end
        join_none
        #1ns;
        if (finish_done || mem.free_count(ring_addr) != ring_free_before)
            `uvm_fatal("DMAQ_DRIVER_RESET_QUERY_BLOCK",
                       "reset freed the ring before query callback returned")
        completions[RESET_QUERY_Q].release_query();
        wait (finish_done);
        if (collectors[RESET_QUERY_Q].observations.size() != 0 ||
            engines[RESET_QUERY_Q].outstanding_count() != 0 ||
            engines[RESET_QUERY_Q].ring_base() != 0 ||
            mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("DMAQ_DRIVER_RESET_QUERY",
                       "stale blocked query retired or released ring incorrectly")
        engines[RESET_QUERY_Q].cleanup();
        if (mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("DMAQ_DRIVER_RESET_QUERY_ONCE",
                       "cleanup double-freed the blocked-query ring")
    endtask

    task run_reset_blocked_ack_scenario();
        dmaq_operation_e operation;
        dmaq_endpoint_t source;
        dmaq_endpoint_t destination;
        int unsigned transfer_length;
        byte expected[];
        dmaq_tx_desc desc;
        gq_response response;
        gq_addr_t ring_addr;
        int unsigned ring_free_before;
        int unsigned query_before;
        longint unsigned epoch_before;
        bit finish_done;

        initialize_queue(RESET_ACK_Q);
        select_literal_transfer(0, operation, source, destination,
                                transfer_length, expected);
        submit_one(RESET_ACK_Q, operation, source, destination,
                   transfer_length, desc, response);
        wait_for_irq_waits(RESET_ACK_Q, 1, "blocked ACK reset");
        if (!dut.complete_slot(engines[RESET_ACK_Q], 31, 32))
            `uvm_fatal("DMAQ_DRIVER_DUT", "blocked-ACK completion failed")
        ring_addr = engines[RESET_ACK_Q].ring_base();
        ring_free_before = mem.free_count(ring_addr);
        query_before = completions[RESET_ACK_Q].query_times.size();
        adapters[RESET_ACK_Q].block_next_irq_ack(RESET_ACK_Q);
        dut.trigger_irq(RESET_ACK_Q);
        adapters[RESET_ACK_Q].irq_ack_blocked[RESET_ACK_Q].wait_on();
        epoch_before = engines[RESET_ACK_Q].reset_epoch();
        engines[RESET_ACK_Q].begin_reset();
        if (engines[RESET_ACK_Q].reset_epoch() != epoch_before + 1 ||
            mem.free_count(ring_addr) != ring_free_before)
            `uvm_fatal("DMAQ_DRIVER_RESET_ACK_EPOCH",
                       "blocked-ACK reset did not advance before freeing")
        finish_done = 0;
        fork
            begin
                engines[RESET_ACK_Q].finish_reset();
                finish_done = 1;
            end
        join_none
        #1ns;
        if (finish_done || mem.free_count(ring_addr) != ring_free_before)
            `uvm_fatal("DMAQ_DRIVER_RESET_ACK_BLOCK",
                       "reset freed the ring before ACK callback returned")
        adapters[RESET_ACK_Q].release_irq_ack(RESET_ACK_Q);
        wait (finish_done);
        if (adapters[RESET_ACK_Q].ack_irq_count[RESET_ACK_Q] != 1 ||
            completions[RESET_ACK_Q].query_times.size() != query_before ||
            collectors[RESET_ACK_Q].observations.size() != 0 ||
            engines[RESET_ACK_Q].outstanding_count() != 0 ||
            engines[RESET_ACK_Q].ring_base() != 0 ||
            mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("DMAQ_DRIVER_RESET_ACK",
                       "stale blocked ACK queried, retired, or freed incorrectly")
        engines[RESET_ACK_Q].cleanup();
        if (mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("DMAQ_DRIVER_RESET_ACK_ONCE",
                       "cleanup double-freed the blocked-ACK ring")
    endtask

    task run_cleanup_blocked_publish_scenario();
        dmaq_operation_e operation;
        dmaq_endpoint_t source;
        dmaq_endpoint_t destination;
        int unsigned transfer_length;
        byte expected[];
        dmaq_tx_desc desc;
        gq_response response;
        gq_addr_t ring_addr;
        int unsigned ring_free_before;
        bit submit_done;
        bit cleanup_done;

        initialize_queue(CLEANUP_PUBLISH_Q);
        select_literal_transfer(0, operation, source, destination,
                                transfer_length, expected);
        ring_addr = engines[CLEANUP_PUBLISH_Q].ring_base();
        ring_free_before = mem.free_count(ring_addr);
        adapters[CLEANUP_PUBLISH_Q].block_next_publish(CLEANUP_PUBLISH_Q);
        submit_done = 0;
        fork
            begin
                submit_one(CLEANUP_PUBLISH_Q, operation, source, destination,
                           transfer_length, desc, response, 0);
                submit_done = 1;
            end
        join_none
        adapters[CLEANUP_PUBLISH_Q].publish_blocked[
            CLEANUP_PUBLISH_Q].wait_on();
        if (adapters[CLEANUP_PUBLISH_Q].published_tails[
                CLEANUP_PUBLISH_Q].size() != 0 ||
            adapters[CLEANUP_PUBLISH_Q].publish_inspection_count[
                CLEANUP_PUBLISH_Q] != 1 ||
            !bytes_equal(adapters[CLEANUP_PUBLISH_Q].last_published_slot[
                             CLEANUP_PUBLISH_Q],
                         expected))
            `uvm_fatal("DMAQ_DRIVER_BLOCKED_PUBLISH",
                       "blocked tail callback did not inspect committed memory")
        cleanup_done = 0;
        fork
            begin
                engines[CLEANUP_PUBLISH_Q].cleanup();
                cleanup_done = 1;
            end
        join_none
        wait_for_disable_count(CLEANUP_PUBLISH_Q, 1,
                               "blocked publish cleanup");
        wait (submit_done && cleanup_done);
        if (!adapters[CLEANUP_PUBLISH_Q].publish_returned[
                CLEANUP_PUBLISH_Q].is_on() ||
            response == null || response.status != GQ_ABORTED_BY_RESET ||
            response.committed_count != 0 ||
            adapters[CLEANUP_PUBLISH_Q].published_tails[
                CLEANUP_PUBLISH_Q].size() != 0 ||
            engines[CLEANUP_PUBLISH_Q].ring_base() != 0 ||
            engines[CLEANUP_PUBLISH_Q].head_seq() != 31 ||
            engines[CLEANUP_PUBLISH_Q].tail_seq() != 31 ||
            mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("DMAQ_DRIVER_CLEANUP_PUBLISH",
                       "cleanup did not cancel exact tail callback before one free")
        engines[CLEANUP_PUBLISH_Q].cleanup();
        if (mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("DMAQ_DRIVER_CLEANUP_PUBLISH_ONCE",
                       "second cleanup double-freed the blocked-publish ring")
    endtask

    task cleanup_all();
        for (int unsigned queue_id = 0; queue_id < QUEUE_COUNT;
             queue_id++)
            engines[queue_id].cleanup();
        #1ns;
        if (mem.borrowed_free_attempts != 0)
            `uvm_fatal("DMAQ_DRIVER_BORROWED_FREE",
                       "a borrowed source or destination address was freed")
        if (mem.allocation_calls != mem.free_calls)
            `uvm_fatal("DMAQ_DRIVER_RING_OWNER", $sformatf(
                "ring allocation/free calls diverged: alloc=%0d free=%0d",
                mem.allocation_calls, mem.free_calls))
        mem.leak_check(`__FILE__, `__LINE__);
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        uvm_report_cb::add(null, report_catcher);
        fork : conformance_watchdog
            begin
                #200us;
                `uvm_fatal("DMAQ_DRIVER_TEST_TIMEOUT",
                           "DMAQ driver conformance exceeded 200 us")
            end
        join_none

        run_literal_sequences_and_wrap();
        run_custom_and_zero_profiles();
        run_timeout_scenarios();
        run_corruption_scenario();
        run_irq_scenarios();
        run_reset_blocked_irq_scenario();
        run_reset_blocked_query_scenario();
        run_reset_blocked_ack_scenario();
        run_cleanup_blocked_publish_scenario();
        cleanup_all();

        if (report_catcher.invalid_query_count != 1 ||
            report_catcher.timeout_count != 1 ||
            report_catcher.expect_invalid_query ||
            report_catcher.expect_timeout)
            `uvm_fatal("DMAQ_DRIVER_REPORTS",
                       "expected corruption/timeout report counts diverged")
        uvm_report_cb::delete(null, report_catcher);
        disable conformance_watchdog;
        phase.drop_objection(this);
    endtask
endclass

`endif
