// tb/tests/msgq_driver_conformance_test.sv: UVM 测试 msgq_driver_conformance_test：验证对应队列组件的定向行为和接口契约。
`ifndef MSGQ_DRIVER_CONFORMANCE_TEST_SV
`define MSGQ_DRIVER_CONFORMANCE_TEST_SV

class msgq_driver_raw_entry extends msgq_raw_entry;
    `uvm_object_utils(msgq_driver_raw_entry)

    function new(string name = "msgq_driver_raw_entry");
        super.new(name);
    endfunction
endclass

class msgq_driver_raw_factory extends msgq_entry_factory;
    `uvm_object_utils(msgq_driver_raw_factory)

    function new(string name = "msgq_driver_raw_factory");
        super.new(name);
    endfunction

    virtual function msgq_entry_base create_entry(
        int unsigned queue_id, gq_logical_seq_t logical_seq,
        int unsigned entry_size);
        msgq_driver_raw_entry entry;

        entry = msgq_driver_raw_entry::type_id::create(
            $sformatf("driver_raw_%0d_%0d", queue_id, logical_seq));
        return entry;
    endfunction
endclass

class msgq_driver_observation extends uvm_object;
    `uvm_object_utils(msgq_driver_observation)

    gq_logical_seq_t logical_seq;
    byte raw_bytes[];
    bit is_mac;
    bit is_timestamp;
    bit is_raw;
    bit [31:0] hash_key_l;
    bit [28:0] hash_key_h;
    bit [8:0] mac_act_idx;
    bit [39:0] timestamp;
    bit [15:0] timestamp_tag;
    bit [1:0] timestamp_type;
    bit [3:0] source_port;
    msgq_format_profile_e format_profile;

    function new(string name = "msgq_driver_observation");
        super.new(name);
        logical_seq = 0;
        raw_bytes = new[0];
        is_mac = 0;
        is_timestamp = 0;
        is_raw = 0;
        hash_key_l = 0;
        hash_key_h = 0;
        mac_act_idx = 0;
        timestamp = 0;
        timestamp_tag = 0;
        timestamp_type = 0;
        source_port = 0;
        format_profile = MSGQ_PROFILE_EMP_ACTIVE;
    endfunction
endclass

class msgq_driver_collector extends uvm_component;
    `uvm_component_utils(msgq_driver_collector)

    uvm_analysis_imp #(gq_desc_base, msgq_driver_collector) analysis_export;
    msgq_driver_observation observations[$];

    function new(string name = "msgq_driver_collector",
                 uvm_component parent = null);
        super.new(name, parent);
        analysis_export = new("analysis_export", this);
    endfunction

    function void clear();
        observations.delete();
    endfunction

    function void write(gq_desc_base desc);
        msgq_entry_base entry;
        msgq_mac_age_entry mac_entry;
        msgq_1588_entry timestamp_entry;
        msgq_driver_raw_entry raw_entry;
        msgq_driver_observation observation;

        if (!$cast(entry, desc))
            `uvm_fatal("MSGQ_DRIVER_DELIVERY",
                       "completion callback was not an MSGQ entry")
        observation = msgq_driver_observation::type_id::create(
            $sformatf("observation_%0d", observations.size()));
        observation.logical_seq = entry.logical_seq;
        observation.raw_bytes = new[entry.raw_bytes.size()];
        foreach (entry.raw_bytes[i])
            observation.raw_bytes[i] = entry.raw_bytes[i];

        if ($cast(mac_entry, desc)) begin
            observation.is_mac = 1;
            observation.hash_key_l = mac_entry.hash_key_l;
            observation.hash_key_h = mac_entry.hash_key_h;
            observation.mac_act_idx = mac_entry.mac_act_idx;
        end else if ($cast(timestamp_entry, desc)) begin
            observation.is_timestamp = 1;
            observation.timestamp = timestamp_entry.timestamp;
            observation.timestamp_tag = timestamp_entry.timestamp_tag;
            observation.timestamp_type = timestamp_entry.timestamp_type;
            observation.source_port = timestamp_entry.source_port;
            observation.format_profile = timestamp_entry.format_profile;
        end else if ($cast(raw_entry, desc)) begin
            observation.is_raw = 1;
        end else begin
            `uvm_fatal("MSGQ_DRIVER_DELIVERY",
                       "completion callback had an unexpected MSGQ subtype")
        end
        observations.push_back(observation);
    endfunction
endclass

class msgq_driver_query_catcher extends uvm_report_catcher;
    `uvm_object_utils(msgq_driver_query_catcher)

    int unsigned invalid_query_count;

    function new(string name = "msgq_driver_query_catcher");
        super.new(name);
        invalid_query_count = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_WARNING &&
            get_id() == "GQ_COMPLETION_QUERY") begin
            invalid_query_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class msgq_driver_conformance_test extends uvm_test;
    `uvm_component_utils(msgq_driver_conformance_test)

    localparam int unsigned MAC_IRQ_Q = 0;
    localparam int unsigned MAC_POLL_Q = 1;
    localparam int unsigned EMP_WATCHDOG_Q = 2;
    localparam int unsigned LINUX_SPURIOUS_Q = 3;
    localparam int unsigned INVALID_PTR_Q = 4;
    localparam int unsigned READ_FAILURE_Q = 5;
    localparam int unsigned RESET_RACE_Q = 6;
    localparam int unsigned RAW_Q = 7;
    localparam int unsigned QUEUE_COUNT = 8;

    host_mem_manager mem;
    msgq_mock_adapter adapter;
    msgq_mock_dut dut;
    msgq_env_cfg env_cfg;
    msgq_driver_raw_factory raw_factory;
    gq_queue_cfg cfgs[int unsigned];
    gq_queue_engine engines[int unsigned];
    uvm_analysis_port #(gq_desc_base) completion_ports[int unsigned];
    msgq_driver_collector collectors[int unsigned];
    bit worker_started[int unsigned];
    bit worker_returned[int unsigned];
    bit reset_drain_returned;

    function new(string name = "msgq_driver_conformance_test",
                 uvm_component parent = null);
        super.new(name, parent);
        reset_drain_returned = 0;
    endfunction

    function void make_mac_bytes(
        bit [31:0] hash_key_l, bit [28:0] hash_key_h,
        bit [8:0] mac_act_idx, ref byte data[]);
        data = new[16];
        data[0] = hash_key_l[7:0];
        data[1] = hash_key_l[15:8];
        data[2] = hash_key_l[23:16];
        data[3] = hash_key_l[31:24];
        data[4] = hash_key_h[7:0];
        data[5] = hash_key_h[15:8];
        data[6] = hash_key_h[23:16];
        data[7] = {3'b000, hash_key_h[28:24]};
        data[8] = mac_act_idx[7:0];
        data[9] = {7'b0000000, mac_act_idx[8]};
        for (int unsigned i = 10; i < 16; i++)
            data[i] = 0;
    endfunction

    function void make_timestamp_bytes(
        bit [39:0] timestamp, bit [15:0] tag, bit [1:0] timestamp_type,
        bit [3:0] source_port, ref byte data[]);
        bit [63:0] packed_entry;

        packed_entry = 0;
        packed_entry[39:0] = timestamp;
        packed_entry[55:40] = tag;
        packed_entry[57:56] = timestamp_type;
        packed_entry[61:58] = source_port;
        data = new[8];
        foreach (data[i])
            data[i] = packed_entry[(i * 8) +: 8];
    endfunction

    function void make_raw_bytes(byte seed, ref byte data[]);
        data = new[24];
        foreach (data[i])
            data[i] = seed + byte'(i);
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

    function void configure_fixed_detection(gq_queue_cfg queue_cfg,
                                            gq_wait_mode_e wait_mode);
        queue_cfg.wait_mode = wait_mode;
        queue_cfg.poll_policy = GQ_POLL_FIXED;
        queue_cfg.poll_min_interval = 10ns;
        queue_cfg.poll_max_interval = 10ns;
        queue_cfg.poll_backoff_factor = 2;
        queue_cfg.irq_watchdog_interval = 1us;
    endfunction

    function void build_phase(uvm_phase phase);
        string reason;
        string key;
        string engine_name;
        string collector_name;

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_d000_0000,
                        64'h0000_0001_d0ff_ffff, MODE_LINEAR, 16);
        adapter = msgq_mock_adapter::type_id::create("adapter");
        dut = msgq_mock_dut::type_id::create("dut");
        dut.mem = mem;
        dut.adapter = adapter;
        raw_factory = msgq_driver_raw_factory::type_id::create("raw_factory");
        env_cfg = msgq_env_cfg::type_id::create("env_cfg");
        env_cfg.mem = mem;
        env_cfg.adapter = adapter;

        if (!env_cfg.add_msgq(MAC_POLL_Q, MSGQ_MAC_AGE,
                              MSGQ_PROFILE_LINUX_HEADER, 0, 0, null,
                              reason) ||
            !env_cfg.add_msgq(MAC_IRQ_Q, MSGQ_MAC_AGE,
                              MSGQ_PROFILE_LINUX_HEADER, 0, 0, null,
                              reason) ||
            !env_cfg.add_msgq(EMP_WATCHDOG_Q, MSGQ_1588,
                              MSGQ_PROFILE_EMP_ACTIVE, 0, 0, null,
                              reason) ||
            !env_cfg.add_msgq(LINUX_SPURIOUS_Q, MSGQ_1588,
                              MSGQ_PROFILE_LINUX_HEADER, 0, 0, null,
                              reason) ||
            !env_cfg.add_msgq(INVALID_PTR_Q, MSGQ_MAC_AGE,
                              MSGQ_PROFILE_LINUX_HEADER, 0, 0, null,
                              reason) ||
            !env_cfg.add_msgq(READ_FAILURE_Q, MSGQ_FSE,
                              MSGQ_PROFILE_EMP_ACTIVE, 8, 24, raw_factory,
                              reason) ||
            !env_cfg.add_msgq(RESET_RACE_Q, MSGQ_FSE,
                              MSGQ_PROFILE_EMP_ACTIVE, 8, 24, raw_factory,
                              reason) ||
            !env_cfg.add_msgq(RAW_Q, MSGQ_FSE,
                              MSGQ_PROFILE_EMP_ACTIVE, 8, 24, raw_factory,
                              reason))
            `uvm_fatal("MSGQ_DRIVER_BUILD",
                       {"valid conformance profile rejected: ", reason})

        for (int unsigned queue_id = 0; queue_id < QUEUE_COUNT;
             queue_id++) begin
            key = gq_queue_key(GQ_RX, queue_id);
            cfgs[queue_id] = env_cfg.queues[key];
            configure_fixed_detection(
                cfgs[queue_id], queue_id == MAC_POLL_Q ||
                                queue_id == INVALID_PTR_Q ||
                                queue_id == READ_FAILURE_Q ||
                                queue_id == RESET_RACE_Q ||
                                queue_id == RAW_Q ? GQ_POLL : GQ_IRQ);
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
            collectors[queue_id] = msgq_driver_collector::type_id::create(
                collector_name, this);
            completion_ports[queue_id] = new(
                $sformatf("completion_port_%0d", queue_id), this);
            worker_started[queue_id] = 0;
            worker_returned[queue_id] = 0;
        end

        if (!env_cfg.validate(reason))
            `uvm_fatal("MSGQ_DRIVER_BUILD",
                       {"fixed conformance configuration rejected: ", reason})
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        for (int unsigned queue_id = 0; queue_id < QUEUE_COUNT;
             queue_id++) begin
            engines[queue_id].bind_completion_port(
                completion_ports[queue_id]);
            completion_ports[queue_id].connect(
                collectors[queue_id].analysis_export);
        end
    endfunction

    task setup_queue(int unsigned queue_id);
        gq_request request;
        gq_response response;
        string expected_trace[$] = '{"RESET", "CONFIGURE", "ENABLE",
                                     "PUBLISH"};

        adapter.clear_trace();
        adapter.record_reset(queue_id);
        engines[queue_id].initialize();
        adapter.record_enable(queue_id);
        dut.set_current_ptr(queue_id, 0);
        request = gq_request::type_id::create(
            $sformatf("start_queue_%0d", queue_id));
        request.kind = GQ_START_RX;
        request.set_refill_profile(env_cfg.get_refill_profile(queue_id));
        engines[queue_id].start_rx(request, response);

        if (response == null || response.status != GQ_OK ||
            response.committed_count != cfgs[queue_id].depth - 1)
            `uvm_fatal("MSGQ_DRIVER_START", $sformatf(
                "queue %0d did not activate depth-minus-one entries",
                queue_id))
        if (adapter.trace != expected_trace)
            `uvm_fatal("MSGQ_DRIVER_TRACE", $sformatf(
                "queue %0d setup trace was not RESET,CONFIGURE,ENABLE,PUBLISH",
                queue_id))
        if (adapter.reset_count[queue_id] != 1 ||
            adapter.configure_count[queue_id] != 1 ||
            adapter.enable_count[queue_id] != 1 ||
            adapter.configured_base[queue_id] !=
                engines[queue_id].ring_base() ||
            adapter.configured_depth[queue_id] != cfgs[queue_id].depth ||
            adapter.configured_entry_size[queue_id] !=
                cfgs[queue_id].desc_size ||
            adapter.published_tails[queue_id].size() != 1 ||
            adapter.published_tails[queue_id][0] !=
                cfgs[queue_id].depth - 1)
            `uvm_fatal("MSGQ_DRIVER_SETUP_ARGS", $sformatf(
                "queue %0d setup arguments/counters diverged", queue_id))
    endtask

    task start_worker(int unsigned queue_id);
        worker_started[queue_id] = 1;
        fork
            begin
                automatic int unsigned worker_queue = queue_id;
                engines[worker_queue].run_completion_monitor();
                worker_returned[worker_queue] = 1;
            end
        join_none
    endtask

    task wait_for_observations(int unsigned queue_id,
                               int unsigned expected_count,
                               string label,
                               int unsigned limit = 400);
        for (int unsigned observation = 0; observation < limit;
             observation++) begin
            #10ns;
            if (collectors[queue_id].observations.size() >= expected_count)
                return;
        end
        `uvm_fatal("MSGQ_DRIVER_STALL", $sformatf(
            "%s delivered %0d entries, expected %0d", label,
            collectors[queue_id].observations.size(), expected_count))
    endtask

    task wait_for_irq_waits(int unsigned queue_id,
                            int unsigned expected_count,
                            string label);
        for (int unsigned observation = 0; observation < 400;
             observation++) begin
            #10ns;
            if (adapter.wait_irq_count[queue_id] >= expected_count)
                return;
        end
        `uvm_fatal("MSGQ_DRIVER_STALL", $sformatf(
            "%s registered %0d IRQ waits, expected %0d", label,
            adapter.wait_irq_count[queue_id], expected_count))
    endtask

    task wait_for_ack_count(int unsigned queue_id,
                            int unsigned expected_count,
                            string label);
        for (int unsigned observation = 0; observation < 400;
             observation++) begin
            #10ns;
            if (adapter.ack_irq_count[queue_id] >= expected_count)
                return;
        end
        `uvm_fatal("MSGQ_DRIVER_STALL", $sformatf(
            "%s observed %0d IRQ ACKs, expected %0d", label,
            adapter.ack_irq_count[queue_id], expected_count))
    endtask

    task write_slot(int unsigned queue_id, int unsigned slot,
                    input byte data[]);
        if (!dut.write_slot(engines[queue_id], queue_id, slot,
                            cfgs[queue_id].depth,
                            cfgs[queue_id].desc_size, data))
            `uvm_fatal("MSGQ_DRIVER_DUT", $sformatf(
                "DUT rejected queue %0d slot %0d write", queue_id, slot))
    endtask

    function void check_mac_observation(
        msgq_driver_observation observation,
        gq_logical_seq_t logical_seq,
        bit [31:0] hash_key_l, bit [28:0] hash_key_h,
        bit [8:0] mac_act_idx, input byte expected_raw[]);
        if (observation == null || !observation.is_mac ||
            observation.is_timestamp || observation.is_raw ||
            observation.logical_seq != logical_seq ||
            observation.hash_key_l != hash_key_l ||
            observation.hash_key_h != hash_key_h ||
            observation.mac_act_idx != mac_act_idx ||
            !bytes_equal(observation.raw_bytes, expected_raw))
            `uvm_fatal("MSGQ_DRIVER_MAC_DECODE", $sformatf(
                "MAC observation for logical sequence %0d diverged",
                logical_seq))
    endfunction

    function void check_timestamp_observation(
        msgq_driver_observation observation,
        gq_logical_seq_t logical_seq,
        bit [39:0] timestamp, bit [15:0] tag,
        bit [1:0] timestamp_type, bit [3:0] source_port,
        msgq_format_profile_e format_profile,
        input byte expected_raw[]);
        if (observation == null || !observation.is_timestamp ||
            observation.is_mac || observation.is_raw ||
            observation.logical_seq != logical_seq ||
            observation.timestamp != timestamp ||
            observation.timestamp_tag != tag ||
            observation.timestamp_type != timestamp_type ||
            observation.source_port != source_port ||
            observation.format_profile != format_profile ||
            !bytes_equal(observation.raw_bytes, expected_raw))
            `uvm_fatal("MSGQ_DRIVER_1588_DECODE", $sformatf(
                "1588 observation for logical sequence %0d diverged",
                logical_seq))
    endfunction

    task run_mac_scenario(int unsigned queue_id, gq_wait_mode_e wait_mode);
        byte warmup[];
        byte entry_126[];
        byte entry_127[];
        byte entry_128[];
        byte ring_before[];
        byte ring_after[];
        int unsigned ack_before;
        int unsigned wait_before;

        setup_queue(queue_id);
        if (cfgs[queue_id].depth != 128 ||
            cfgs[queue_id].desc_size != 16 ||
            cfgs[queue_id].wait_mode != wait_mode ||
            cfgs[queue_id].poll_policy != GQ_POLL_FIXED ||
            cfgs[queue_id].poll_min_interval != 10ns ||
            cfgs[queue_id].poll_max_interval != 10ns)
            `uvm_fatal("MSGQ_DRIVER_MAC_PROFILE",
                       "MAC fixed detection profile did not match 128x16/10ns")

        for (int unsigned slot = 0; slot < 126; slot++) begin
            make_mac_bytes(32'h1000_0000 + slot, slot, slot,
                           warmup);
            write_slot(queue_id, slot, warmup);
        end
        start_worker(queue_id);
        if (wait_mode == GQ_IRQ)
            wait_for_irq_waits(queue_id, 1, "MAC warm-up");
        dut.set_current_ptr(queue_id, 126);
        if (wait_mode == GQ_IRQ)
            dut.trigger_irq(queue_id);
        wait_for_observations(queue_id, 126, "MAC warm-up");
        if (collectors[queue_id].observations.size() != 126 ||
            engines[queue_id].head_seq() != 126 ||
            engines[queue_id].tail_seq() != 253 ||
            engines[queue_id].outstanding_count() != 127)
            `uvm_fatal("MSGQ_DRIVER_WARMUP",
                       "public current-pointer warm-up did not consume 0..125")

        collectors[queue_id].clear();
        make_mac_bytes(32'h1260_00a1, 29'h0126_001, 9'h126,
                       entry_126);
        make_mac_bytes(32'h1270_00b2, 29'h0127_002, 9'h127,
                       entry_127);
        make_mac_bytes(32'h1280_00c3, 29'h0128_003, 9'h128,
                       entry_128);
        write_slot(queue_id, 126, entry_126);
        write_slot(queue_id, 127, entry_127);
        write_slot(queue_id, 0, entry_128);
        dut.snapshot_ring(engines[queue_id], cfgs[queue_id].depth,
                          cfgs[queue_id].desc_size, ring_before);
        ack_before = adapter.ack_irq_count[queue_id];
        wait_before = adapter.wait_irq_count[queue_id];
        if (wait_mode == GQ_IRQ)
            wait_for_irq_waits(queue_id, wait_before + 1, "MAC wrap");
        dut.set_current_ptr(queue_id, 1);
        if (wait_mode == GQ_IRQ)
            dut.trigger_irq(queue_id);
        wait_for_observations(queue_id, 3, "MAC wrap");

        if (collectors[queue_id].observations.size() != 3)
            `uvm_fatal("MSGQ_DRIVER_MAC_COUNT",
                       "MAC wrap delivered other than exactly three entries")
        check_mac_observation(collectors[queue_id].observations[0], 126,
                              32'h1260_00a1, 29'h0126_001, 9'h126,
                              entry_126);
        check_mac_observation(collectors[queue_id].observations[1], 127,
                              32'h1270_00b2, 29'h0127_002, 9'h127,
                              entry_127);
        check_mac_observation(collectors[queue_id].observations[2], 128,
                              32'h1280_00c3, 29'h0128_003, 9'h128,
                              entry_128);
        dut.snapshot_ring(engines[queue_id], cfgs[queue_id].depth,
                          cfgs[queue_id].desc_size, ring_after);
        if (!bytes_equal(ring_before, ring_after) ||
            adapter.published_tails[queue_id].size() != 1 ||
            dut.pointer_history[queue_id].size() != 3 ||
            dut.pointer_history[queue_id][0] != 0 ||
            dut.pointer_history[queue_id][1] != 126 ||
            dut.pointer_history[queue_id][2] != 1 ||
            engines[queue_id].head_seq() != 129 ||
            engines[queue_id].tail_seq() != 256 ||
            engines[queue_id].outstanding_count() != 127)
            `uvm_fatal("MSGQ_DRIVER_AUTO_RECYCLE",
                       "MAC auto-recycle changed the ring/publish history/window")
        if ((wait_mode == GQ_IRQ &&
             adapter.ack_irq_count[queue_id] != ack_before + 1) ||
            (wait_mode == GQ_POLL &&
             adapter.ack_irq_count[queue_id] != ack_before))
            `uvm_fatal("MSGQ_DRIVER_MAC_ACK",
                       "MAC wrap ACK count did not match detection mode")
    endtask

    task run_emp_watchdog_scenario();
        byte warmup[];
        byte entry_31[];
        byte entry_32[];
        byte ring_before[];
        byte ring_after[];
        int unsigned ack_before;
        int unsigned irq_before;

        setup_queue(EMP_WATCHDOG_Q);
        if (cfgs[EMP_WATCHDOG_Q].depth != 32 ||
            cfgs[EMP_WATCHDOG_Q].desc_size != 8 ||
            cfgs[EMP_WATCHDOG_Q].wait_mode != GQ_IRQ ||
            cfgs[EMP_WATCHDOG_Q].irq_watchdog_interval != 1us ||
            env_cfg.get_refill_profile(EMP_WATCHDOG_Q).format_profile !=
                MSGQ_PROFILE_EMP_ACTIVE)
            `uvm_fatal("MSGQ_DRIVER_EMP_PROFILE",
                       "EMP 1588 profile did not match 32x8 IRQ/1us")

        for (int unsigned slot = 0; slot < 31; slot++) begin
            make_timestamp_bytes(40'h0100_0000_00 + slot,
                                 16'h1000 + slot, 2'b00, 4'h1, warmup);
            write_slot(EMP_WATCHDOG_Q, slot, warmup);
        end
        start_worker(EMP_WATCHDOG_Q);
        wait_for_irq_waits(EMP_WATCHDOG_Q, 1, "EMP warm-up");
        dut.set_current_ptr(EMP_WATCHDOG_Q, 31);
        dut.trigger_irq(EMP_WATCHDOG_Q);
        wait_for_observations(EMP_WATCHDOG_Q, 31, "EMP warm-up");
        collectors[EMP_WATCHDOG_Q].clear();

        make_timestamp_bytes(40'h5a12_3456_78, 16'hbeef, 2'b10, 4'ha,
                             entry_31);
        make_timestamp_bytes(40'h6b89_abcd_ef, 16'hcafe, 2'b01, 4'h3,
                             entry_32);
        write_slot(EMP_WATCHDOG_Q, 31, entry_31);
        write_slot(EMP_WATCHDOG_Q, 0, entry_32);
        dut.snapshot_ring(engines[EMP_WATCHDOG_Q], 32, 8, ring_before);
        wait_for_irq_waits(EMP_WATCHDOG_Q, 2, "EMP lost IRQ watchdog");
        ack_before = adapter.ack_irq_count[EMP_WATCHDOG_Q];
        irq_before = adapter.trigger_irq_count[EMP_WATCHDOG_Q];
        dut.set_current_ptr(EMP_WATCHDOG_Q, 1);
        wait_for_observations(EMP_WATCHDOG_Q, 2,
                              "EMP lost IRQ watchdog", 300);

        if (collectors[EMP_WATCHDOG_Q].observations.size() != 2)
            `uvm_fatal("MSGQ_DRIVER_EMP_COUNT",
                       "EMP wrap delivered other than exactly two entries")
        check_timestamp_observation(
            collectors[EMP_WATCHDOG_Q].observations[0], 31,
            40'h5a12_3456_78, 16'hbeef, 2'b10, 4'ha,
            MSGQ_PROFILE_EMP_ACTIVE, entry_31);
        check_timestamp_observation(
            collectors[EMP_WATCHDOG_Q].observations[1], 32,
            40'h6b89_abcd_ef, 16'hcafe, 2'b01, 4'h3,
            MSGQ_PROFILE_EMP_ACTIVE, entry_32);
        dut.snapshot_ring(engines[EMP_WATCHDOG_Q], 32, 8, ring_after);
        if (!bytes_equal(ring_before, ring_after) ||
            adapter.ack_irq_count[EMP_WATCHDOG_Q] != ack_before ||
            adapter.trigger_irq_count[EMP_WATCHDOG_Q] != irq_before ||
            dut.pointer_history[EMP_WATCHDOG_Q].size() != 3 ||
            dut.pointer_history[EMP_WATCHDOG_Q][0] != 0 ||
            dut.pointer_history[EMP_WATCHDOG_Q][1] != 31 ||
            dut.pointer_history[EMP_WATCHDOG_Q][2] != 1 ||
            adapter.published_tails[EMP_WATCHDOG_Q].size() != 1)
            `uvm_fatal("MSGQ_DRIVER_WATCHDOG",
                       "lost IRQ did not recover at watchdog with zero ACK")
    endtask

    task run_linux_spurious_scenario();
        string reason;
        int unsigned ack_before;
        int unsigned reads_before;

        setup_queue(LINUX_SPURIOUS_Q);
        if (!env_cfg.get_refill_profile(LINUX_SPURIOUS_Q).validate(
                cfgs[LINUX_SPURIOUS_Q].depth, reason) ||
            cfgs[LINUX_SPURIOUS_Q].depth != 128 ||
            cfgs[LINUX_SPURIOUS_Q].desc_size != 8 ||
            env_cfg.get_refill_profile(LINUX_SPURIOUS_Q).format_profile !=
                MSGQ_PROFILE_LINUX_HEADER)
            `uvm_fatal("MSGQ_DRIVER_LINUX_PROFILE",
                       {"Linux 1588 profile invalid: ", reason})
        start_worker(LINUX_SPURIOUS_Q);
        wait_for_irq_waits(LINUX_SPURIOUS_Q, 1, "Linux spurious IRQ");
        ack_before = adapter.ack_irq_count[LINUX_SPURIOUS_Q];
        reads_before = adapter.read_current_ptr_count[LINUX_SPURIOUS_Q];
        dut.trigger_irq(LINUX_SPURIOUS_Q);
        wait_for_ack_count(LINUX_SPURIOUS_Q, ack_before + 1,
                           "Linux spurious IRQ");
        for (int unsigned observation = 0; observation < 100;
             observation++) begin
            #10ns;
            if (adapter.read_current_ptr_count[LINUX_SPURIOUS_Q] >
                reads_before)
                break;
        end
        if (adapter.ack_irq_count[LINUX_SPURIOUS_Q] != ack_before + 1 ||
            adapter.read_current_ptr_count[LINUX_SPURIOUS_Q] !=
                reads_before + 1 ||
            collectors[LINUX_SPURIOUS_Q].observations.size() != 0 ||
            engines[LINUX_SPURIOUS_Q].head_seq() != 0)
            `uvm_fatal("MSGQ_DRIVER_SPURIOUS",
                       "spurious IRQ was not ACKed once with zero delivery")
    endtask

    task run_invalid_query_scenarios();
        msgq_driver_query_catcher catcher;

        setup_queue(INVALID_PTR_Q);
        setup_queue(READ_FAILURE_Q);
        catcher = msgq_driver_query_catcher::type_id::create("catcher");
        uvm_report_cb::add(null, catcher);
        dut.set_current_ptr(INVALID_PTR_Q, cfgs[INVALID_PTR_Q].depth);
        engines[INVALID_PTR_Q].drain_completed();
        dut.fail_next_current_ptr_read(READ_FAILURE_Q);
        engines[READ_FAILURE_Q].drain_completed();
        uvm_report_cb::delete(null, catcher);

        if (catcher.invalid_query_count != 2 ||
            adapter.failed_current_ptr_read_count[READ_FAILURE_Q] != 1 ||
            collectors[INVALID_PTR_Q].observations.size() != 0 ||
            collectors[READ_FAILURE_Q].observations.size() != 0 ||
            engines[INVALID_PTR_Q].head_seq() != 0 ||
            engines[READ_FAILURE_Q].head_seq() != 0)
            `uvm_fatal("MSGQ_DRIVER_INVALID_QUERY", $sformatf(
                "invalid/read-failure query handling diverged: caught=%0d",
                catcher.invalid_query_count))
    endtask

    task run_raw_scenario();
        byte entry_0[];
        byte entry_1[];
        byte ring_before[];
        byte ring_after[];

        setup_queue(RAW_Q);
        make_raw_bytes(8'h20, entry_0);
        make_raw_bytes(8'h80, entry_1);
        write_slot(RAW_Q, 0, entry_0);
        write_slot(RAW_Q, 1, entry_1);
        dut.snapshot_ring(engines[RAW_Q], 8, 24, ring_before);
        dut.set_current_ptr(RAW_Q, 2);
        engines[RAW_Q].drain_completed();
        dut.snapshot_ring(engines[RAW_Q], 8, 24, ring_after);

        if (collectors[RAW_Q].observations.size() != 2 ||
            !collectors[RAW_Q].observations[0].is_raw ||
            !collectors[RAW_Q].observations[1].is_raw ||
            collectors[RAW_Q].observations[0].logical_seq != 0 ||
            collectors[RAW_Q].observations[1].logical_seq != 1 ||
            !bytes_equal(collectors[RAW_Q].observations[0].raw_bytes,
                         entry_0) ||
            !bytes_equal(collectors[RAW_Q].observations[1].raw_bytes,
                         entry_1) ||
            !bytes_equal(ring_before, ring_after) ||
            engines[RAW_Q].head_seq() != 2 ||
            engines[RAW_Q].tail_seq() != 9 ||
            dut.pointer_history[RAW_Q].size() != 2 ||
            dut.pointer_history[RAW_Q][0] != 0 ||
            dut.pointer_history[RAW_Q][1] != 2 ||
            adapter.current_ptr_value[RAW_Q] != 2 ||
            adapter.published_tails[RAW_Q].size() != 1)
            `uvm_fatal("MSGQ_DRIVER_RAW",
                       "raw 24-byte pointer/byte-only contract diverged")
    endtask

    task run_reset_race_scenario();
        byte entry_0[];
        longint unsigned starting_epoch;

        setup_queue(RESET_RACE_Q);
        make_raw_bytes(8'hd0, entry_0);
        write_slot(RESET_RACE_Q, 0, entry_0);
        dut.set_current_ptr(RESET_RACE_Q, 1);
        adapter.block_next_current_ptr_read(RESET_RACE_Q);
        reset_drain_returned = 0;
        fork
            begin
                engines[RESET_RACE_Q].drain_completed();
                reset_drain_returned = 1;
            end
        join_none
        for (int unsigned observation = 0; observation < 100;
             observation++) begin
            #10ns;
            if (adapter.blocked_current_ptr_read_count[RESET_RACE_Q] == 1)
                break;
        end
        if (adapter.blocked_current_ptr_read_count[RESET_RACE_Q] != 1)
            `uvm_fatal("MSGQ_DRIVER_RESET_BLOCK",
                       "current-pointer read did not block")

        starting_epoch = engines[RESET_RACE_Q].reset_epoch();
        engines[RESET_RACE_Q].begin_reset();
        if (engines[RESET_RACE_Q].reset_epoch() != starting_epoch + 1)
            `uvm_fatal("MSGQ_DRIVER_RESET_EPOCH",
                       "reset did not advance while current-pointer read blocked")
        adapter.set_current_ptr(RESET_RACE_Q, 0, 0);
        adapter.release_current_ptr_read(RESET_RACE_Q);
        for (int unsigned observation = 0; observation < 100;
             observation++) begin
            #10ns;
            if (reset_drain_returned)
                break;
        end
        if (!reset_drain_returned ||
            collectors[RESET_RACE_Q].observations.size() != 0 ||
            engines[RESET_RACE_Q].head_seq() != 0)
            `uvm_fatal("MSGQ_DRIVER_RESET_STALE",
                       "stale blocked current-pointer result was delivered")
        engines[RESET_RACE_Q].finish_reset();
        if (engines[RESET_RACE_Q].outstanding_count() != 0 ||
            engines[RESET_RACE_Q].ring_base() != 0 ||
            adapter.disable_count[RESET_RACE_Q] != 1)
            `uvm_fatal("MSGQ_DRIVER_RESET_CLEANUP",
                       "reset did not release queue state exactly once")
    endtask

    task cleanup_all();
        for (int unsigned queue_id = 0; queue_id < QUEUE_COUNT;
             queue_id++)
            engines[queue_id].cleanup();
        for (int unsigned queue_id = 0; queue_id < QUEUE_COUNT;
             queue_id++) begin
            if (!worker_started[queue_id])
                continue;
            for (int unsigned observation = 0; observation < 200;
                 observation++) begin
                #10ns;
                if (worker_returned[queue_id])
                    break;
            end
            if (!worker_returned[queue_id])
                `uvm_fatal("MSGQ_DRIVER_WORKER",
                           $sformatf("queue %0d worker did not terminate",
                                     queue_id))
        end
        mem.leak_check(`__FILE__, `__LINE__);
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        fork : test_watchdog
            begin
                #50us;
                `uvm_fatal("MSGQ_DRIVER_TEST_TIMEOUT",
                           "driver conformance test exceeded 50us")
            end
        join_none

        run_mac_scenario(MAC_IRQ_Q, GQ_IRQ);
        run_mac_scenario(MAC_POLL_Q, GQ_POLL);
        run_emp_watchdog_scenario();
        run_linux_spurious_scenario();
        run_invalid_query_scenarios();
        run_raw_scenario();
        run_reset_race_scenario();
        cleanup_all();

        disable test_watchdog;
        phase.drop_objection(this);
    endtask
endclass

`endif
