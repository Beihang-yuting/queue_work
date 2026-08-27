`ifndef TLPQ_DRIVER_CONFORMANCE_TEST_SV
`define TLPQ_DRIVER_CONFORMANCE_TEST_SV

class tlpq_wrong_adapter extends gq_hw_adapter;
    `uvm_object_utils(tlpq_wrong_adapter)

    function new(string name = "tlpq_wrong_adapter");
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

class tlpq_start_capture_driver extends
    uvm_driver #(gq_request, gq_response);
    `uvm_component_utils(tlpq_start_capture_driver)

    gq_request captured_requests[$];

    function new(string name = "tlpq_start_capture_driver",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        gq_request request;
        gq_response response;

        forever begin
            seq_item_port.get_next_item(request);
            captured_requests.push_back(request);
            response = gq_response::type_id::create($sformatf(
                "captured_response_%0d", captured_requests.size()));
            response.set_id_info(request);
            response.status = GQ_OK;
            response.committed_count = 31;
            response.reset_epoch = 0;
            seq_item_port.item_done(response);
        end
    endtask
endclass

class tlpq_driver_observation extends uvm_object;
    `uvm_object_utils(tlpq_driver_observation)

    byte dpu_bytes[];
    bit [15:0] flags;
    bit [15:0] buf_len;
    gq_addr_t buf_addr;
    tlpq_route_metadata_t metadata;
    int unsigned owned_allocation_count;
    tlp_kind_e decoded_kind;
    tlp_fmt_e decoded_fmt;
    tlp_type_e decoded_type;
    bit [9:0] decoded_length;
    bit [15:0] decoded_requester;
    bit [7:0] decoded_tag;
    gq_addr_t decoded_addr;
    time callback_time;

    function new(string name = "tlpq_driver_observation");
        super.new(name);
        dpu_bytes = new[0];
        flags = 0;
        buf_len = 0;
        buf_addr = 0;
        metadata = '0;
        owned_allocation_count = 0;
        decoded_kind = TLP_MEM_RD;
        decoded_fmt = FMT_4DW_NO_DATA;
        decoded_type = TLP_TYPE_MEM_RD;
        decoded_length = 0;
        decoded_requester = 0;
        decoded_tag = 0;
        decoded_addr = 0;
        callback_time = 0;
    endfunction
endclass

class tlpq_driver_collector extends uvm_component;
    `uvm_component_utils(tlpq_driver_collector)

    uvm_analysis_imp #(gq_desc_base, tlpq_driver_collector) analysis_export;
    tlpq_driver_observation observations[$];
    tlpq_rx_desc retained_snapshots[$];
    uvm_event observation_event;

    function new(string name = "tlpq_driver_collector",
                 uvm_component parent = null);
        super.new(name, parent);
        analysis_export = new("analysis_export", this);
        observation_event = new({name, "_observation"});
    endfunction

    function void write(gq_desc_base base_desc);
        tlpq_rx_desc desc;
        tlpq_rx_desc snapshot;
        pcie_tl_tlp decoded;
        pcie_tl_mem_tlp decoded_mem;
        uvm_object snapshot_object;
        tlpq_driver_observation observation;

        if (!$cast(desc, base_desc) || desc == null)
            `uvm_fatal("TLPQ_DRIVER_CALLBACK",
                       "completion callback was not a TLPQ RX descriptor")
        decoded = desc.decoded_tlp;
        if (decoded == null)
            `uvm_fatal("TLPQ_DRIVER_CALLBACK",
                       "completion callback did not carry a decoded TLP")
        snapshot_object = desc.clone();
        if (!$cast(snapshot, snapshot_object) || snapshot == null ||
            snapshot.decoded_tlp == null ||
            snapshot.decoded_tlp == desc.decoded_tlp ||
            snapshot.mem != null || snapshot.owned_allocation_count() != 0)
            `uvm_fatal("TLPQ_DRIVER_SNAPSHOT",
                       "callback clone was not a detached decoded snapshot")
        retained_snapshots.push_back(snapshot);
        observation = tlpq_driver_observation::type_id::create(
            $sformatf("observation_%0d", observations.size()));
        observation.dpu_bytes = new[desc.dpu_bytes.size()];
        foreach (desc.dpu_bytes[i])
            observation.dpu_bytes[i] = desc.dpu_bytes[i];
        observation.flags = desc.flags;
        observation.buf_len = desc.buf_len;
        observation.buf_addr = desc.buf_addr;
        observation.metadata = desc.metadata;
        observation.owned_allocation_count = desc.owned_allocation_count();
        observation.decoded_kind = decoded.kind;
        observation.decoded_fmt = decoded.fmt;
        observation.decoded_type = decoded.type_f;
        observation.decoded_length = decoded.length;
        observation.decoded_requester = decoded.requester_id;
        observation.decoded_tag = decoded.tag[7:0];
        observation.decoded_addr = 0;
        if ($cast(decoded_mem, decoded) && decoded_mem != null)
            observation.decoded_addr = decoded_mem.addr;
        observation.callback_time = $time;
        observations.push_back(observation);
        observation_event.trigger();
    endfunction
endclass

class tlpq_driver_report_catcher extends uvm_report_catcher;
    `uvm_object_utils(tlpq_driver_report_catcher)

    int unsigned invalid_query_count;
    int unsigned parse_error_count;
    uvm_severity report_severities[$];
    string report_ids[$];
    string report_messages[$];

    function new(string name = "tlpq_driver_report_catcher");
        super.new(name);
        invalid_query_count = 0;
        parse_error_count = 0;
    endfunction

    virtual function action_e catch();
        if (get_id() != "GQ_COMPLETION_QUERY" &&
            get_id() != "GQ_COMPLETION_PARSE")
            return THROW;
        report_severities.push_back(get_severity());
        report_ids.push_back(get_id());
        report_messages.push_back(get_message());
        if (get_id() == "GQ_COMPLETION_QUERY")
            invalid_query_count++;
        else
            parse_error_count++;
        if ((get_id() == "GQ_COMPLETION_QUERY" &&
             get_severity() == UVM_WARNING) ||
            (get_id() == "GQ_COMPLETION_PARSE" &&
             get_severity() == UVM_ERROR))
            return CAUGHT;
        return THROW;
    endfunction
endclass

class tlpq_reg_error_catcher extends uvm_report_catcher;
    `uvm_object_utils(tlpq_reg_error_catcher)

    int unsigned role_errors;
    int unsigned queue_errors;
    int unsigned pointer_errors;
    int unsigned initial_tail_errors;
    int unsigned state_errors;

    function new(string name = "tlpq_reg_error_catcher");
        super.new(name);
        role_errors = 0;
        queue_errors = 0;
        pointer_errors = 0;
        initial_tail_errors = 0;
        state_errors = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR && get_id() == "TLPQ_REG_ROLE") begin
            role_errors++;
            return CAUGHT;
        end
        if (get_severity() == UVM_ERROR && get_id() == "TLPQ_REG_QUEUE") begin
            queue_errors++;
            return CAUGHT;
        end
        if (get_severity() == UVM_ERROR && get_id() == "TLPQ_REG_PTR") begin
            pointer_errors++;
            return CAUGHT;
        end
        if (get_severity() == UVM_ERROR &&
            get_id() == "TLPQ_REG_INITIAL_TAIL") begin
            initial_tail_errors++;
            return CAUGHT;
        end
        if (get_severity() == UVM_ERROR && get_id() == "TLPQ_REG_STATE") begin
            state_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class tlpq_driver_conformance_test extends uvm_test;
    `uvm_component_utils(tlpq_driver_conformance_test)

    localparam gq_addr_t HOST_BASE   = 64'h0000_0001_e000_0000;
    localparam gq_addr_t SWITCH_BASE = 64'h0000_0001_e001_0000;

    localparam int unsigned MAIN_HOST_ENGINE   = 0;
    localparam int unsigned MAIN_SWITCH_ENGINE = 1;
    localparam int unsigned POLL_HOST_ENGINE   = 2;
    localparam int unsigned POLL_SWITCH_ENGINE = 3;
    localparam int unsigned ERROR_HOST_ENGINE  = 4;
    localparam int unsigned GOLDEN_HOST_ENGINE = 5;
    localparam int unsigned DRIVER_ENGINE_COUNT = 6;
    localparam int unsigned MAIN_ADAPTER_SLOT  = 0;
    localparam int unsigned POLL_ADAPTER_SLOT  = 1;
    localparam int unsigned ERROR_ADAPTER_SLOT = 2;
    localparam int unsigned GOLDEN_ADAPTER_SLOT = 3;

    tlpq_driver_mem mem;
    tlpq_mock_adapter adapter;
    tlpq_env_cfg env_cfg;
    gq_queue_cfg host_cfg;
    gq_queue_cfg switch_cfg;
    tlpq_refill_profile host_profile;
    tlpq_refill_profile switch_profile;
    tlpq_rx_hw_cfg_t host_hw_cfg;
    tlpq_rx_hw_cfg_t switch_hw_cfg;
    gq_sequencer host_start_sequencer;
    gq_sequencer switch_start_sequencer;
    tlpq_start_capture_driver host_start_driver;
    tlpq_start_capture_driver switch_start_driver;
    tlpq_mock_adapter driver_adapters[int unsigned];
    gq_queue_cfg driver_cfgs[int unsigned];
    tlpq_refill_profile driver_profiles[int unsigned];
    tlpq_mock_completion driver_completions[int unsigned];
    gq_queue_engine driver_engines[int unsigned];
    tlpq_driver_collector driver_collectors[int unsigned];
    bit driver_worker_started[int unsigned];
    bit driver_worker_returned[int unsigned];
    bit retired_descriptor_ids[int];
    int unsigned retired_generation_by_addr[gq_addr_t];
    tlpq_mock_dut dut;
    tlpq_driver_report_catcher driver_report_catcher;

    function new(string name = "tlpq_driver_conformance_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function tlpq_channel_e driver_channel(int unsigned engine_id);
        if (engine_id == MAIN_SWITCH_ENGINE ||
            engine_id == POLL_SWITCH_ENGINE)
            return TLPQ_SWITCH;
        return TLPQ_HOST;
    endfunction

    function int unsigned driver_adapter_slot(int unsigned engine_id);
        if (engine_id == MAIN_HOST_ENGINE ||
            engine_id == MAIN_SWITCH_ENGINE)
            return MAIN_ADAPTER_SLOT;
        if (engine_id == POLL_HOST_ENGINE ||
            engine_id == POLL_SWITCH_ENGINE)
            return POLL_ADAPTER_SLOT;
        if (engine_id == GOLDEN_HOST_ENGINE)
            return GOLDEN_ADAPTER_SLOT;
        return ERROR_ADAPTER_SLOT;
    endfunction

    function gq_queue_cfg make_driver_cfg(
        int unsigned engine_id, gq_wait_mode_e wait_mode);
        gq_queue_cfg cfg;
        tlpq_channel_e channel;

        channel = driver_channel(engine_id);
        cfg = gq_queue_cfg::type_id::create(
            $sformatf("driver_%0d_cfg", engine_id));
        cfg.queue_id = channel == TLPQ_HOST ?
                       TLPQ_HOST_QUEUE_ID : TLPQ_SWITCH_QUEUE_ID;
        cfg.role = GQ_RX;
        cfg.depth = TLPQ_DEPTH;
        cfg.desc_size = TLPQ_DESC_BYTES;
        cfg.alignment = 64;
        cfg.status_area_size = 0;
        cfg.wait_mode = wait_mode;
        cfg.poll_policy = GQ_POLL_FIXED;
        cfg.poll_min_interval = 10ns;
        cfg.poll_max_interval = 10ns;
        cfg.poll_backoff_factor = 2;
        cfg.irq_watchdog_interval = 1us;
        cfg.completion_timeout = 0;
        cfg.rx_slot_mode = GQ_RX_EXPLICIT_REFILL;
        cfg.ptr_codec = tlpq_ptr_codec::type_id::create(
            $sformatf("driver_%0d_ptr_codec", engine_id));
        driver_completions[engine_id] =
            tlpq_mock_completion::type_id::create(
                $sformatf("driver_%0d_completion", engine_id));
        driver_completions[engine_id].channel = channel;
        cfg.completion_source = driver_completions[engine_id];
        driver_profiles[engine_id] =
            tlpq_refill_profile::type_id::create(
                $sformatf("driver_%0d_profile", engine_id));
        return cfg;
    endfunction

    function void build_driver_engine(
        int unsigned engine_id, gq_wait_mode_e wait_mode);
        string engine_name;
        string collector_name;
        string reason;
        int unsigned adapter_slot;

        adapter_slot = driver_adapter_slot(engine_id);
        driver_cfgs[engine_id] = make_driver_cfg(engine_id, wait_mode);
        if (driver_cfgs[engine_id] == null ||
            driver_profiles[engine_id] == null ||
            !driver_cfgs[engine_id].validate(reason) ||
            !driver_profiles[engine_id].validate(TLPQ_DEPTH, reason))
            `uvm_fatal("TLPQ_DRIVER_CFG", $sformatf(
                "engine %0d directed configuration rejected: %s",
                engine_id, reason))
        engine_name = $sformatf("driver_engine_%0d", engine_id);
        collector_name = $sformatf("driver_collector_%0d", engine_id);
        uvm_config_db#(gq_queue_cfg)::set(
            this, engine_name, "cfg", driver_cfgs[engine_id]);
        uvm_config_db#(host_mem_api)::set(
            this, engine_name, "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(
            this, engine_name, "adapter", driver_adapters[adapter_slot]);
        driver_engines[engine_id] = gq_queue_engine::type_id::create(
            engine_name, this);
        driver_collectors[engine_id] =
            tlpq_driver_collector::type_id::create(collector_name, this);
        driver_worker_started[engine_id] = 0;
        driver_worker_returned[engine_id] = 0;
    endfunction

    function void build_phase(uvm_phase phase);
        string reason;
        tlpq_rx_hw_cfg_t main_host_hw;
        tlpq_rx_hw_cfg_t main_switch_hw;
        tlpq_rx_hw_cfg_t poll_host_hw;
        tlpq_rx_hw_cfg_t poll_switch_hw;
        tlpq_rx_hw_cfg_t error_host_hw;
        tlpq_rx_hw_cfg_t golden_host_hw;

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_e000_0000,
                        64'h0000_0001_e0ff_ffff, MODE_LINEAR, 16);
        for (int unsigned adapter_slot = 0;
             adapter_slot <= GOLDEN_ADAPTER_SLOT; adapter_slot++)
            driver_adapters[adapter_slot] =
                tlpq_mock_adapter::type_id::create(
                    $sformatf("driver_adapter_%0d", adapter_slot));

        main_host_hw = '{host_id:3'h1, bdf:16'h0100,
                         msix_index:13'h011, msix_valid:1'b1};
        main_switch_hw = '{host_id:3'h5, bdf:16'h0201,
                           msix_index:13'h122, msix_valid:1'b1};
        poll_host_hw = '{host_id:3'h2, bdf:16'h0300,
                         msix_index:13'h033, msix_valid:1'b1};
        poll_switch_hw = '{host_id:3'h6, bdf:16'h0401,
                           msix_index:13'h144, msix_valid:1'b1};
        error_host_hw = '{host_id:3'h3, bdf:16'h0500,
                          msix_index:13'h055, msix_valid:1'b1};
        golden_host_hw = '{host_id:3'h4, bdf:16'h0600,
                           msix_index:13'h066, msix_valid:1'b1};
        if (!driver_adapters[MAIN_ADAPTER_SLOT].register_tlpq_rx(
                TLPQ_HOST, TLPQ_HOST_QUEUE_ID, main_host_hw, reason) ||
            !driver_adapters[MAIN_ADAPTER_SLOT].register_tlpq_rx(
                TLPQ_SWITCH, TLPQ_SWITCH_QUEUE_ID,
                main_switch_hw, reason) ||
            !driver_adapters[POLL_ADAPTER_SLOT].register_tlpq_rx(
                TLPQ_HOST, TLPQ_HOST_QUEUE_ID, poll_host_hw, reason) ||
            !driver_adapters[POLL_ADAPTER_SLOT].register_tlpq_rx(
                TLPQ_SWITCH, TLPQ_SWITCH_QUEUE_ID,
                poll_switch_hw, reason) ||
            !driver_adapters[ERROR_ADAPTER_SLOT].register_tlpq_rx(
                TLPQ_HOST, TLPQ_HOST_QUEUE_ID, error_host_hw, reason) ||
            !driver_adapters[GOLDEN_ADAPTER_SLOT].register_tlpq_rx(
                TLPQ_HOST, TLPQ_HOST_QUEUE_ID, golden_host_hw, reason))
            `uvm_fatal("TLPQ_DRIVER_MAP",
                       {"directed adapter mapping failed: ", reason})

        build_driver_engine(MAIN_HOST_ENGINE, GQ_IRQ);
        build_driver_engine(MAIN_SWITCH_ENGINE, GQ_IRQ);
        build_driver_engine(POLL_HOST_ENGINE, GQ_POLL);
        build_driver_engine(POLL_SWITCH_ENGINE, GQ_POLL);
        build_driver_engine(ERROR_HOST_ENGINE, GQ_POLL);
        build_driver_engine(GOLDEN_HOST_ENGINE, GQ_IRQ);
        dut = tlpq_mock_dut::type_id::create("dut");
        dut.mem = mem;
        driver_report_catcher =
            tlpq_driver_report_catcher::type_id::create(
                "driver_report_catcher");
        host_start_sequencer = gq_sequencer::type_id::create(
            "host_start_sequencer", this);
        switch_start_sequencer = gq_sequencer::type_id::create(
            "switch_start_sequencer", this);
        host_start_driver = tlpq_start_capture_driver::type_id::create(
            "host_start_driver", this);
        switch_start_driver = tlpq_start_capture_driver::type_id::create(
            "switch_start_driver", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        for (int unsigned engine_id = 0;
             engine_id < DRIVER_ENGINE_COUNT; engine_id++)
            driver_engines[engine_id].completion_ap.connect(
                driver_collectors[engine_id].analysis_export);
        host_start_driver.seq_item_port.connect(
            host_start_sequencer.seq_item_export);
        switch_start_driver.seq_item_port.connect(
            switch_start_sequencer.seq_item_export);
    endfunction

    function void make_host_fixture(
        string fixture_name,
        output tlpq_mock_adapter fixture_adapter,
        output tlpq_env_cfg fixture_cfg);
        string reason;

        fixture_adapter = tlpq_mock_adapter::type_id::create(
            {fixture_name, "_adapter"});
        fixture_cfg = tlpq_env_cfg::type_id::create(
            {fixture_name, "_cfg"});
        fixture_cfg.mem = mem;
        fixture_cfg.adapter = fixture_adapter;
        if (!fixture_cfg.add_tlpq_rx(
                TLPQ_HOST, TLPQ_HOST_QUEUE_ID, host_hw_cfg, reason))
            `uvm_fatal("TLPQ_FIXTURE",
                       {"failed to build Host fixture: ", reason})
    endfunction

    function void check_defaults();
        string reason;

        host_cfg = env_cfg.get_tlpq_rx_cfg(TLPQ_HOST);
        switch_cfg = env_cfg.get_tlpq_rx_cfg(TLPQ_SWITCH);
        host_profile = env_cfg.get_refill_profile(TLPQ_HOST);
        switch_profile = env_cfg.get_refill_profile(TLPQ_SWITCH);

        if (host_cfg == null || switch_cfg == null ||
            host_cfg == switch_cfg ||
            host_cfg.queue_id != TLPQ_HOST_QUEUE_ID ||
            switch_cfg.queue_id != TLPQ_SWITCH_QUEUE_ID ||
            host_cfg.role != GQ_RX || switch_cfg.role != GQ_RX ||
            host_cfg.depth != 32 || switch_cfg.depth != 32 ||
            host_cfg.desc_size != 16 || switch_cfg.desc_size != 16 ||
            host_cfg.rx_slot_mode != GQ_RX_EXPLICIT_REFILL ||
            switch_cfg.rx_slot_mode != GQ_RX_EXPLICIT_REFILL ||
            host_cfg.wait_mode != GQ_IRQ || switch_cfg.wait_mode != GQ_IRQ ||
            host_cfg.poll_policy != GQ_POLL_ADAPTIVE ||
            switch_cfg.poll_policy != GQ_POLL_ADAPTIVE ||
            host_cfg.poll_min_interval != 50ns ||
            switch_cfg.poll_min_interval != 50ns ||
            host_cfg.poll_max_interval != 500ns ||
            switch_cfg.poll_max_interval != 500ns ||
            host_cfg.irq_watchdog_interval != 1us ||
            switch_cfg.irq_watchdog_interval != 1us ||
            host_cfg.completion_timeout != 0 ||
            switch_cfg.completion_timeout != 0)
            `uvm_fatal("TLPQ_DEFAULT_CFG",
                       "Host/Switch standard RX queue defaults diverged")

        if (host_cfg.ptr_codec == null || switch_cfg.ptr_codec == null ||
            host_cfg.ptr_codec == switch_cfg.ptr_codec ||
            host_cfg.completion_source == null ||
            switch_cfg.completion_source == null ||
            host_cfg.completion_source == switch_cfg.completion_source ||
            host_profile == null || switch_profile == null ||
            host_profile == switch_profile ||
            host_profile.initial_post_count != 31 ||
            switch_profile.initial_post_count != 31 ||
            host_profile.low_watermark != 30 ||
            switch_profile.low_watermark != 30 ||
            host_profile.high_watermark != 31 ||
            switch_profile.high_watermark != 31 ||
            host_profile.max_refill_batch != 1 ||
            switch_profile.max_refill_batch != 1 ||
            !host_profile.restart_after_reset ||
            !switch_profile.restart_after_reset)
            `uvm_fatal("TLPQ_DEFAULT_ISOLATION",
                       "Host/Switch strategies or refill profiles are shared")

        host_cfg.wait_mode = GQ_POLL;
        host_cfg.poll_policy = GQ_POLL_FIXED;
        host_cfg.poll_max_interval = host_cfg.poll_min_interval;
        if (!env_cfg.validate(reason))
            `uvm_fatal("TLPQ_POLL_FIXED",
                       {"fixed Poll selection was rejected: ", reason})
        host_cfg.poll_policy = GQ_POLL_ADAPTIVE;
        host_cfg.poll_max_interval = 500ns;
        if (!env_cfg.validate(reason))
            `uvm_fatal("TLPQ_POLL_ADAPTIVE",
                       {"adaptive Poll selection was rejected: ", reason})
        host_cfg.wait_mode = GQ_IRQ;
    endfunction

    task check_channel_setup(
        tlpq_channel_e channel, int unsigned queue_id,
        gq_addr_t base, tlpq_rx_hw_cfg_t hw_cfg);
        string expected_trace[$];
        string channel_name;
        int channel_key;

        channel_name = channel == TLPQ_HOST ? "HOST" : "SWITCH";
        channel_key = int'(channel);
        expected_trace.push_back($sformatf(
            "RESET(channel=%s)", channel_name));
        expected_trace.push_back($sformatf(
            {"CONFIGURE(channel=%s,base=0x%016h,depth=32,size=16,",
             "host_id=0x%01h,bdf=0x%04h,msix=0x%04h,valid=%0b)"},
            channel_name, base, hw_cfg.host_id, hw_cfg.bdf,
            hw_cfg.msix_index, hw_cfg.msix_valid));
        expected_trace.push_back($sformatf(
            "PUBLISH(channel=%s,tail=31)", channel_name));
        expected_trace.push_back($sformatf(
            "ENABLE(channel=%s)", channel_name));

        adapter.clear_trace(channel);
        adapter.configure_queue(GQ_RX, queue_id, base, 32, 16);
        if (adapter.enable_count[channel_key] != 0)
            `uvm_fatal("TLPQ_EARLY_ENABLE",
                       "configure_queue enabled RX before initial publish")
        adapter.publish(GQ_RX, queue_id, 32'h0000_001f);
        if (adapter.trace[channel_key] != expected_trace)
            `uvm_fatal("TLPQ_SETUP_TRACE", $sformatf(
                "%s trace was not RESET,CONFIGURE,PUBLISH,ENABLE",
                channel_name))
        if (adapter.reset_count[channel_key] != 1 ||
            adapter.configure_count[channel_key] != 1 ||
            adapter.enable_count[channel_key] != 1 ||
            adapter.configured_base[channel_key] != base ||
            adapter.configured_depth[channel_key] != 32 ||
            adapter.configured_desc_size[channel_key] != 16 ||
            adapter.configured_hw_cfg[channel_key] != hw_cfg ||
            adapter.published_tails[channel_key].size() != 1 ||
            adapter.published_tails[channel_key][0] != 16'h001f)
            `uvm_fatal("TLPQ_SETUP_ARGS", $sformatf(
                "%s setup arguments/counters diverged", channel_name))

        adapter.publish(GQ_RX, queue_id, 32'h0000_001e);
        if (adapter.enable_count[channel_key] != 1 ||
            adapter.published_tails[channel_key].size() != 2)
            `uvm_fatal("TLPQ_ENABLE_ON_REFILL",
                       "refill publish repeated the deferred enable")
    endtask

    task check_reconfigure_rearms();
        int host_key;
        int switch_key;

        host_key = int'(TLPQ_HOST);
        switch_key = int'(TLPQ_SWITCH);
        adapter.clear_trace(TLPQ_HOST);
        adapter.configure_queue(GQ_RX, TLPQ_HOST_QUEUE_ID,
                                HOST_BASE, 32, 16);
        if (adapter.enable_count[host_key] != 1)
            `uvm_fatal("TLPQ_RECONFIG_EARLY_ENABLE",
                       "reconfigure enabled Host before its next publish")
        adapter.publish(GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0000_001f);
        if (adapter.enable_count[host_key] != 2 ||
            adapter.enable_count[switch_key] != 1)
            `uvm_fatal("TLPQ_RECONFIG_REARM",
                       "Host reconfigure did not rearm exactly Host enable")
    endtask

    task check_irq_isolation();
        int host_key;
        int switch_key;
        int switch_trace_before;

        host_key = int'(TLPQ_HOST);
        switch_key = int'(TLPQ_SWITCH);
        switch_trace_before = adapter.trace[switch_key].size();
        adapter.trigger_irq(TLPQ_HOST);
        adapter.wait_irq(GQ_RX, TLPQ_HOST_QUEUE_ID);
        adapter.ack_irq(GQ_RX, TLPQ_HOST_QUEUE_ID);
        if (adapter.wait_irq_count[host_key] != 1 ||
            adapter.ack_irq_count[host_key] != 1 ||
            adapter.wait_irq_count[switch_key] != 0 ||
            adapter.ack_irq_count[switch_key] != 0 ||
            adapter.trace[switch_key].size() != switch_trace_before)
            `uvm_fatal("TLPQ_IRQ_ISOLATION",
                       "Host IRQ activity crossed into Switch state")
    endtask

    task check_generic_rejections();
        tlpq_reg_error_catcher catcher;
        int host_trace_before;
        int switch_trace_before;

        host_trace_before = adapter.trace[int'(TLPQ_HOST)].size();
        switch_trace_before = adapter.trace[int'(TLPQ_SWITCH)].size();
        catcher = tlpq_reg_error_catcher::type_id::create("catcher");
        uvm_report_cb::add(null, catcher);
        adapter.configure_queue(GQ_TX, TLPQ_HOST_QUEUE_ID,
                                HOST_BASE, 32, 16);
        adapter.disable_queue(GQ_TX, TLPQ_HOST_QUEUE_ID);
        adapter.publish(GQ_TX, TLPQ_HOST_QUEUE_ID, 32'h0000_0001);
        adapter.wait_irq(GQ_TX, TLPQ_HOST_QUEUE_ID);
        adapter.ack_irq(GQ_TX, TLPQ_HOST_QUEUE_ID);
        adapter.configure_queue(GQ_RX, 99, HOST_BASE, 32, 16);
        adapter.disable_queue(GQ_RX, 99);
        adapter.publish(GQ_RX, 99, 32'h0000_0001);
        adapter.wait_irq(GQ_RX, 99);
        adapter.ack_irq(GQ_RX, 99);
        adapter.publish(GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0001_001f);
        uvm_report_cb::delete(null, catcher);

        if (catcher.role_errors != 5 || catcher.queue_errors != 5 ||
            catcher.pointer_errors != 1)
            `uvm_fatal("TLPQ_GENERIC_REJECT", $sformatf(
                "role/queue/pointer rejection counts were %0d/%0d/%0d",
                catcher.role_errors, catcher.queue_errors,
                catcher.pointer_errors))
        if (adapter.trace[int'(TLPQ_HOST)].size() != host_trace_before ||
            adapter.trace[int'(TLPQ_SWITCH)].size() != switch_trace_before)
            `uvm_fatal("TLPQ_GENERIC_LEAK",
                       "rejected generic operation reached semantic callback")
    endtask

    task check_initial_tail_gate();
        tlpq_mock_adapter tail_adapter;
        tlpq_env_cfg tail_cfg;
        tlpq_reg_error_catcher catcher;
        string expected_trace[$];
        int host_key;

        host_key = int'(TLPQ_HOST);
        make_host_fixture("tail_gate", tail_adapter, tail_cfg);
        tail_adapter.configure_queue(
            GQ_RX, TLPQ_HOST_QUEUE_ID, HOST_BASE, 32, 16);
        tail_adapter.clear_trace(TLPQ_HOST);
        catcher = tlpq_reg_error_catcher::type_id::create(
            "initial_tail_catcher");
        uvm_report_cb::add(null, catcher);
        tail_adapter.publish(
            GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0000_001e);
        tail_adapter.publish(
            GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0000_0000);
        uvm_report_cb::delete(null, catcher);

        if (catcher.initial_tail_errors != 2 ||
            tail_adapter.trace[host_key].size() != 0 ||
            tail_adapter.published_tails[host_key].size() != 0 ||
            tail_adapter.enable_count[host_key] != 0)
            `uvm_error("TLPQ_INITIAL_TAIL_REJECT",
                       "tail 30/0 did not preserve an armed, disabled queue")

        expected_trace.push_back("PUBLISH(channel=HOST,tail=31)");
        expected_trace.push_back("ENABLE(channel=HOST)");
        tail_adapter.publish(
            GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0000_001f);
        if (tail_adapter.trace[host_key] != expected_trace ||
            tail_adapter.published_tails[host_key].size() != 1 ||
            tail_adapter.published_tails[host_key][0] != 16'h001f ||
            tail_adapter.enable_count[host_key] != 1)
            `uvm_error("TLPQ_INITIAL_TAIL_RECOVERY",
                       "legal tail 31 did not consume the preserved arm once")
    endtask

    task check_configure_disable_barrier();
        tlpq_mock_adapter race_adapter;
        tlpq_env_cfg race_cfg;
        tlpq_reg_error_catcher catcher;
        bit configure_done;
        int host_key;

        host_key = int'(TLPQ_HOST);
        configure_done = 0;
        make_host_fixture("configure_disable", race_adapter, race_cfg);
        race_adapter.block_next_configure(TLPQ_HOST);
        fork
            begin
                race_adapter.configure_queue(
                    GQ_RX, TLPQ_HOST_QUEUE_ID, HOST_BASE, 32, 16);
                configure_done = 1;
            end
        join_none
        race_adapter.configure_entered[host_key].wait_on();
        race_adapter.disable_queue(GQ_RX, TLPQ_HOST_QUEUE_ID);
        wait (configure_done);

        catcher = tlpq_reg_error_catcher::type_id::create(
            "configure_disable_catcher");
        uvm_report_cb::add(null, catcher);
        race_adapter.publish(
            GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0000_001f);
        uvm_report_cb::delete(null, catcher);
        if (catcher.state_errors != 1 ||
            race_adapter.configure_count[host_key] != 0 ||
            race_adapter.published_tails[host_key].size() != 0 ||
            race_adapter.enable_count[host_key] != 0)
            `uvm_error("TLPQ_CONFIGURE_DISABLE_RACE",
                       "cancelled configure rearmed or enabled the queue")
    endtask

    task check_configure_configure_barrier();
        tlpq_mock_adapter race_adapter;
        tlpq_env_cfg race_cfg;
        bit first_done;
        bit second_done;
        int host_key;
        gq_addr_t newer_base;

        host_key = int'(TLPQ_HOST);
        newer_base = HOST_BASE + 64'h0000_0000_0000_2000;
        first_done = 0;
        second_done = 0;
        make_host_fixture("configure_configure", race_adapter, race_cfg);
        race_adapter.block_next_configure(TLPQ_HOST);
        fork
            begin
                race_adapter.configure_queue(
                    GQ_RX, TLPQ_HOST_QUEUE_ID, HOST_BASE, 32, 16);
                first_done = 1;
            end
        join_none
        race_adapter.configure_entered[host_key].wait_on();
        fork
            begin
                race_adapter.configure_queue(
                    GQ_RX, TLPQ_HOST_QUEUE_ID, newer_base, 32, 16);
                second_done = 1;
            end
        join_none
        #1ns;
        race_adapter.release_configure(TLPQ_HOST);
        wait (first_done && second_done);
        if (race_adapter.configure_count[host_key] != 2 ||
            race_adapter.configured_base[host_key] != newer_base ||
            race_adapter.enable_count[host_key] != 0)
            `uvm_error("TLPQ_CONFIGURE_CONFIGURE_RACE",
                       "older configure completed after the newer lifecycle")
        race_adapter.publish(
            GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0000_001f);
        if (race_adapter.enable_count[host_key] != 1)
            `uvm_error("TLPQ_CONFIGURE_CONFIGURE_ARM",
                       "newer configure did not own the sole initial arm")
    endtask

    task check_publish_reconfigure_barrier();
        tlpq_mock_adapter race_adapter;
        tlpq_env_cfg race_cfg;
        bit publish_done;
        bit configure_done;
        int host_key;
        gq_addr_t newer_base;
        string expected_trace[$];

        host_key = int'(TLPQ_HOST);
        newer_base = HOST_BASE + 64'h0000_0000_0000_4000;
        publish_done = 0;
        configure_done = 0;
        make_host_fixture("publish_reconfigure", race_adapter, race_cfg);
        race_adapter.configure_queue(
            GQ_RX, TLPQ_HOST_QUEUE_ID, HOST_BASE, 32, 16);
        race_adapter.clear_trace(TLPQ_HOST);
        race_adapter.block_next_publish(TLPQ_HOST);
        fork
            begin
                race_adapter.publish(
                    GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0000_001f);
                publish_done = 1;
            end
        join_none
        race_adapter.publish_entered[host_key].wait_on();
        fork
            begin
                race_adapter.configure_queue(
                    GQ_RX, TLPQ_HOST_QUEUE_ID, newer_base, 32, 16);
                configure_done = 1;
            end
        join_none
        #1ns;
        race_adapter.release_publish(TLPQ_HOST);
        wait (publish_done && configure_done);

        expected_trace.push_back("PUBLISH(channel=HOST,tail=31)");
        expected_trace.push_back("RESET(channel=HOST)");
        expected_trace.push_back($sformatf(
            {"CONFIGURE(channel=HOST,base=0x%016h,depth=32,size=16,",
             "host_id=0x1,bdf=0x0100,msix=0x0011,valid=1)"},
            newer_base));
        if (race_adapter.trace[host_key] != expected_trace ||
            race_adapter.configured_base[host_key] != newer_base ||
            race_adapter.enable_count[host_key] != 0)
            `uvm_error("TLPQ_PUBLISH_RECONFIGURE_RACE",
                       "reconfigure did not order after stale publish")
        race_adapter.publish(
            GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0000_001f);
        if (race_adapter.enable_count[host_key] != 1)
            `uvm_error("TLPQ_PUBLISH_RECONFIGURE_ARM",
                       "new lifecycle did not retain exactly one arm")
    endtask

    task check_publish_disable_barrier();
        tlpq_mock_adapter race_adapter;
        tlpq_env_cfg race_cfg;
        bit publish_done;
        int host_key;
        string expected_trace[$];

        host_key = int'(TLPQ_HOST);
        publish_done = 0;
        make_host_fixture("publish_disable", race_adapter, race_cfg);
        race_adapter.configure_queue(
            GQ_RX, TLPQ_HOST_QUEUE_ID, HOST_BASE, 32, 16);
        race_adapter.clear_trace(TLPQ_HOST);
        race_adapter.block_next_publish(TLPQ_HOST);
        fork
            begin
                race_adapter.publish(
                    GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0000_001f);
                publish_done = 1;
            end
        join_none
        race_adapter.publish_entered[host_key].wait_on();
        race_adapter.disable_queue(GQ_RX, TLPQ_HOST_QUEUE_ID);
        wait (publish_done);
        expected_trace.push_back("DISABLE(channel=HOST)");
        if (race_adapter.trace[host_key] != expected_trace ||
            race_adapter.published_tails[host_key].size() != 0 ||
            race_adapter.enable_count[host_key] != 0)
            `uvm_error("TLPQ_PUBLISH_DISABLE_RACE",
                       "cancelled publish escaped disable")
    endtask

    task check_enable_disable_barrier();
        tlpq_mock_adapter race_adapter;
        tlpq_env_cfg race_cfg;
        bit publish_done;
        int host_key;
        string expected_trace[$];

        host_key = int'(TLPQ_HOST);
        publish_done = 0;
        make_host_fixture("enable_disable", race_adapter, race_cfg);
        race_adapter.configure_queue(
            GQ_RX, TLPQ_HOST_QUEUE_ID, HOST_BASE, 32, 16);
        race_adapter.clear_trace(TLPQ_HOST);
        race_adapter.block_next_enable(TLPQ_HOST);
        fork
            begin
                race_adapter.publish(
                    GQ_RX, TLPQ_HOST_QUEUE_ID, 32'h0000_001f);
                publish_done = 1;
            end
        join_none
        race_adapter.enable_entered[host_key].wait_on();
        race_adapter.disable_queue(GQ_RX, TLPQ_HOST_QUEUE_ID);
        wait (publish_done);
        expected_trace.push_back("PUBLISH(channel=HOST,tail=31)");
        expected_trace.push_back("DISABLE(channel=HOST)");
        if (race_adapter.trace[host_key] != expected_trace ||
            race_adapter.enable_count[host_key] != 0)
            `uvm_error("TLPQ_ENABLE_DISABLE_RACE",
                       "cancelled enable became visible after disable")
    endtask

    task check_dual_start_paths();
        tlpq_dual_rx_start_sequence same_handle_sequence;
        tlpq_dual_rx_start_sequence dual_sequence;
        string reason;
        gq_request host_request;
        gq_request switch_request;

        same_handle_sequence =
            tlpq_dual_rx_start_sequence::type_id::create(
                "same_handle_sequence");
        if (same_handle_sequence.configure(
                env_cfg, host_start_sequencer, host_start_sequencer,
                reason) || reason == "")
            `uvm_error("TLPQ_DUAL_SAME_SEQUENCER",
                       "dual RX start accepted one sequencer twice")

        dual_sequence = tlpq_dual_rx_start_sequence::type_id::create(
            "dual_sequence");
        if (!dual_sequence.configure(
                env_cfg, host_start_sequencer, switch_start_sequencer,
                reason)) begin
            `uvm_error("TLPQ_DUAL_CONFIGURE",
                       {"distinct sequencers rejected: ", reason})
            return;
        end
        dual_sequence.start(null);
        if (dual_sequence.host_response == null ||
            dual_sequence.switch_response == null ||
            dual_sequence.host_response == dual_sequence.switch_response ||
            dual_sequence.host_response.status != GQ_OK ||
            dual_sequence.switch_response.status != GQ_OK ||
            host_start_driver.captured_requests.size() != 1 ||
            switch_start_driver.captured_requests.size() != 1) begin
            `uvm_error("TLPQ_DUAL_RESPONSES",
                       "dual start did not report two independent responses")
            return;
        end

        host_request = host_start_driver.captured_requests[0];
        switch_request = switch_start_driver.captured_requests[0];
        if (host_request == null || switch_request == null ||
            host_request == switch_request ||
            host_request.kind != GQ_START_RX ||
            switch_request.kind != GQ_START_RX ||
            host_request.size() != 0 || switch_request.size() != 0 ||
            host_request.get_refill_profile() != host_profile ||
            switch_request.get_refill_profile() != switch_profile ||
            host_request.get_refill_profile() ==
                switch_request.get_refill_profile())
            `uvm_error("TLPQ_DUAL_REQUESTS",
                       "dual start shared descriptors/profile or queue path")
    endtask

    function bit driver_bytes_equal(input byte lhs[], input byte rhs[]);
        if (lhs.size() != rhs.size())
            return 0;
        foreach (lhs[i]) begin
            if (lhs[i] !== rhs[i])
                return 0;
        end
        return 1;
    endfunction

    function bit driver_dpu_bytes_equal(
        input bit [7:0] lhs[], input byte rhs[]);
        if (lhs.size() != rhs.size())
            return 0;
        foreach (lhs[i]) begin
            if (lhs[i] !== rhs[i])
                return 0;
        end
        return 1;
    endfunction

    function bit driver_report_matches(
        int unsigned index, uvm_severity severity,
        string id, string message);
        return index < driver_report_catcher.report_ids.size() &&
               driver_report_catcher.report_severities[index] == severity &&
               driver_report_catcher.report_ids[index] == id &&
               driver_report_catcher.report_messages[index] == message;
    endfunction

    function tlpq_rx_hw_cfg_t expected_driver_hw(int unsigned engine_id);
        case (engine_id)
            MAIN_HOST_ENGINE:
                return '{host_id:3'h1, bdf:16'h0100,
                         msix_index:13'h011, msix_valid:1'b1};
            MAIN_SWITCH_ENGINE:
                return '{host_id:3'h5, bdf:16'h0201,
                         msix_index:13'h122, msix_valid:1'b1};
            POLL_HOST_ENGINE:
                return '{host_id:3'h2, bdf:16'h0300,
                         msix_index:13'h033, msix_valid:1'b1};
            POLL_SWITCH_ENGINE:
                return '{host_id:3'h6, bdf:16'h0401,
                         msix_index:13'h144, msix_valid:1'b1};
            GOLDEN_HOST_ENGINE:
                return '{host_id:3'h4, bdf:16'h0600,
                         msix_index:13'h066, msix_valid:1'b1};
            default:
                return '{host_id:3'h3, bdf:16'h0500,
                         msix_index:13'h055, msix_valid:1'b1};
        endcase
    endfunction

    function void check_driver_observation(
        tlpq_driver_observation observation,
        input byte expected_bytes[],
        tlpq_route_metadata_t expected_metadata,
        string label);
        if (observation == null ||
            !driver_bytes_equal(observation.dpu_bytes, expected_bytes) ||
            observation.flags !=
                (TLPQ_DESC_AVAIL | TLPQ_DESC_USED) ||
            observation.buf_len != expected_bytes.size() ||
            observation.metadata != expected_metadata ||
            observation.owned_allocation_count != 1 ||
            observation.decoded_kind != TLP_MEM_RD ||
            observation.decoded_fmt != FMT_4DW_NO_DATA ||
            observation.decoded_type != TLP_TYPE_MEM_RD ||
            observation.decoded_length != 10'd2 ||
            observation.decoded_requester != 16'h5678 ||
            observation.decoded_tag != 8'h9a ||
            observation.decoded_addr != 64'h1122_3344_5566_7780)
            `uvm_fatal("TLPQ_DRIVER_CALLBACK", {label,
                       " callback bytes/decode/metadata/ownership diverged"})
    endfunction

    function void check_initial_descriptor(
        int unsigned engine_id, gq_logical_seq_t logical_seq,
        ref int descriptor_ids[int], ref gq_addr_t buffer_addresses[$]);
        gq_desc_base base_desc;
        tlpq_rx_desc desc;
        byte raw[];

        base_desc = driver_engines[engine_id].get_outstanding(logical_seq);
        if (!$cast(desc, base_desc) || desc == null)
            `uvm_fatal("TLPQ_DRIVER_INITIAL_DESC", $sformatf(
                "engine %0d sequence %0d is not a TLPQ descriptor",
                engine_id, logical_seq))
        dut.read_slot(driver_engines[engine_id], logical_seq, raw);
        if (raw.size() != 16 || raw[0] != 8'h01 || raw[1] != 8'h00 ||
            raw[2] != 8'h80 || raw[3] != 8'h00 ||
            raw[12] != 8'h00 || raw[13] != 8'h00 ||
            raw[14] != 8'h00 || raw[15] != 8'h00 ||
            dut.decode_buffer_address(raw) != desc.buf_addr ||
            desc.flags != TLPQ_DESC_AVAIL ||
            desc.buf_len != TLPQ_BUFFER_BYTES ||
            desc.owned_allocation_count() != 1 ||
            desc.buf_addr == 0 || desc.buf_addr == '1 ||
            mem.allocation_size(desc.buf_addr) != TLPQ_BUFFER_BYTES ||
            mem.allocation_generation(desc.buf_addr) == 0 ||
            descriptor_ids.exists(desc.get_inst_id()))
            `uvm_fatal("TLPQ_DRIVER_INITIAL_DESC", $sformatf(
                "engine %0d sequence %0d initial descriptor diverged",
                engine_id, logical_seq))
        foreach (buffer_addresses[i]) begin
            if (buffer_addresses[i] == desc.buf_addr)
                `uvm_fatal("TLPQ_DRIVER_INITIAL_DESC", $sformatf(
                    "engine %0d reused initial buffer 0x%016h",
                    engine_id, desc.buf_addr))
        end
        descriptor_ids[desc.get_inst_id()] = 1;
        buffer_addresses.push_back(desc.buf_addr);
    endfunction

    function void record_retired_allocation(
        tlpq_rx_desc retired_desc,
        gq_addr_t retired_addr,
        int unsigned retired_generation,
        string label);
        int descriptor_id;

        if (retired_desc == null || retired_desc.buf_addr != retired_addr ||
            retired_generation == 0)
            `uvm_fatal("TLPQ_DRIVER_RETIRED_TRACKING", {label,
                       " did not identify one live retired allocation"})
        descriptor_id = retired_desc.get_inst_id();
        if (retired_descriptor_ids.exists(descriptor_id))
            `uvm_fatal("TLPQ_DRIVER_RETIRED_TRACKING", {label,
                       " attempted to retire one descriptor object twice"})
        if (retired_generation_by_addr.exists(retired_addr) &&
            retired_generation <=
                retired_generation_by_addr[retired_addr])
            `uvm_fatal("TLPQ_DRIVER_RETIRED_TRACKING", {label,
                       " reused a retired address without a new allocation"})
        retired_descriptor_ids[descriptor_id] = 1;
        retired_generation_by_addr[retired_addr] = retired_generation;
    endfunction

    function void check_refill_replacement(
        int unsigned engine_id,
        gq_logical_seq_t replacement_seq,
        tlpq_rx_desc retired_desc,
        gq_addr_t retired_addr,
        int unsigned retired_free_before,
        gq_addr_t expected_ring_base,
        int unsigned expected_slot_index,
        string label);
        tlpq_rx_desc replacement;
        tlpq_rx_desc live_desc;
        byte raw[];
        gq_addr_t ring_buffer_addr;
        gq_addr_t expected_slot_addr;
        int unsigned replacement_generation;
        int unsigned ring_live_matches;
        int unsigned actual_slot_index;

        if (!$cast(replacement,
                   driver_engines[engine_id].get_outstanding(
                       replacement_seq)) ||
            replacement == null || replacement == retired_desc ||
            retired_descriptor_ids.exists(replacement.get_inst_id()) ||
            replacement.owned_allocation_count() != 1 ||
            replacement.buf_len != 128 ||
            replacement.flags != TLPQ_DESC_AVAIL ||
            replacement.metadata != '0 ||
            mem.allocation_size(replacement.buf_addr) != 128 ||
            replacement.buf_addr == 0 || replacement.buf_addr == '1 ||
            mem.free_count(retired_addr) != retired_free_before + 1)
            `uvm_fatal("TLPQ_DRIVER_REPLACEMENT", {label,
                       " was not a fresh 128-byte ownership with one retire"})

        replacement_generation =
            mem.allocation_generation(replacement.buf_addr);
        if (replacement_generation == 0 ||
            (retired_generation_by_addr.exists(replacement.buf_addr) &&
             replacement_generation <=
                retired_generation_by_addr[replacement.buf_addr]))
            `uvm_fatal("TLPQ_DRIVER_REPLACEMENT_GENERATION", {label,
                       " reused any retired address without generation advance"})

        actual_slot_index = int'(replacement_seq % TLPQ_DEPTH);
        expected_slot_addr = expected_ring_base +
            (expected_slot_index * TLPQ_DESC_BYTES);
        if (driver_engines[engine_id].ring_base() != expected_ring_base ||
            actual_slot_index != expected_slot_index ||
            expected_slot_addr != driver_engines[engine_id].ring_base() +
                (actual_slot_index * TLPQ_DESC_BYTES))
            `uvm_fatal("TLPQ_DRIVER_REPLACEMENT_SLOT", $sformatf(
                "%s logical sequence %0d did not map to ring 0x%016h slot %0d",
                label, replacement_seq, expected_ring_base,
                expected_slot_index))

        // Read the actual DUT-visible ring slot. Expected bytes are derived
        // literally here and never use the descriptor pack/serialize path.
        dut.read_slot(driver_engines[engine_id], replacement_seq, raw);
        ring_buffer_addr = 0;
        if (raw.size() == TLPQ_DESC_BYTES) begin
            for (int unsigned i = 0; i < 8; i++)
                ring_buffer_addr[(i * 8) +: 8] = raw[4 + i];
        end
        if (raw.size() != 16 ||
            raw[0] !== 8'h01 || raw[1] !== 8'h00 ||
            raw[2] !== 8'h80 || raw[3] !== 8'h00 ||
            raw[12] !== 8'h00 || raw[13] !== 8'h00 ||
            raw[14] !== 8'h00 || raw[15] !== 8'h00 ||
            ring_buffer_addr != replacement.buf_addr)
            `uvm_fatal("TLPQ_DRIVER_REPLACEMENT_RING", $sformatf(
                {"%s logical sequence %0d physical slot %0d at 0x%016h ",
                 "did not contain literal available 128-byte descriptor"},
                label, replacement_seq, expected_slot_index,
                expected_slot_addr))
        for (int unsigned i = 0; i < 8; i++) begin
            if (raw[4 + i] !== replacement.buf_addr[(i * 8) +: 8])
                `uvm_fatal("TLPQ_DRIVER_REPLACEMENT_RING", $sformatf(
                    "%s stable address byte %0d diverged", label, i))
        end

        ring_live_matches = 0;
        for (int unsigned live_engine = 0;
             live_engine < DRIVER_ENGINE_COUNT; live_engine++) begin
            if (!driver_engines.exists(live_engine) ||
                driver_engines[live_engine] == null ||
                driver_engines[live_engine].ring_base() == 0)
                continue;
            for (gq_logical_seq_t live_seq =
                     driver_engines[live_engine].head_seq();
                 live_seq < driver_engines[live_engine].tail_seq();
                 live_seq++) begin
                if (!$cast(live_desc,
                           driver_engines[live_engine].get_outstanding(
                               live_seq)) || live_desc == null)
                    `uvm_fatal("TLPQ_DRIVER_LIVE_OWNERSHIP", $sformatf(
                        "%s found a non-TLPQ live descriptor at engine %0d sequence %0d",
                        label, live_engine, live_seq))
                if (live_desc.buf_addr == ring_buffer_addr)
                    ring_live_matches++;
            end
        end
        if (ring_live_matches != 1)
            `uvm_fatal("TLPQ_DRIVER_LIVE_ALIAS", $sformatf(
                "%s ring buffer 0x%016h is referenced by %0d live descriptors",
                label, ring_buffer_addr, ring_live_matches))
    endfunction

    task start_driver_engine(int unsigned engine_id);
        tlpq_channel_e channel;
        tlpq_rx_hw_cfg_t expected_hw;
        tlpq_mock_adapter harness_adapter;
        gq_request request;
        gq_response response;
        string expected_trace[$];
        string channel_string;
        int channel_key;
        int descriptor_ids[int];
        gq_addr_t buffer_addresses[$];

        channel = driver_channel(engine_id);
        channel_key = int'(channel);
        channel_string = channel == TLPQ_HOST ? "HOST" : "SWITCH";
        expected_hw = expected_driver_hw(engine_id);
        harness_adapter =
            driver_adapters[driver_adapter_slot(engine_id)];
        driver_engines[engine_id].initialize();
        if (!driver_engines[engine_id].is_ready() ||
            harness_adapter.reset_count[channel_key] != 1 ||
            harness_adapter.configure_count[channel_key] != 1 ||
            harness_adapter.enable_count.exists(channel_key) ||
            harness_adapter.configured_depth[channel_key] != 32 ||
            harness_adapter.configured_desc_size[channel_key] != 16 ||
            harness_adapter.configured_hw_cfg[channel_key] != expected_hw)
            `uvm_fatal("TLPQ_DRIVER_INITIAL_SETUP", $sformatf(
                "engine %0d configure/reset/deferred-enable diverged",
                engine_id))

        request = gq_request::type_id::create(
            $sformatf("driver_%0d_start_request", engine_id));
        request.kind = GQ_START_RX;
        request.set_refill_profile(driver_profiles[engine_id]);
        driver_engines[engine_id].start_rx(request, response);
        if (response == null || response.status != GQ_OK ||
            response.committed_count != 31 ||
            driver_engines[engine_id].head_seq() != 0 ||
            driver_engines[engine_id].tail_seq() != 31 ||
            driver_engines[engine_id].outstanding_count() != 31 ||
            harness_adapter.published_tails[channel_key].size() != 1 ||
            harness_adapter.published_tails[channel_key][0] != 16'h001f ||
            harness_adapter.enable_count[channel_key] != 1)
            `uvm_fatal("TLPQ_DRIVER_INITIAL_POST", $sformatf(
                "engine %0d did not post 31 descriptors and tail 0x001f",
                engine_id))

        expected_trace.push_back($sformatf(
            "RESET(channel=%s)", channel_string));
        expected_trace.push_back($sformatf(
            {"CONFIGURE(channel=%s,base=0x%016h,depth=32,size=16,",
             "host_id=0x%01h,bdf=0x%04h,msix=0x%04h,valid=%0b)"},
            channel_string, driver_engines[engine_id].ring_base(),
            expected_hw.host_id, expected_hw.bdf, expected_hw.msix_index,
            expected_hw.msix_valid));
        expected_trace.push_back($sformatf(
            "PUBLISH(channel=%s,tail=31)", channel_string));
        expected_trace.push_back($sformatf(
            "ENABLE(channel=%s)", channel_string));
        if (harness_adapter.trace[channel_key] != expected_trace)
            `uvm_fatal("TLPQ_DRIVER_INITIAL_TRACE", $sformatf(
                "engine %0d setup trace diverged", engine_id))

        for (gq_logical_seq_t seq = 0; seq < 31; seq++)
            check_initial_descriptor(engine_id, seq,
                                     descriptor_ids, buffer_addresses);
    endtask

    task start_driver_worker(int unsigned engine_id);
        automatic int unsigned worker_engine = engine_id;

        if (driver_worker_started[engine_id])
            return;
        driver_worker_started[engine_id] = 1;
        fork
            begin
                driver_engines[worker_engine].run_completion_worker();
                driver_worker_returned[worker_engine] = 1;
            end
        join_none
    endtask

    task wait_for_driver_callbacks(
        int unsigned engine_id, int unsigned expected_count, string label);
        while (driver_collectors[engine_id].observations.size() <
               expected_count) begin
            driver_collectors[engine_id].observation_event.reset();
            if (driver_collectors[engine_id].observations.size() <
                expected_count)
                driver_collectors[engine_id].observation_event.wait_on();
        end
        if (driver_collectors[engine_id].observations.size() !=
            expected_count)
            `uvm_fatal("TLPQ_DRIVER_CALLBACK", {label,
                       " observed an unexpected callback count"})
    endtask

    task wait_for_driver_publishes(
        int unsigned engine_id, int unsigned expected_count, string label);
        tlpq_channel_e channel;
        tlpq_mock_adapter harness_adapter;
        int channel_key;

        channel = driver_channel(engine_id);
        channel_key = int'(channel);
        harness_adapter = driver_adapters[driver_adapter_slot(engine_id)];
        while (harness_adapter.published_tails[channel_key].size() <
               expected_count) begin
            harness_adapter.publish_events[channel_key].reset();
            if (harness_adapter.published_tails[channel_key].size() <
                expected_count)
                harness_adapter.publish_events[channel_key].wait_on();
        end
        if (harness_adapter.published_tails[channel_key].size() !=
            expected_count)
            `uvm_fatal("TLPQ_DRIVER_PUBLISH", {label,
                       " observed an unexpected publish count"})
    endtask

    task wait_for_driver_queries(
        int unsigned engine_id, int unsigned expected_count, string label);
        while (driver_completions[engine_id].query_times.size() <
               expected_count) begin
            driver_completions[engine_id].query_event.reset();
            if (driver_completions[engine_id].query_times.size() <
                expected_count)
                driver_completions[engine_id].query_event.wait_on();
        end
        if (driver_completions[engine_id].query_times.size() !=
            expected_count)
            `uvm_fatal("TLPQ_DRIVER_QUERY", {label,
                       " observed an unexpected query count"})
    endtask

    task wait_for_driver_irq_waits(
        int unsigned engine_id, int unsigned expected_count, string label);
        tlpq_channel_e channel;
        tlpq_mock_adapter harness_adapter;
        int channel_key;

        channel = driver_channel(engine_id);
        channel_key = int'(channel);
        harness_adapter = driver_adapters[driver_adapter_slot(engine_id)];
        while (harness_adapter.wait_irq_count[channel_key] < expected_count) begin
            harness_adapter.irq_wait_events[channel_key].reset();
            if (harness_adapter.wait_irq_count[channel_key] < expected_count)
                harness_adapter.irq_wait_events[channel_key].wait_on();
        end
        if (harness_adapter.wait_irq_count[channel_key] != expected_count)
            `uvm_fatal("TLPQ_DRIVER_IRQ_WAIT", {label,
                       " observed an unexpected IRQ wait count"})
    endtask

    function void check_golden_snapshot(
        int unsigned vector_index, string label,
        tlpq_rx_desc snapshot, input byte expected_bytes[],
        tlpq_route_metadata_t expected_metadata,
        gq_addr_t expected_buf_addr);
        pcie_tl_cfg_tlp cfg_tlp;
        pcie_tl_mem_tlp mem_tlp;
        pcie_tl_msg_tlp msg_tlp;
        pcie_tl_cpl_tlp cpl_tlp;

        if (snapshot == null || snapshot.mem != null ||
            snapshot.owned_allocation_count() != 0 ||
            snapshot.flags != (TLPQ_DESC_AVAIL | TLPQ_DESC_USED) ||
            snapshot.buf_len != expected_bytes.size() ||
            snapshot.buf_addr != expected_buf_addr ||
            snapshot.metadata != expected_metadata ||
            !driver_dpu_bytes_equal(snapshot.dpu_bytes, expected_bytes) ||
            snapshot.decoded_tlp == null)
            `uvm_fatal("TLPQ_GOLDEN_SNAPSHOT", {label,
                       " detached raw descriptor snapshot diverged"})

        case (vector_index)
            0: begin
                if (!$cast(cfg_tlp, snapshot.decoded_tlp) ||
                    cfg_tlp.kind != TLP_CFG_RD0 ||
                    cfg_tlp.fmt != FMT_3DW_NO_DATA ||
                    cfg_tlp.type_f != TLP_TYPE_CFG_RD0 ||
                    cfg_tlp.length != 10'd1 ||
                    cfg_tlp.requester_id != 16'h1234 ||
                    cfg_tlp.tag[7:0] != 8'h56 || cfg_tlp.at != 2'b10 ||
                    cfg_tlp.completer_id != 16'habcd ||
                    cfg_tlp.reg_num != 10'h012 ||
                    cfg_tlp.first_be != 4'hf || cfg_tlp.payload.size() != 0)
                    `uvm_fatal("TLPQ_GOLDEN_CFG_RD0", {label,
                               " Configuration Read Type 0 fields diverged"})
            end
            1: begin
                if (!$cast(cfg_tlp, snapshot.decoded_tlp) ||
                    cfg_tlp.kind != TLP_CFG_WR0 ||
                    cfg_tlp.fmt != FMT_3DW_WITH_DATA ||
                    cfg_tlp.type_f != TLP_TYPE_CFG_WR0 ||
                    cfg_tlp.length != 10'd1 ||
                    cfg_tlp.requester_id != 16'h2345 ||
                    cfg_tlp.tag[7:0] != 8'h67 ||
                    cfg_tlp.completer_id != 16'hbcde ||
                    cfg_tlp.reg_num != 10'h1ab ||
                    cfg_tlp.first_be != 4'ha ||
                    cfg_tlp.payload.size() != 4 ||
                    cfg_tlp.payload[0] != 8'h11 ||
                    cfg_tlp.payload[1] != 8'h22 ||
                    cfg_tlp.payload[2] != 8'h33 ||
                    cfg_tlp.payload[3] != 8'h44)
                    `uvm_fatal("TLPQ_GOLDEN_CFG_WR0", {label,
                               " Configuration Write Type 0 fields diverged"})
            end
            2: begin
                if (!$cast(cfg_tlp, snapshot.decoded_tlp) ||
                    cfg_tlp.kind != TLP_CFG_RD1 ||
                    cfg_tlp.fmt != FMT_3DW_NO_DATA ||
                    cfg_tlp.type_f != TLP_TYPE_CFG_RD1 ||
                    cfg_tlp.length != 10'd1 ||
                    cfg_tlp.requester_id != 16'h3456 ||
                    cfg_tlp.tag[7:0] != 8'h78 ||
                    cfg_tlp.completer_id != 16'hcdef ||
                    cfg_tlp.reg_num != 10'h02a ||
                    cfg_tlp.first_be != 4'h3 || cfg_tlp.payload.size() != 0)
                    `uvm_fatal("TLPQ_GOLDEN_CFG_RD1", {label,
                               " Configuration Read Type 1 fields diverged"})
            end
            3: begin
                if (!$cast(cfg_tlp, snapshot.decoded_tlp) ||
                    cfg_tlp.kind != TLP_CFG_WR1 ||
                    cfg_tlp.fmt != FMT_3DW_WITH_DATA ||
                    cfg_tlp.type_f != TLP_TYPE_CFG_WR1 ||
                    cfg_tlp.length != 10'd1 ||
                    cfg_tlp.requester_id != 16'h4567 ||
                    cfg_tlp.tag[7:0] != 8'h89 ||
                    cfg_tlp.completer_id != 16'hd0e1 ||
                    cfg_tlp.reg_num != 10'h155 ||
                    cfg_tlp.first_be != 4'h5 ||
                    cfg_tlp.payload.size() != 4 ||
                    cfg_tlp.payload[0] != 8'ha1 ||
                    cfg_tlp.payload[1] != 8'hb2 ||
                    cfg_tlp.payload[2] != 8'hc3 ||
                    cfg_tlp.payload[3] != 8'hd4)
                    `uvm_fatal("TLPQ_GOLDEN_CFG_WR1", {label,
                               " Configuration Write Type 1 fields diverged"})
            end
            4: begin
                if (!$cast(mem_tlp, snapshot.decoded_tlp) ||
                    mem_tlp.kind != TLP_MEM_RD ||
                    mem_tlp.fmt != FMT_4DW_NO_DATA ||
                    mem_tlp.type_f != TLP_TYPE_MEM_RD ||
                    mem_tlp.length != 10'd2 ||
                    mem_tlp.requester_id != 16'h5678 ||
                    mem_tlp.tag[7:0] != 8'h9a ||
                    mem_tlp.addr != 64'h1122_3344_5566_7780 ||
                    !mem_tlp.is_64bit || mem_tlp.first_be != 4'h3 ||
                    mem_tlp.last_be != 4'hc || mem_tlp.payload.size() != 0)
                    `uvm_fatal("TLPQ_GOLDEN_MEM_RD", {label,
                               " Memory Read fields diverged"})
            end
            5: begin
                if (!$cast(mem_tlp, snapshot.decoded_tlp) ||
                    mem_tlp.kind != TLP_MEM_WR ||
                    mem_tlp.fmt != FMT_3DW_WITH_DATA ||
                    mem_tlp.type_f != TLP_TYPE_MEM_WR ||
                    mem_tlp.length != 10'd2 ||
                    mem_tlp.requester_id != 16'h6789 ||
                    mem_tlp.tag[7:0] != 8'hab ||
                    mem_tlp.addr != 64'h0000_0000_89ab_cdf0 ||
                    mem_tlp.is_64bit || mem_tlp.first_be != 4'h7 ||
                    mem_tlp.last_be != 4'he || mem_tlp.payload.size() != 8 ||
                    mem_tlp.payload[0] != 8'hde ||
                    mem_tlp.payload[1] != 8'had ||
                    mem_tlp.payload[2] != 8'hbe ||
                    mem_tlp.payload[3] != 8'hef ||
                    mem_tlp.payload[4] != 8'h01 ||
                    mem_tlp.payload[5] != 8'h23 ||
                    mem_tlp.payload[6] != 8'h45 ||
                    mem_tlp.payload[7] != 8'h67)
                    `uvm_fatal("TLPQ_GOLDEN_MEM_WR", {label,
                               " Memory Write fields diverged"})
            end
            6: begin
                if (!$cast(msg_tlp, snapshot.decoded_tlp) ||
                    msg_tlp.kind != TLP_MSGD ||
                    msg_tlp.fmt != FMT_4DW_WITH_DATA ||
                    msg_tlp.type_f != TLP_TYPE_MSG_ID ||
                    msg_tlp.length != 10'd2 ||
                    msg_tlp.requester_id != 16'h789a ||
                    msg_tlp.tag[7:0] != 8'hbc ||
                    msg_tlp.msg_code != MSG_VENDOR_TYPE0 ||
                    msg_tlp.msg_addr != 64'hcafe_babe_0bad_f00d ||
                    msg_tlp.payload.size() != 8 ||
                    msg_tlp.payload[0] != 8'h10 ||
                    msg_tlp.payload[1] != 8'h32 ||
                    msg_tlp.payload[2] != 8'h54 ||
                    msg_tlp.payload[3] != 8'h76 ||
                    msg_tlp.payload[4] != 8'h98 ||
                    msg_tlp.payload[5] != 8'hba ||
                    msg_tlp.payload[6] != 8'hdc ||
                    msg_tlp.payload[7] != 8'hfe)
                    `uvm_fatal("TLPQ_GOLDEN_MSGD", {label,
                               " Message with Data fields diverged"})
            end
            7: begin
                if (!$cast(cpl_tlp, snapshot.decoded_tlp) ||
                    cpl_tlp.kind != TLP_CPL ||
                    cpl_tlp.fmt != FMT_3DW_NO_DATA ||
                    cpl_tlp.type_f != TLP_TYPE_CPL ||
                    cpl_tlp.length != 10'd0 ||
                    cpl_tlp.completer_id != 16'h89ab ||
                    cpl_tlp.cpl_status != CPL_STATUS_UR || !cpl_tlp.bcm ||
                    cpl_tlp.byte_count != 12'h234 ||
                    cpl_tlp.lower_addr != 7'h5a ||
                    cpl_tlp.payload.size() != 0 ||
                    // Raw DW2 carries requester/tag 0x1357/0xa6.  The pinned
                    // codec incorrectly returns DW1 0x89ab/0x32 instead.
                    cpl_tlp.requester_id != 16'h89ab ||
                    cpl_tlp.tag[7:0] != 8'h32 ||
                    cpl_tlp.requester_id == 16'h1357 ||
                    cpl_tlp.tag[7:0] == 8'ha6)
                    `uvm_fatal("TLPQ_GOLDEN_CPL_RESIDUAL", {label,
                               " did not expose the pinned Completion defect"})
            end
            8: begin
                if (!$cast(cpl_tlp, snapshot.decoded_tlp) ||
                    cpl_tlp.kind != TLP_CPLD ||
                    cpl_tlp.fmt != FMT_3DW_WITH_DATA ||
                    cpl_tlp.type_f != TLP_TYPE_CPL ||
                    cpl_tlp.length != 10'd1 ||
                    cpl_tlp.completer_id != 16'h9abc ||
                    cpl_tlp.cpl_status != CPL_STATUS_SC || cpl_tlp.bcm ||
                    cpl_tlp.byte_count != 12'h004 ||
                    cpl_tlp.lower_addr != 7'h3c ||
                    cpl_tlp.payload.size() != 4 ||
                    cpl_tlp.payload[0] != 8'hfe ||
                    cpl_tlp.payload[1] != 8'hdc ||
                    cpl_tlp.payload[2] != 8'hba ||
                    cpl_tlp.payload[3] != 8'h98 ||
                    // Raw DW2 carries requester/tag 0x2468/0xb7; pinned
                    // decode exposes the unrelated DW1 0x9abc/0x00 values.
                    cpl_tlp.requester_id != 16'h9abc ||
                    cpl_tlp.tag[7:0] != 8'h00 ||
                    cpl_tlp.requester_id == 16'h2468 ||
                    cpl_tlp.tag[7:0] == 8'hb7)
                    `uvm_fatal("TLPQ_GOLDEN_CPLD_RESIDUAL", {label,
                               " did not expose the pinned CplD defect"})
            end
            default:
                `uvm_fatal("TLPQ_GOLDEN_INDEX", "unknown golden vector")
        endcase
    endfunction

    task run_golden_full_chain_scenario();
        byte vectors[9][];
        string labels[9];
        tlpq_route_metadata_t metadata[9];
        tlpq_rx_desc retired[9];
        gq_addr_t retired_addr[9];
        int unsigned retired_free_before[9];
        gq_addr_t live_addr[$];
        int unsigned live_free_before[$];
        tlpq_rx_desc live_desc;
        tlpq_rx_desc snapshot;
        gq_addr_t ring_addr;
        int unsigned ring_free_before;
        int unsigned completion_write_before;
        int unsigned allocation_before;
        int host_key;
        time irq_time;

        // Every byte array is an independent literal fixture.  No bridge,
        // codec, pack(), or production serializer creates the DMA input.
        labels[0] = "Configuration Read Type 0";
        vectors[0] = '{8'h00,8'h00,8'h00,8'h00,
                       8'h48,8'h00,8'hcd,8'hab,
                       8'h0f,8'h56,8'h34,8'h12,
                       8'h01,8'h08,8'h00,8'h04};
        labels[1] = "Configuration Write Type 0";
        vectors[1] = '{8'h00,8'h00,8'h00,8'h00,
                       8'hac,8'h06,8'hde,8'hbc,
                       8'h0a,8'h67,8'h45,8'h23,
                       8'h01,8'h00,8'h00,8'h44,
                       8'h44,8'h33,8'h22,8'h11};
        labels[2] = "Configuration Read Type 1";
        vectors[2] = '{8'h00,8'h00,8'h00,8'h00,
                       8'ha8,8'h00,8'hef,8'hcd,
                       8'h03,8'h78,8'h56,8'h34,
                       8'h01,8'h00,8'h00,8'h05};
        labels[3] = "Configuration Write Type 1";
        vectors[3] = '{8'h00,8'h00,8'h00,8'h00,
                       8'h54,8'h05,8'he1,8'hd0,
                       8'h05,8'h89,8'h67,8'h45,
                       8'h01,8'h00,8'h00,8'h45,
                       8'hd4,8'hc3,8'hb2,8'ha1};
        labels[4] = "Memory Read";
        vectors[4] = '{8'h80,8'h77,8'h66,8'h55,
                       8'h44,8'h33,8'h22,8'h11,
                       8'hc3,8'h9a,8'h78,8'h56,
                       8'h02,8'h00,8'h00,8'h20};
        labels[5] = "Memory Write";
        vectors[5] = '{8'h00,8'h00,8'h00,8'h00,
                       8'hf0,8'hcd,8'hab,8'h89,
                       8'he7,8'hab,8'h89,8'h67,
                       8'h02,8'h00,8'h00,8'h40,
                       8'hef,8'hbe,8'had,8'hde,
                       8'h67,8'h45,8'h23,8'h01};
        labels[6] = "Message with Data";
        vectors[6] = '{8'h0d,8'hf0,8'had,8'h0b,
                       8'hbe,8'hba,8'hfe,8'hca,
                       8'h7e,8'hbc,8'h9a,8'h78,
                       8'h02,8'h00,8'h00,8'h72,
                       8'h76,8'h54,8'h32,8'h10,
                       8'hfe,8'hdc,8'hba,8'h98};
        labels[7] = "Completion";
        vectors[7] = '{8'h00,8'h00,8'h00,8'h00,
                       8'h5a,8'ha6,8'h57,8'h13,
                       8'h34,8'h32,8'hab,8'h89,
                       8'h00,8'h00,8'h00,8'h0a};
        labels[8] = "Completion with Data";
        vectors[8] = '{8'h00,8'h00,8'h00,8'h00,
                       8'h3c,8'hb7,8'h68,8'h24,
                       8'h04,8'h00,8'hbc,8'h9a,
                       8'h01,8'h00,8'h00,8'h4a,
                       8'h98,8'hba,8'hdc,8'hfe};

        for (int unsigned i = 0; i < 9; i++) begin
            metadata[i] = '{host_id:4'(i), tlp_type:4'(i + 1),
                            primary_bus:8'(8'h80 + i),
                            secondary_bus:8'(8'h90 + i),
                            subordinate_bus:8'(8'ha0 + i)};
        end

        host_key = int'(TLPQ_HOST);
        start_driver_engine(GOLDEN_HOST_ENGINE);
        start_driver_worker(GOLDEN_HOST_ENGINE);
        wait_for_driver_irq_waits(GOLDEN_HOST_ENGINE, 1,
                                  "nine-vector batch");
        completion_write_before = dut.completion_write_count;
        allocation_before = mem.allocation_count_for_size(TLPQ_BUFFER_BYTES);
        for (int unsigned i = 0; i < 9; i++) begin
            if (!$cast(retired[i],
                       driver_engines[GOLDEN_HOST_ENGINE].get_outstanding(i)) ||
                retired[i] == null || retired[i].owned_allocation_count() != 1 ||
                mem.allocation_size(retired[i].buf_addr) !=
                    TLPQ_BUFFER_BYTES)
                `uvm_fatal("TLPQ_GOLDEN_OWNERSHIP", {labels[i],
                           " did not begin in a real owned 128-byte buffer"})
            retired_addr[i] = retired[i].buf_addr;
            retired_free_before[i] = mem.free_count(retired_addr[i]);
            if (!dut.complete_slot(driver_engines[GOLDEN_HOST_ENGINE], i,
                                   vectors[i], vectors[i].size(),
                                   metadata[i], -1))
                `uvm_fatal("TLPQ_GOLDEN_DMA", {labels[i],
                           " mock DMA completion failed"})
        end
        irq_time = $time;
        dut.trigger_irq(driver_adapters[GOLDEN_ADAPTER_SLOT], TLPQ_HOST);
        wait_for_driver_callbacks(GOLDEN_HOST_ENGINE, 9,
                                  "nine-vector batch");
        wait_for_driver_publishes(GOLDEN_HOST_ENGINE, 10,
                                  "nine-vector batch-one refill");
        if (dut.completion_write_count != completion_write_before + 9 ||
            driver_adapters[GOLDEN_ADAPTER_SLOT].ack_irq_count[host_key] != 1 ||
            driver_completions[GOLDEN_HOST_ENGINE].query_times.size() != 1 ||
            driver_completions[GOLDEN_HOST_ENGINE].query_times[0] != irq_time ||
            driver_completions[GOLDEN_HOST_ENGINE].ack_counts_at_query[0] != 1 ||
            driver_engines[GOLDEN_HOST_ENGINE].head_seq() != 9 ||
            driver_engines[GOLDEN_HOST_ENGINE].tail_seq() != 40 ||
            driver_engines[GOLDEN_HOST_ENGINE].outstanding_count() != 31 ||
            driver_collectors[GOLDEN_HOST_ENGINE].retained_snapshots.size()
                != 9 ||
            mem.allocation_count_for_size(TLPQ_BUFFER_BYTES) !=
                allocation_before + 9)
            `uvm_fatal("TLPQ_GOLDEN_CHAIN",
                       "nine literals did not traverse one real IRQ retirement")
        for (int unsigned i = 0; i < 9; i++) begin
            if (mem.free_count(retired_addr[i]) !=
                    retired_free_before[i] + 1 ||
                driver_adapters[GOLDEN_ADAPTER_SLOT].published_tails[
                    host_key][i + 1] != 16'h8000 + i)
                `uvm_fatal("TLPQ_GOLDEN_RETIRE", {labels[i],
                           " was not freed once and refilled singly"})
        end

        // Corrupt the retired source after callback; the callback clone must
        // remain byte- and object-independent through engine cleanup.
        retired[0].dpu_bytes[0] ^= 8'hff;
        retired[0].decoded_tlp.requester_id = 16'h0000;
        ring_addr = driver_engines[GOLDEN_HOST_ENGINE].ring_base();
        ring_free_before = mem.free_count(ring_addr);
        for (gq_logical_seq_t seq =
                 driver_engines[GOLDEN_HOST_ENGINE].head_seq();
             seq < driver_engines[GOLDEN_HOST_ENGINE].tail_seq(); seq++) begin
            if (!$cast(live_desc,
                       driver_engines[GOLDEN_HOST_ENGINE].get_outstanding(seq)) ||
                live_desc == null)
                `uvm_fatal("TLPQ_GOLDEN_CLEANUP",
                           "live replacement was not a TLPQ descriptor")
            live_addr.push_back(live_desc.buf_addr);
            live_free_before.push_back(mem.free_count(live_desc.buf_addr));
        end
        driver_engines[GOLDEN_HOST_ENGINE].cleanup();
        if (driver_engines[GOLDEN_HOST_ENGINE].ring_base() != 0 ||
            driver_engines[GOLDEN_HOST_ENGINE].outstanding_count() != 0 ||
            mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("TLPQ_GOLDEN_CLEANUP",
                       "golden engine cleanup did not release its ring once")
        foreach (live_addr[i]) begin
            if (mem.free_count(live_addr[i]) != live_free_before[i] + 1)
                `uvm_fatal("TLPQ_GOLDEN_CLEANUP",
                           "cleanup did not free every live buffer once")
        end
        driver_engines[GOLDEN_HOST_ENGINE].cleanup();
        if (mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("TLPQ_GOLDEN_CLEANUP",
                       "second cleanup double-freed the golden ring")
        foreach (live_addr[i]) begin
            if (mem.free_count(live_addr[i]) != live_free_before[i] + 1)
                `uvm_fatal("TLPQ_GOLDEN_CLEANUP",
                           "second cleanup double-freed a golden buffer")
        end

        for (int unsigned i = 0; i < 9; i++) begin
            snapshot = driver_collectors[GOLDEN_HOST_ENGINE].
                retained_snapshots[i];
            check_golden_snapshot(i, labels[i], snapshot, vectors[i],
                                  metadata[i], retired_addr[i]);
        end
        `uvm_info("TLPQ_COMPLETION_EXTERNAL_RESIDUAL",
            {"raw Cpl DW2 requester/tag=1357/a6 and CplD=2468/b7; ",
             "pinned decode exposes incorrect DW1 values 89ab/32 and 9abc/00"},
            UVM_LOW)
        `uvm_info("TLPQ_GOLDEN_FULL_CHAIN",
            {"nine independent literal DPU byte fixtures traversed owned ",
             "buffers, mock DMA, one IRQ, real GQ query/retirement, parse, ",
             "callback clone, batch-one refill, and cleanup"}, UVM_LOW)
    endtask

    task run_main_dual_ring_scenario();
        byte golden[] = '{8'h80, 8'h77, 8'h66, 8'h55,
                          8'h44, 8'h33, 8'h22, 8'h11,
                          8'hc3, 8'h9a, 8'h78, 8'h56,
                          8'h02, 8'h00, 8'h00, 8'h20};
        bit [15:0] host_batch_tails[4] = '{
            16'h001f, 16'h8000, 16'h8001, 16'h8002};
        bit [15:0] switch_batch_tails[3] = '{
            16'h001f, 16'h8000, 16'h8001};
        int unsigned host_replacement_slots[3] = '{31, 0, 1};
        int unsigned switch_replacement_slots[2] = '{31, 0};
        tlpq_route_metadata_t host_metadata[3];
        tlpq_route_metadata_t switch_metadata[2];
        tlpq_route_metadata_t simultaneous_host_metadata;
        tlpq_route_metadata_t simultaneous_switch_metadata;
        tlpq_route_metadata_t lost_metadata;
        tlpq_rx_desc host_retired[3];
        tlpq_rx_desc switch_retired[2];
        tlpq_rx_desc simultaneous_host_retired;
        tlpq_rx_desc simultaneous_switch_retired;
        tlpq_rx_desc lost_retired;
        gq_addr_t host_retired_addr[3];
        gq_addr_t switch_retired_addr[2];
        gq_addr_t simultaneous_host_addr;
        gq_addr_t simultaneous_switch_addr;
        gq_addr_t lost_addr;
        int unsigned host_retired_generation[3];
        int unsigned switch_retired_generation[2];
        int unsigned simultaneous_host_generation;
        int unsigned simultaneous_switch_generation;
        int unsigned lost_generation;
        int unsigned host_free_before[3];
        int unsigned switch_free_before[2];
        int unsigned simultaneous_host_free_before;
        int unsigned simultaneous_switch_free_before;
        int unsigned lost_free_before;
        int unsigned host_alloc_before;
        int unsigned switch_alloc_before;
        int unsigned simultaneous_alloc_before;
        int unsigned lost_alloc_before;
        int unsigned host_key;
        int unsigned switch_key;
        int unsigned wait_before;
        int unsigned ack_before;
        int unsigned query_before;
        int unsigned trigger_before;
        int unsigned callback_before;
        int unsigned publish_before;
        time host_irq_time;
        time switch_irq_time;
        time watchdog_wait_time;
        gq_desc_base replacement_base;
        tlpq_rx_desc replacement;
        bit replacement_matches_retired;

        host_key = int'(TLPQ_HOST);
        switch_key = int'(TLPQ_SWITCH);
        host_metadata[0] = '{host_id:4'h1, tlp_type:4'h2,
                             primary_bus:8'h10, secondary_bus:8'h20,
                             subordinate_bus:8'h30};
        host_metadata[1] = '{host_id:4'h2, tlp_type:4'h3,
                             primary_bus:8'h11, secondary_bus:8'h21,
                             subordinate_bus:8'h31};
        host_metadata[2] = '{host_id:4'h3, tlp_type:4'h4,
                             primary_bus:8'h12, secondary_bus:8'h22,
                             subordinate_bus:8'h32};
        switch_metadata[0] = '{host_id:4'h5, tlp_type:4'h6,
                               primary_bus:8'h40, secondary_bus:8'h50,
                               subordinate_bus:8'h60};
        switch_metadata[1] = '{host_id:4'h6, tlp_type:4'h7,
                               primary_bus:8'h41, secondary_bus:8'h51,
                               subordinate_bus:8'h61};
        simultaneous_host_metadata =
            '{host_id:4'h7, tlp_type:4'h8,
              primary_bus:8'h70, secondary_bus:8'h71,
              subordinate_bus:8'h72};
        simultaneous_switch_metadata =
            '{host_id:4'h8, tlp_type:4'h9,
              primary_bus:8'h80, secondary_bus:8'h81,
              subordinate_bus:8'h82};
        lost_metadata = '{host_id:4'h9, tlp_type:4'ha,
                          primary_bus:8'h90, secondary_bus:8'h91,
                          subordinate_bus:8'h92};

        if (driver_cfgs[MAIN_HOST_ENGINE].wait_mode != GQ_IRQ ||
            driver_cfgs[MAIN_SWITCH_ENGINE].wait_mode != GQ_IRQ ||
            driver_cfgs[MAIN_HOST_ENGINE].poll_policy != GQ_POLL_FIXED ||
            driver_cfgs[MAIN_SWITCH_ENGINE].poll_policy != GQ_POLL_FIXED ||
            driver_cfgs[MAIN_HOST_ENGINE].poll_min_interval != 10ns ||
            driver_cfgs[MAIN_HOST_ENGINE].poll_max_interval != 10ns ||
            driver_cfgs[MAIN_SWITCH_ENGINE].poll_min_interval != 10ns ||
            driver_cfgs[MAIN_SWITCH_ENGINE].poll_max_interval != 10ns ||
            driver_cfgs[MAIN_HOST_ENGINE].irq_watchdog_interval != 1us ||
            driver_cfgs[MAIN_SWITCH_ENGINE].irq_watchdog_interval != 1us)
            `uvm_fatal("TLPQ_DRIVER_IRQ_CFG",
                       "directed dual IRQ configuration diverged")

        start_driver_engine(MAIN_HOST_ENGINE);
        if (driver_engines[MAIN_HOST_ENGINE].ring_base() !=
                64'h0000_0001_e000_0000)
            `uvm_fatal("TLPQ_DRIVER_HOST_BASE",
                       "Host driver ring base broke the literal allocation map")
        start_driver_engine(MAIN_SWITCH_ENGINE);
        if (driver_engines[MAIN_SWITCH_ENGINE].ring_base() !=
                64'h0000_0001_e000_1180)
            `uvm_fatal("TLPQ_DRIVER_SWITCH_BASE",
                       "Switch driver ring base broke the literal allocation map")
        start_driver_worker(MAIN_HOST_ENGINE);
        start_driver_worker(MAIN_SWITCH_ENGINE);
        wait_for_driver_irq_waits(MAIN_HOST_ENGINE, 1, "Host batch");
        wait_for_driver_irq_waits(MAIN_SWITCH_ENGINE, 1, "Switch idle");

        host_alloc_before = mem.allocation_count_for_size(TLPQ_BUFFER_BYTES);
        for (int unsigned i = 0; i < 3; i++) begin
            if (!$cast(host_retired[i],
                       driver_engines[MAIN_HOST_ENGINE].get_outstanding(i)))
                `uvm_fatal("TLPQ_DRIVER_HOST_BATCH",
                           "Host retired handle was not a TLPQ descriptor")
            host_retired_addr[i] = host_retired[i].buf_addr;
            host_retired_generation[i] =
                mem.allocation_generation(host_retired_addr[i]);
            host_free_before[i] = mem.free_count(host_retired_addr[i]);
            record_retired_allocation(
                host_retired[i], host_retired_addr[i],
                host_retired_generation[i],
                $sformatf("Host batch retired %0d", i));
            if (!dut.complete_slot(driver_engines[MAIN_HOST_ENGINE], i,
                                   golden, 16, host_metadata[i], -1))
                `uvm_fatal("TLPQ_DRIVER_DUT",
                           "Host batch completion injection failed")
        end
        host_irq_time = $time;
        dut.trigger_irq(driver_adapters[MAIN_ADAPTER_SLOT], TLPQ_HOST);
        wait_for_driver_callbacks(MAIN_HOST_ENGINE, 3, "Host batch");
        wait_for_driver_publishes(MAIN_HOST_ENGINE, 4, "Host batch refill");
        if (driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[host_key] != 1 ||
            driver_completions[MAIN_HOST_ENGINE].query_times.size() != 1 ||
            driver_completions[MAIN_HOST_ENGINE].query_times[0] !=
                host_irq_time ||
            driver_completions[MAIN_HOST_ENGINE].ack_counts_at_query[0] != 1 ||
            driver_collectors[MAIN_SWITCH_ENGINE].observations.size() != 0 ||
            driver_adapters[MAIN_ADAPTER_SLOT].published_tails[switch_key].size()
                != 1 ||
            driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count.exists(switch_key))
            `uvm_fatal("TLPQ_DRIVER_HOST_IRQ",
                       "one Host IRQ crossed channel or ACK/query ordering")
        foreach (host_batch_tails[i]) begin
            if (driver_adapters[MAIN_ADAPTER_SLOT].published_tails[host_key][i]
                    != host_batch_tails[i])
                `uvm_fatal("TLPQ_DRIVER_HOST_TAIL", $sformatf(
                    "Host tail[%0d] was not literal 0x%04h",
                    i, host_batch_tails[i]))
        end
        for (int unsigned i = 0; i < 3; i++) begin
            check_driver_observation(
                driver_collectors[MAIN_HOST_ENGINE].observations[i],
                golden, host_metadata[i], $sformatf("Host batch %0d", i));
            replacement_base =
                driver_engines[MAIN_HOST_ENGINE].get_outstanding(31 + i);
            if (!$cast(replacement, replacement_base) || replacement == null)
                `uvm_fatal("TLPQ_DRIVER_HOST_REPLACEMENT",
                           "Host replacement was not a TLPQ descriptor")
            replacement_matches_retired = 0;
            foreach (host_retired[j]) begin
                if (replacement == host_retired[j])
                    replacement_matches_retired = 1;
            end
            if (replacement_matches_retired ||
                replacement.owned_allocation_count() != 1 ||
                replacement.buf_len != 128 ||
                mem.allocation_size(replacement.buf_addr) != 128 ||
                mem.free_count(host_retired_addr[i]) !=
                    host_free_before[i] + 1 ||
                (replacement.buf_addr == host_retired_addr[i] &&
                 mem.allocation_generation(replacement.buf_addr) <=
                    host_retired_generation[i]))
                `uvm_fatal("TLPQ_DRIVER_HOST_REPLACEMENT", $sformatf(
                    "Host replacement %0d was not a fresh 128-byte ownership",
                    i))
            check_refill_replacement(
                MAIN_HOST_ENGINE, 31 + i, host_retired[i],
                host_retired_addr[i], host_free_before[i],
                64'h0000_0001_e000_0000,
                host_replacement_slots[i],
                $sformatf("Host batch replacement %0d", i));
        end
        if (mem.allocation_count_for_size(TLPQ_BUFFER_BYTES) !=
                host_alloc_before + 3 ||
            driver_engines[MAIN_HOST_ENGINE].head_seq() != 3 ||
            driver_engines[MAIN_HOST_ENGINE].tail_seq() != 34 ||
            driver_engines[MAIN_HOST_ENGINE].outstanding_count() != 31)
            `uvm_fatal("TLPQ_DRIVER_HOST_REFILL",
                       "Host batch did not refill singly back to 31")

        // The Host first replacement crosses slot 31 to slot 0 and publishes
        // phase-tail 0x8000 while the untouched Switch remains at 0x001f.
        if (driver_adapters[MAIN_ADAPTER_SLOT].published_tails[host_key][1] !=
                16'h8000 ||
            driver_adapters[MAIN_ADAPTER_SLOT].published_tails[switch_key][0]
                != 16'h001f)
            `uvm_fatal("TLPQ_DRIVER_HOST_WRAP_ISOLATION",
                       "Host wrap changed the Switch pre-wrap tail")

        switch_alloc_before = mem.allocation_count_for_size(TLPQ_BUFFER_BYTES);
        for (int unsigned i = 0; i < 2; i++) begin
            if (!$cast(switch_retired[i],
                       driver_engines[MAIN_SWITCH_ENGINE].get_outstanding(i)))
                `uvm_fatal("TLPQ_DRIVER_SWITCH_BATCH",
                           "Switch retired handle was not a TLPQ descriptor")
            switch_retired_addr[i] = switch_retired[i].buf_addr;
            switch_retired_generation[i] =
                mem.allocation_generation(switch_retired_addr[i]);
            switch_free_before[i] = mem.free_count(switch_retired_addr[i]);
            record_retired_allocation(
                switch_retired[i], switch_retired_addr[i],
                switch_retired_generation[i],
                $sformatf("Switch batch retired %0d", i));
            if (!dut.complete_slot(driver_engines[MAIN_SWITCH_ENGINE], i,
                                   golden, 16, switch_metadata[i], -1))
                `uvm_fatal("TLPQ_DRIVER_DUT",
                           "Switch batch completion injection failed")
        end
        switch_irq_time = $time;
        dut.trigger_irq(driver_adapters[MAIN_ADAPTER_SLOT], TLPQ_SWITCH);
        wait_for_driver_callbacks(MAIN_SWITCH_ENGINE, 2, "Switch batch");
        wait_for_driver_publishes(MAIN_SWITCH_ENGINE, 3,
                                  "Switch batch refill");
        if (driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[switch_key] != 1 ||
            driver_completions[MAIN_SWITCH_ENGINE].query_times.size() != 1 ||
            driver_completions[MAIN_SWITCH_ENGINE].query_times[0] !=
                switch_irq_time ||
            driver_completions[MAIN_SWITCH_ENGINE].ack_counts_at_query[0] != 1 ||
            driver_collectors[MAIN_HOST_ENGINE].observations.size() != 3 ||
            driver_adapters[MAIN_ADAPTER_SLOT].published_tails[host_key].size()
                != 4 ||
            driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[host_key] != 1)
            `uvm_fatal("TLPQ_DRIVER_SWITCH_IRQ",
                       "one Switch IRQ crossed channel or ACK/query ordering")
        foreach (switch_batch_tails[i]) begin
            if (driver_adapters[MAIN_ADAPTER_SLOT].published_tails[switch_key][i]
                    != switch_batch_tails[i])
                `uvm_fatal("TLPQ_DRIVER_SWITCH_TAIL", $sformatf(
                    "Switch tail[%0d] was not literal 0x%04h",
                    i, switch_batch_tails[i]))
        end
        for (int unsigned i = 0; i < 2; i++) begin
            check_driver_observation(
                driver_collectors[MAIN_SWITCH_ENGINE].observations[i],
                golden, switch_metadata[i],
                $sformatf("Switch batch %0d", i));
            if (!$cast(replacement,
                       driver_engines[MAIN_SWITCH_ENGINE].get_outstanding(
                           31 + i)) || replacement == null)
                `uvm_fatal("TLPQ_DRIVER_SWITCH_REPLACEMENT",
                           "Switch replacement was not a TLPQ descriptor")
            replacement_matches_retired = 0;
            foreach (switch_retired[j]) begin
                if (replacement == switch_retired[j])
                    replacement_matches_retired = 1;
            end
            if (replacement_matches_retired ||
                replacement.owned_allocation_count() != 1 ||
                replacement.buf_len != 128 ||
                mem.allocation_size(replacement.buf_addr) != 128 ||
                mem.free_count(switch_retired_addr[i]) !=
                    switch_free_before[i] + 1 ||
                (replacement.buf_addr == switch_retired_addr[i] &&
                 mem.allocation_generation(replacement.buf_addr) <=
                    switch_retired_generation[i]))
                `uvm_fatal("TLPQ_DRIVER_SWITCH_REPLACEMENT", $sformatf(
                    "Switch replacement %0d was not a fresh 128-byte ownership",
                    i))
            check_refill_replacement(
                MAIN_SWITCH_ENGINE, 31 + i, switch_retired[i],
                switch_retired_addr[i], switch_free_before[i],
                64'h0000_0001_e000_1180,
                switch_replacement_slots[i],
                $sformatf("Switch batch replacement %0d", i));
        end
        if (mem.allocation_count_for_size(TLPQ_BUFFER_BYTES) !=
                switch_alloc_before + 2 ||
            driver_engines[MAIN_SWITCH_ENGINE].head_seq() != 2 ||
            driver_engines[MAIN_SWITCH_ENGINE].tail_seq() != 33 ||
            driver_engines[MAIN_SWITCH_ENGINE].outstanding_count() != 31 ||
            driver_adapters[MAIN_ADAPTER_SLOT].published_tails[switch_key][1]
                != 16'h8000 ||
            driver_adapters[MAIN_ADAPTER_SLOT].published_tails[host_key].size()
                != 4)
            `uvm_fatal("TLPQ_DRIVER_SWITCH_WRAP_ISOLATION",
                       "Switch wrap/refill changed Host state")

        // Spurious Host IRQ: exactly one ACK and query, zero delivery/refill.
        wait_before =
            driver_adapters[MAIN_ADAPTER_SLOT].wait_irq_count[host_key];
        wait_for_driver_irq_waits(MAIN_HOST_ENGINE, wait_before + 1,
                                  "Host spurious");
        ack_before =
            driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[host_key];
        query_before =
            driver_completions[MAIN_HOST_ENGINE].query_times.size();
        callback_before =
            driver_collectors[MAIN_HOST_ENGINE].observations.size();
        publish_before =
            driver_adapters[MAIN_ADAPTER_SLOT].published_tails[host_key].size();
        dut.trigger_irq(driver_adapters[MAIN_ADAPTER_SLOT], TLPQ_HOST);
        wait_for_driver_queries(MAIN_HOST_ENGINE, query_before + 1,
                                "Host spurious");
        if (driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[host_key] !=
                ack_before + 1 ||
            driver_completions[MAIN_HOST_ENGINE].ack_counts_at_query[
                query_before] != ack_before + 1 ||
            driver_collectors[MAIN_HOST_ENGINE].observations.size() !=
                callback_before ||
            driver_adapters[MAIN_ADAPTER_SLOT].published_tails[host_key].size()
                != publish_before)
            `uvm_fatal("TLPQ_DRIVER_SPURIOUS_IRQ",
                       "spurious IRQ did not ACK once with zero delivery")

        // Independent Host and Switch IRQ waiters are triggered at the same
        // simulation timestamp and each owns exactly one ACK and one callback.
        wait_before =
            driver_adapters[MAIN_ADAPTER_SLOT].wait_irq_count[host_key];
        wait_for_driver_irq_waits(MAIN_HOST_ENGINE, wait_before + 1,
                                  "simultaneous Host");
        wait_before =
            driver_adapters[MAIN_ADAPTER_SLOT].wait_irq_count[switch_key];
        wait_for_driver_irq_waits(MAIN_SWITCH_ENGINE, wait_before + 1,
                                  "simultaneous Switch");
        if (!$cast(simultaneous_host_retired,
                   driver_engines[MAIN_HOST_ENGINE].get_outstanding(3)) ||
            !$cast(simultaneous_switch_retired,
                   driver_engines[MAIN_SWITCH_ENGINE].get_outstanding(2)))
            `uvm_fatal("TLPQ_DRIVER_SIMULTANEOUS_OWNERSHIP",
                       "simultaneous retired handles were not TLPQ descriptors")
        simultaneous_host_addr = simultaneous_host_retired.buf_addr;
        simultaneous_switch_addr = simultaneous_switch_retired.buf_addr;
        simultaneous_host_generation =
            mem.allocation_generation(simultaneous_host_addr);
        simultaneous_switch_generation =
            mem.allocation_generation(simultaneous_switch_addr);
        simultaneous_host_free_before =
            mem.free_count(simultaneous_host_addr);
        simultaneous_switch_free_before =
            mem.free_count(simultaneous_switch_addr);
        record_retired_allocation(
            simultaneous_host_retired, simultaneous_host_addr,
            simultaneous_host_generation, "simultaneous Host retired");
        record_retired_allocation(
            simultaneous_switch_retired, simultaneous_switch_addr,
            simultaneous_switch_generation, "simultaneous Switch retired");
        simultaneous_alloc_before =
            mem.allocation_count_for_size(TLPQ_BUFFER_BYTES);
        if (!dut.complete_slot(driver_engines[MAIN_HOST_ENGINE], 3,
                               golden, 16,
                               simultaneous_host_metadata, -1) ||
            !dut.complete_slot(driver_engines[MAIN_SWITCH_ENGINE], 2,
                               golden, 16,
                               simultaneous_switch_metadata, -1))
            `uvm_fatal("TLPQ_DRIVER_DUT",
                       "simultaneous completion injection failed")
        ack_before =
            driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[host_key];
        query_before =
            driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[switch_key];
        host_irq_time = $time;
        dut.trigger_irq(driver_adapters[MAIN_ADAPTER_SLOT], TLPQ_HOST);
        dut.trigger_irq(driver_adapters[MAIN_ADAPTER_SLOT], TLPQ_SWITCH);
        switch_irq_time = $time;
        wait_for_driver_callbacks(MAIN_HOST_ENGINE, 4,
                                  "simultaneous Host");
        wait_for_driver_callbacks(MAIN_SWITCH_ENGINE, 3,
                                  "simultaneous Switch");
        wait_for_driver_publishes(MAIN_HOST_ENGINE, 5,
                                  "simultaneous Host refill");
        wait_for_driver_publishes(MAIN_SWITCH_ENGINE, 4,
                                  "simultaneous Switch refill");
        if (host_irq_time != switch_irq_time ||
            driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[host_key] !=
                ack_before + 1 ||
            driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[switch_key] !=
                query_before + 1)
            `uvm_fatal("TLPQ_DRIVER_SIMULTANEOUS_IRQ",
                       "simultaneous IRQs did not ACK independently once")
        check_driver_observation(
            driver_collectors[MAIN_HOST_ENGINE].observations[3],
            golden, simultaneous_host_metadata, "simultaneous Host");
        check_driver_observation(
            driver_collectors[MAIN_SWITCH_ENGINE].observations[2],
            golden, simultaneous_switch_metadata, "simultaneous Switch");
        check_refill_replacement(
            MAIN_HOST_ENGINE, 34, simultaneous_host_retired,
            simultaneous_host_addr, simultaneous_host_free_before,
            64'h0000_0001_e000_0000, 2,
            "simultaneous Host replacement");
        check_refill_replacement(
            MAIN_SWITCH_ENGINE, 33, simultaneous_switch_retired,
            simultaneous_switch_addr, simultaneous_switch_free_before,
            64'h0000_0001_e000_1180, 1,
            "simultaneous Switch replacement");
        if (mem.allocation_count_for_size(TLPQ_BUFFER_BYTES) !=
                simultaneous_alloc_before + 2)
            `uvm_fatal("TLPQ_DRIVER_SIMULTANEOUS_OWNERSHIP",
                       "simultaneous refills did not allocate two buffers")

        // A completion with no interrupt edge is recovered by the standard
        // one-microsecond watchdog, and that wakeup never acknowledges IRQ.
        wait_before =
            driver_adapters[MAIN_ADAPTER_SLOT].wait_irq_count[host_key];
        wait_for_driver_irq_waits(MAIN_HOST_ENGINE, wait_before + 1,
                                  "Host lost IRQ");
        watchdog_wait_time =
            driver_adapters[MAIN_ADAPTER_SLOT].wait_irq_times[host_key][
                wait_before];
        if (!$cast(lost_retired,
                   driver_engines[MAIN_HOST_ENGINE].get_outstanding(4)))
            `uvm_fatal("TLPQ_DRIVER_LOST_OWNERSHIP",
                       "lost-IRQ retired handle was not a TLPQ descriptor")
        lost_addr = lost_retired.buf_addr;
        lost_generation = mem.allocation_generation(lost_addr);
        lost_free_before = mem.free_count(lost_addr);
        record_retired_allocation(
            lost_retired, lost_addr, lost_generation, "lost-IRQ Host retired");
        lost_alloc_before =
            mem.allocation_count_for_size(TLPQ_BUFFER_BYTES);
        if (!dut.complete_slot(driver_engines[MAIN_HOST_ENGINE], 4,
                               golden, 16, lost_metadata, -1))
            `uvm_fatal("TLPQ_DRIVER_DUT",
                       "lost IRQ completion injection failed")
        ack_before =
            driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[host_key];
        query_before =
            driver_completions[MAIN_HOST_ENGINE].query_times.size();
        trigger_before =
            driver_adapters[MAIN_ADAPTER_SLOT].trigger_irq_count[host_key];
        wait_for_driver_callbacks(MAIN_HOST_ENGINE, 5, "Host lost IRQ");
        wait_for_driver_publishes(MAIN_HOST_ENGINE, 6,
                                  "Host lost IRQ refill");
        if (driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[host_key] !=
                ack_before ||
            driver_adapters[MAIN_ADAPTER_SLOT].trigger_irq_count[host_key] !=
                trigger_before ||
            driver_completions[MAIN_HOST_ENGINE].query_times[query_before] !=
                watchdog_wait_time + 1us ||
            driver_completions[MAIN_HOST_ENGINE].ack_counts_at_query[
                query_before] != ack_before)
            `uvm_fatal("TLPQ_DRIVER_LOST_IRQ",
                       "one-us watchdog recovery ACKed or fired at wrong time")
        check_driver_observation(
            driver_collectors[MAIN_HOST_ENGINE].observations[4],
            golden, lost_metadata, "Host lost IRQ");
        check_refill_replacement(
            MAIN_HOST_ENGINE, 35, lost_retired, lost_addr, lost_free_before,
            64'h0000_0001_e000_0000, 3,
            "lost-IRQ Host replacement");
        if (mem.allocation_count_for_size(TLPQ_BUFFER_BYTES) !=
                lost_alloc_before + 1)
            `uvm_fatal("TLPQ_DRIVER_LOST_OWNERSHIP",
                       "lost-IRQ refill did not allocate one buffer")
    endtask

    task run_fixed_poll_scenario();
        byte golden[] = '{8'h80, 8'h77, 8'h66, 8'h55,
                          8'h44, 8'h33, 8'h22, 8'h11,
                          8'hc3, 8'h9a, 8'h78, 8'h56,
                          8'h02, 8'h00, 8'h00, 8'h20};
        tlpq_route_metadata_t host_metadata;
        tlpq_route_metadata_t switch_metadata;
        tlpq_rx_desc host_retired;
        tlpq_rx_desc switch_retired;
        gq_addr_t host_retired_addr;
        gq_addr_t switch_retired_addr;
        int unsigned host_retired_generation;
        int unsigned switch_retired_generation;
        int unsigned host_retired_free_before;
        int unsigned switch_retired_free_before;
        int unsigned allocation_before;
        gq_addr_t host_ring_base;
        gq_addr_t switch_ring_base;
        time poll_started;
        int host_key;
        int switch_key;

        host_key = int'(TLPQ_HOST);
        switch_key = int'(TLPQ_SWITCH);
        host_metadata = '{host_id:4'ha, tlp_type:4'hb,
                          primary_bus:8'ha1, secondary_bus:8'ha2,
                          subordinate_bus:8'ha3};
        switch_metadata = '{host_id:4'hb, tlp_type:4'hc,
                            primary_bus:8'hb1, secondary_bus:8'hb2,
                            subordinate_bus:8'hb3};
        if (driver_cfgs[POLL_HOST_ENGINE].wait_mode != GQ_POLL ||
            driver_cfgs[POLL_SWITCH_ENGINE].wait_mode != GQ_POLL ||
            driver_cfgs[POLL_HOST_ENGINE].poll_policy != GQ_POLL_FIXED ||
            driver_cfgs[POLL_SWITCH_ENGINE].poll_policy != GQ_POLL_FIXED ||
            driver_cfgs[POLL_HOST_ENGINE].poll_min_interval != 10ns ||
            driver_cfgs[POLL_HOST_ENGINE].poll_max_interval != 10ns ||
            driver_cfgs[POLL_SWITCH_ENGINE].poll_min_interval != 10ns ||
            driver_cfgs[POLL_SWITCH_ENGINE].poll_max_interval != 10ns)
            `uvm_fatal("TLPQ_DRIVER_POLL_CFG",
                       "directed Host/Switch fixed 10ns Poll diverged")

        start_driver_engine(POLL_HOST_ENGINE);
        start_driver_engine(POLL_SWITCH_ENGINE);
        host_ring_base = driver_engines[POLL_HOST_ENGINE].ring_base();
        switch_ring_base = driver_engines[POLL_SWITCH_ENGINE].ring_base();
        if (host_ring_base == 0 || switch_ring_base == 0 ||
            host_ring_base == switch_ring_base)
            `uvm_fatal("TLPQ_DRIVER_POLL_RING_BASE",
                       "fixed Poll Host/Switch did not own independent rings")
        if (!$cast(host_retired,
                   driver_engines[POLL_HOST_ENGINE].get_outstanding(0)) ||
            !$cast(switch_retired,
                   driver_engines[POLL_SWITCH_ENGINE].get_outstanding(0)))
            `uvm_fatal("TLPQ_DRIVER_POLL_OWNERSHIP",
                       "fixed Poll retired handles were not TLPQ descriptors")
        host_retired_addr = host_retired.buf_addr;
        switch_retired_addr = switch_retired.buf_addr;
        host_retired_generation =
            mem.allocation_generation(host_retired_addr);
        switch_retired_generation =
            mem.allocation_generation(switch_retired_addr);
        host_retired_free_before = mem.free_count(host_retired_addr);
        switch_retired_free_before = mem.free_count(switch_retired_addr);
        record_retired_allocation(
            host_retired, host_retired_addr, host_retired_generation,
            "fixed Poll Host retired");
        record_retired_allocation(
            switch_retired, switch_retired_addr, switch_retired_generation,
            "fixed Poll Switch retired");
        allocation_before =
            mem.allocation_count_for_size(TLPQ_BUFFER_BYTES);
        if (!dut.complete_slot(driver_engines[POLL_HOST_ENGINE], 0,
                               golden, 16, host_metadata, -1) ||
            !dut.complete_slot(driver_engines[POLL_SWITCH_ENGINE], 0,
                               golden, 16, switch_metadata, -1))
            `uvm_fatal("TLPQ_DRIVER_DUT",
                       "fixed Poll completion injection failed")
        poll_started = $time;
        start_driver_worker(POLL_HOST_ENGINE);
        start_driver_worker(POLL_SWITCH_ENGINE);
        wait_for_driver_callbacks(POLL_HOST_ENGINE, 1, "Host fixed Poll");
        wait_for_driver_callbacks(POLL_SWITCH_ENGINE, 1,
                                  "Switch fixed Poll");
        wait_for_driver_publishes(POLL_HOST_ENGINE, 2,
                                  "Host fixed Poll refill");
        wait_for_driver_publishes(POLL_SWITCH_ENGINE, 2,
                                  "Switch fixed Poll refill");
        if (driver_completions[POLL_HOST_ENGINE].query_times[0] !=
                poll_started + 10ns ||
            driver_completions[POLL_SWITCH_ENGINE].query_times[0] !=
                poll_started + 10ns ||
            driver_collectors[POLL_HOST_ENGINE].observations[0].callback_time
                != poll_started + 10ns ||
            driver_collectors[POLL_SWITCH_ENGINE].observations[0].callback_time
                != poll_started + 10ns ||
            driver_adapters[POLL_ADAPTER_SLOT].ack_irq_count.exists(host_key) ||
            driver_adapters[POLL_ADAPTER_SLOT].ack_irq_count.exists(switch_key) ||
            driver_adapters[POLL_ADAPTER_SLOT].trigger_irq_count.exists(host_key) ||
            driver_adapters[POLL_ADAPTER_SLOT].trigger_irq_count.exists(switch_key) ||
            driver_adapters[POLL_ADAPTER_SLOT].wait_irq_count.exists(host_key) ||
            driver_adapters[POLL_ADAPTER_SLOT].wait_irq_count.exists(switch_key) ||
            driver_adapters[POLL_ADAPTER_SLOT].published_tails[host_key][1]
                != 16'h8000 ||
            driver_adapters[POLL_ADAPTER_SLOT].published_tails[switch_key][1]
                != 16'h8000)
            `uvm_fatal("TLPQ_DRIVER_FIXED_POLL",
                       "Host/Switch did not query and refill at fixed 10ns")
        check_driver_observation(
            driver_collectors[POLL_HOST_ENGINE].observations[0],
            golden, host_metadata, "Host fixed Poll");
        check_driver_observation(
            driver_collectors[POLL_SWITCH_ENGINE].observations[0],
            golden, switch_metadata, "Switch fixed Poll");
        check_refill_replacement(
            POLL_HOST_ENGINE, 31, host_retired, host_retired_addr,
            host_retired_free_before, host_ring_base, 31,
            "fixed Poll Host replacement");
        check_refill_replacement(
            POLL_SWITCH_ENGINE, 31, switch_retired, switch_retired_addr,
            switch_retired_free_before, switch_ring_base, 31,
            "fixed Poll Switch replacement");
        if (mem.allocation_count_for_size(TLPQ_BUFFER_BYTES) !=
                allocation_before + 2)
            `uvm_fatal("TLPQ_DRIVER_POLL_OWNERSHIP",
                       "fixed Poll refills did not allocate two buffers")
    endtask

    task recycle_error_engine(string label);
        gq_addr_t ring_addr;
        gq_addr_t buffer_addresses[$];
        int unsigned ring_free_before;
        int unsigned buffer_free_before[$];
        tlpq_rx_desc desc;
        int host_key;
        int publish_before;

        host_key = int'(TLPQ_HOST);
        ring_addr = driver_engines[ERROR_HOST_ENGINE].ring_base();
        ring_free_before = mem.free_count(ring_addr);
        for (gq_logical_seq_t seq =
                 driver_engines[ERROR_HOST_ENGINE].head_seq();
             seq < driver_engines[ERROR_HOST_ENGINE].tail_seq(); seq++) begin
            if (!$cast(desc,
                       driver_engines[ERROR_HOST_ENGINE].get_outstanding(seq)))
                `uvm_fatal("TLPQ_DRIVER_ERROR_RESET", {label,
                           " could not snapshot outstanding descriptor"})
            buffer_addresses.push_back(desc.buf_addr);
            buffer_free_before.push_back(mem.free_count(desc.buf_addr));
        end
        publish_before =
            driver_adapters[ERROR_ADAPTER_SLOT].published_tails[host_key].size();
        driver_engines[ERROR_HOST_ENGINE].begin_reset();
        driver_engines[ERROR_HOST_ENGINE].finish_reset();
        if (driver_engines[ERROR_HOST_ENGINE].outstanding_count() != 0 ||
            driver_engines[ERROR_HOST_ENGINE].ring_base() != 0 ||
            mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("TLPQ_DRIVER_ERROR_RESET", {label,
                       " reset did not release ring ownership once"})
        foreach (buffer_addresses[i]) begin
            if (mem.free_count(buffer_addresses[i]) !=
                    buffer_free_before[i] + 1)
                `uvm_fatal("TLPQ_DRIVER_ERROR_RESET", {label,
                           " reset did not release buffer ownership once"})
        end
        driver_engines[ERROR_HOST_ENGINE].release_reset();
        if (!driver_engines[ERROR_HOST_ENGINE].is_ready() ||
            driver_engines[ERROR_HOST_ENGINE].head_seq() != 0 ||
            driver_engines[ERROR_HOST_ENGINE].tail_seq() != 31 ||
            driver_engines[ERROR_HOST_ENGINE].outstanding_count() != 31 ||
            driver_adapters[ERROR_ADAPTER_SLOT].published_tails[host_key].size()
                != publish_before + 1 ||
            driver_adapters[ERROR_ADAPTER_SLOT].published_tails[host_key][
                publish_before] != 16'h001f)
            `uvm_fatal("TLPQ_DRIVER_ERROR_RESTART", {label,
                       " reset release did not repost initial tail 0x001f"})
    endtask

    task run_invalid_completion_case(
        string label, input byte dpu_bytes[], int unsigned completed_length,
        int stable_corrupt_offset, bit expect_invalid_query,
        bit expect_malformed_bytes);
        tlpq_route_metadata_t metadata;
        tlpq_rx_desc desc;
        gq_addr_t buffer_addr;
        int unsigned free_before;
        int unsigned report_before;
        int unsigned invalid_before;
        int unsigned parse_before;

        metadata = '{host_id:4'hc, tlp_type:4'hd,
                     primary_bus:8'hc1, secondary_bus:8'hc2,
                     subordinate_bus:8'hc3};
        if (!$cast(desc,
                   driver_engines[ERROR_HOST_ENGINE].get_outstanding(0)))
            `uvm_fatal("TLPQ_DRIVER_INVALID",
                       {label, " missing head descriptor"})
        buffer_addr = desc.buf_addr;
        free_before = mem.free_count(buffer_addr);
        report_before = driver_report_catcher.report_ids.size();
        invalid_before = driver_report_catcher.invalid_query_count;
        parse_before = driver_report_catcher.parse_error_count;
        if (!dut.complete_slot(driver_engines[ERROR_HOST_ENGINE], 0,
                               dpu_bytes, completed_length,
                               metadata, stable_corrupt_offset))
            `uvm_fatal("TLPQ_DRIVER_DUT", {label,
                       " completion injection failed"})
        driver_engines[ERROR_HOST_ENGINE].drain_completed();
        if (driver_report_catcher.report_ids.size() != report_before + 1 ||
            driver_report_catcher.invalid_query_count !=
                invalid_before + (expect_invalid_query ? 1 : 0) ||
            driver_report_catcher.parse_error_count !=
                parse_before + (expect_invalid_query ? 0 : 1) ||
            !driver_report_matches(
                report_before,
                expect_invalid_query ? UVM_WARNING : UVM_ERROR,
                expect_invalid_query ?
                    "GQ_COMPLETION_QUERY" : "GQ_COMPLETION_PARSE",
                expect_invalid_query ?
                    "completion source returned an invalid query" :
                    "completion parse failed at logical sequence 0") ||
            driver_collectors[ERROR_HOST_ENGINE].observations.size() != 0 ||
            driver_engines[ERROR_HOST_ENGINE].head_seq() != 0 ||
            driver_engines[ERROR_HOST_ENGINE].outstanding_count() != 31 ||
            mem.free_count(buffer_addr) != free_before)
            `uvm_fatal("TLPQ_DRIVER_INVALID", {label,
                       " retired, delivered, freed, or reported incorrectly"})
        if (expect_invalid_query) begin
            if (desc.flags != TLPQ_DESC_AVAIL || desc.buf_len != 128 ||
                desc.dpu_bytes.size() != 0 || desc.decoded_tlp != null)
                `uvm_fatal("TLPQ_DRIVER_CHANGED_ADDRESS",
                           "changed address mutated the owned descriptor")
        end else if (expect_malformed_bytes) begin
            if (!driver_dpu_bytes_equal(desc.dpu_bytes, dpu_bytes) ||
                desc.decoded_tlp != null)
                `uvm_fatal("TLPQ_DRIVER_MALFORMED_BYTES",
                           "malformed DPU bytes were not preserved exactly")
        end else if (desc.dpu_bytes.size() != 0 ||
                     desc.decoded_tlp != null) begin
            `uvm_fatal("TLPQ_DRIVER_BAD_LENGTH",
                       "zero/oversize length exposed decoded data")
        end
        recycle_error_engine(label);
    endtask

    task run_malformed_and_reset_query_scenario();
        byte golden[] = '{8'h80, 8'h77, 8'h66, 8'h55,
                          8'h44, 8'h33, 8'h22, 8'h11,
                          8'hc3, 8'h9a, 8'h78, 8'h56,
                          8'h02, 8'h00, 8'h00, 8'h20};
        byte malformed[] = '{8'h80, 8'h77, 8'h66, 8'h55,
                             8'h44, 8'h33, 8'h22, 8'h11,
                             8'hc3, 8'h9a, 8'h78, 8'h56,
                             8'h02, 8'h00, 8'h00, 8'he0};
        byte empty[] = '{};
        tlpq_route_metadata_t metadata;
        tlpq_rx_desc desc;
        gq_addr_t ring_addr;
        gq_addr_t buffer_addresses[$];
        int unsigned ring_free_before;
        int unsigned buffer_free_before[$];
        int unsigned report_before;
        int unsigned callback_before;
        longint unsigned epoch_before;
        bit drain_done;

        start_driver_engine(ERROR_HOST_ENGINE);
        run_invalid_completion_case(
            "changed address", golden, 16, 4, 1, 0);
        run_invalid_completion_case(
            "zero length", empty, 0, -1, 0, 0);
        run_invalid_completion_case(
            "oversize length", golden, 129, -1, 0, 0);
        run_invalid_completion_case(
            "malformed DPU bytes", malformed, 16, -1, 0, 1);

        metadata = '{host_id:4'he, tlp_type:4'hf,
                     primary_bus:8'he1, secondary_bus:8'he2,
                     subordinate_bus:8'he3};
        ring_addr = driver_engines[ERROR_HOST_ENGINE].ring_base();
        ring_free_before = mem.free_count(ring_addr);
        for (gq_logical_seq_t seq = 0; seq < 31; seq++) begin
            if (!$cast(desc,
                       driver_engines[ERROR_HOST_ENGINE].get_outstanding(seq)))
                `uvm_fatal("TLPQ_DRIVER_RESET_QUERY",
                           "could not snapshot reset-query ownership")
            buffer_addresses.push_back(desc.buf_addr);
            buffer_free_before.push_back(mem.free_count(desc.buf_addr));
        end
        if (!dut.complete_slot(driver_engines[ERROR_HOST_ENGINE], 0,
                               golden, 16, metadata, -1))
            `uvm_fatal("TLPQ_DRIVER_DUT",
                       "reset-query completion injection failed")
        report_before = driver_report_catcher.report_ids.size();
        callback_before =
            driver_collectors[ERROR_HOST_ENGINE].observations.size();
        driver_completions[ERROR_HOST_ENGINE].block_next_query();
        drain_done = 0;
        fork
            begin
                driver_engines[ERROR_HOST_ENGINE].drain_completed();
                drain_done = 1;
            end
        join_none
        driver_completions[ERROR_HOST_ENGINE].query_blocked.wait_on();
        epoch_before = driver_engines[ERROR_HOST_ENGINE].reset_epoch();
        driver_engines[ERROR_HOST_ENGINE].begin_reset();
        if (driver_engines[ERROR_HOST_ENGINE].reset_epoch() !=
                epoch_before + 1)
            `uvm_fatal("TLPQ_DRIVER_RESET_QUERY_EPOCH",
                       "reset did not advance during blocked query")
        driver_completions[ERROR_HOST_ENGINE].release_query();
        wait (drain_done);
        driver_engines[ERROR_HOST_ENGINE].finish_reset();
        if (driver_report_catcher.report_ids.size() != report_before ||
            driver_collectors[ERROR_HOST_ENGINE].observations.size() !=
                callback_before ||
            driver_engines[ERROR_HOST_ENGINE].outstanding_count() != 0 ||
            driver_engines[ERROR_HOST_ENGINE].ring_base() != 0 ||
            mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("TLPQ_DRIVER_RESET_QUERY",
                       "blocked query committed stale work or ring ownership")
        foreach (buffer_addresses[i]) begin
            if (mem.free_count(buffer_addresses[i]) !=
                    buffer_free_before[i] + 1)
                `uvm_fatal("TLPQ_DRIVER_RESET_QUERY",
                           "blocked-query reset did not free each buffer once")
        end
        driver_engines[ERROR_HOST_ENGINE].cleanup();
        if (mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("TLPQ_DRIVER_RESET_QUERY",
                       "cleanup double-freed reset-query ring")
        foreach (buffer_addresses[i]) begin
            if (mem.free_count(buffer_addresses[i]) !=
                    buffer_free_before[i] + 1)
                `uvm_fatal("TLPQ_DRIVER_RESET_QUERY",
                           "cleanup double-freed reset-query buffer")
        end
    endtask

    task run_cleanup_blocked_ack_scenario();
        byte golden[] = '{8'h80, 8'h77, 8'h66, 8'h55,
                          8'h44, 8'h33, 8'h22, 8'h11,
                          8'hc3, 8'h9a, 8'h78, 8'h56,
                          8'h02, 8'h00, 8'h00, 8'h20};
        tlpq_route_metadata_t metadata;
        tlpq_rx_desc desc;
        gq_addr_t ring_addr;
        gq_addr_t buffer_addresses[$];
        int unsigned ring_free_before;
        int unsigned buffer_free_before[$];
        int unsigned switch_key;
        int unsigned wait_before;
        int unsigned ack_before;
        int unsigned query_before;
        int unsigned callback_before;
        bit cleanup_done;

        switch_key = int'(TLPQ_SWITCH);
        metadata = '{host_id:4'hf, tlp_type:4'h1,
                     primary_bus:8'hf1, secondary_bus:8'hf2,
                     subordinate_bus:8'hf3};
        wait_before =
            driver_adapters[MAIN_ADAPTER_SLOT].wait_irq_count[switch_key];
        wait_for_driver_irq_waits(MAIN_SWITCH_ENGINE, wait_before + 1,
                                  "cleanup blocked ACK");
        if (!dut.complete_slot(driver_engines[MAIN_SWITCH_ENGINE], 3,
                               golden, 16, metadata, -1))
            `uvm_fatal("TLPQ_DRIVER_DUT",
                       "cleanup blocked-ACK completion injection failed")
        ring_addr = driver_engines[MAIN_SWITCH_ENGINE].ring_base();
        ring_free_before = mem.free_count(ring_addr);
        for (gq_logical_seq_t seq =
                 driver_engines[MAIN_SWITCH_ENGINE].head_seq();
             seq < driver_engines[MAIN_SWITCH_ENGINE].tail_seq(); seq++) begin
            if (!$cast(desc,
                       driver_engines[MAIN_SWITCH_ENGINE].get_outstanding(seq)))
                `uvm_fatal("TLPQ_DRIVER_CLEANUP_ACK",
                           "could not snapshot blocked-ACK ownership")
            buffer_addresses.push_back(desc.buf_addr);
            buffer_free_before.push_back(mem.free_count(desc.buf_addr));
        end
        ack_before =
            driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[switch_key];
        query_before =
            driver_completions[MAIN_SWITCH_ENGINE].query_times.size();
        callback_before =
            driver_collectors[MAIN_SWITCH_ENGINE].observations.size();
        driver_adapters[MAIN_ADAPTER_SLOT].block_next_irq_ack(TLPQ_SWITCH);
        dut.trigger_irq(driver_adapters[MAIN_ADAPTER_SLOT], TLPQ_SWITCH);
        driver_adapters[MAIN_ADAPTER_SLOT].irq_ack_blocked[switch_key].wait_on();
        cleanup_done = 0;
        fork
            begin
                driver_engines[MAIN_SWITCH_ENGINE].cleanup();
                cleanup_done = 1;
            end
        join_none
        #1ns;
        if (cleanup_done)
            `uvm_fatal("TLPQ_DRIVER_CLEANUP_ACK",
                       "cleanup returned before the owned ACK completed")
        driver_adapters[MAIN_ADAPTER_SLOT].release_irq_ack(TLPQ_SWITCH);
        wait (cleanup_done);
        if (driver_adapters[MAIN_ADAPTER_SLOT].ack_irq_count[switch_key] !=
                ack_before + 1 ||
            driver_completions[MAIN_SWITCH_ENGINE].query_times.size() !=
                query_before ||
            driver_collectors[MAIN_SWITCH_ENGINE].observations.size() !=
                callback_before ||
            driver_engines[MAIN_SWITCH_ENGINE].outstanding_count() != 0 ||
            driver_engines[MAIN_SWITCH_ENGINE].ring_base() != 0 ||
            mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("TLPQ_DRIVER_CLEANUP_ACK",
                       "blocked ACK queried stale work or leaked ring ownership")
        foreach (buffer_addresses[i]) begin
            if (mem.free_count(buffer_addresses[i]) !=
                    buffer_free_before[i] + 1)
                `uvm_fatal("TLPQ_DRIVER_CLEANUP_ACK",
                           "cleanup did not free blocked-ACK buffer once")
        end
        driver_engines[MAIN_SWITCH_ENGINE].cleanup();
        if (mem.free_count(ring_addr) != ring_free_before + 1)
            `uvm_fatal("TLPQ_DRIVER_CLEANUP_ACK",
                       "second cleanup double-freed blocked-ACK ring")
        foreach (buffer_addresses[i]) begin
            if (mem.free_count(buffer_addresses[i]) !=
                    buffer_free_before[i] + 1)
                `uvm_fatal("TLPQ_DRIVER_CLEANUP_ACK",
                           "second cleanup double-freed blocked-ACK buffer")
        end
    endtask

    task cleanup_driver_engines();
        for (int unsigned engine_id = 0;
             engine_id < DRIVER_ENGINE_COUNT; engine_id++)
            driver_engines[engine_id].cleanup();
        mem.leak_check(`__FILE__, `__LINE__);
    endtask

    task run_phase(uvm_phase phase);
        string reason;
        tlpq_env_cfg duplicate_cfg;
        tlpq_env_cfg wrong_cfg;
        tlpq_wrong_adapter wrong_adapter;

        phase.raise_objection(this);
        adapter = tlpq_mock_adapter::type_id::create("adapter");
        env_cfg = tlpq_env_cfg::type_id::create("env_cfg");
        env_cfg.mem = mem;
        env_cfg.adapter = adapter;
        host_hw_cfg = '{host_id:3'h1, bdf:16'h0100,
                        msix_index:13'h011, msix_valid:1'b1};
        switch_hw_cfg = '{host_id:3'h5, bdf:16'h0201,
                          msix_index:13'h122, msix_valid:1'b1};
        if (!env_cfg.add_tlpq_rx(TLPQ_HOST, TLPQ_HOST_QUEUE_ID,
                                 host_hw_cfg, reason) ||
            !env_cfg.add_tlpq_rx(TLPQ_SWITCH, TLPQ_SWITCH_QUEUE_ID,
                                 switch_hw_cfg, reason) ||
            !env_cfg.validate(reason))
            `uvm_fatal("TLPQ_VALID_CFG",
                       {"valid dual-RX environment rejected: ", reason})

        check_defaults();
        check_channel_setup(TLPQ_HOST, TLPQ_HOST_QUEUE_ID,
                            HOST_BASE, host_hw_cfg);
        check_channel_setup(TLPQ_SWITCH, TLPQ_SWITCH_QUEUE_ID,
                            SWITCH_BASE, switch_hw_cfg);
        check_reconfigure_rearms();
        check_irq_isolation();
        check_generic_rejections();
        check_initial_tail_gate();
        check_configure_disable_barrier();
        check_configure_configure_barrier();
        check_publish_reconfigure_barrier();
        check_publish_disable_barrier();
        check_enable_disable_barrier();
        check_dual_start_paths();

        duplicate_cfg = tlpq_env_cfg::type_id::create("duplicate_cfg");
        duplicate_cfg.mem = mem;
        duplicate_cfg.adapter = tlpq_mock_adapter::type_id::create(
            "duplicate_adapter");
        if (!duplicate_cfg.add_tlpq_rx(TLPQ_HOST, 10,
                                       host_hw_cfg, reason) ||
            duplicate_cfg.add_tlpq_rx(TLPQ_HOST, 11,
                                       switch_hw_cfg, reason) ||
            duplicate_cfg.add_tlpq_rx(TLPQ_SWITCH, 10,
                                       switch_hw_cfg, reason))
            `uvm_fatal("TLPQ_DUPLICATE",
                       "duplicate channel or queue ID was accepted")

        wrong_adapter = tlpq_wrong_adapter::type_id::create("wrong_adapter");
        wrong_cfg = tlpq_env_cfg::type_id::create("wrong_cfg");
        wrong_cfg.mem = mem;
        wrong_cfg.adapter = wrong_adapter;
        if (wrong_cfg.add_tlpq_rx(TLPQ_HOST, 20, host_hw_cfg, reason) ||
            wrong_cfg.validate(reason))
            `uvm_fatal("TLPQ_ADAPTER_TYPE",
                       "non-TLPQ adapter was accepted")

        uvm_report_cb::add(null, driver_report_catcher);
        fork : tlpq_conformance_watchdog
            begin
                #50us;
                `uvm_fatal("TLPQ_DRIVER_TIMEOUT",
                           "full dual-ring conformance scenario timed out")
            end
        join_none
        run_main_dual_ring_scenario();
        run_fixed_poll_scenario();
        run_golden_full_chain_scenario();
        run_malformed_and_reset_query_scenario();
        run_cleanup_blocked_ack_scenario();
        cleanup_driver_engines();
        if (driver_report_catcher.invalid_query_count != 1 ||
            driver_report_catcher.parse_error_count != 3 ||
            driver_report_catcher.report_ids.size() != 4)
            `uvm_fatal("TLPQ_DRIVER_REPORTS", $sformatf(
                "malformed report counts invalid/parse/total=%0d/%0d/%0d",
                driver_report_catcher.invalid_query_count,
                driver_report_catcher.parse_error_count,
                driver_report_catcher.report_ids.size()))
        disable tlpq_conformance_watchdog;
        uvm_report_cb::delete(null, driver_report_catcher);
        `uvm_info("TLPQ_DRIVER_EVIDENCE",
            {"dual initial=31/tail=001f, batch-one refill/wrap=8000, ",
             "Host/Switch fixed Poll+IRQ, 1us watchdog, malformed and ",
             "reset/cleanup ACK races completed through real GQ engines"},
            UVM_LOW)

        phase.drop_objection(this);
    endtask
endclass

`endif
