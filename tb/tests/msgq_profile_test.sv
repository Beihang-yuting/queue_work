// tb/tests/msgq_profile_test.sv: UVM 测试 msgq_profile_test：验证对应队列组件的定向行为和接口契约。
`ifndef MSGQ_PROFILE_TEST_SV
`define MSGQ_PROFILE_TEST_SV

class msgq_test_raw_entry extends msgq_raw_entry;
    `uvm_object_utils(msgq_test_raw_entry)

    int unsigned factory_queue_id;

    function new(string name = "msgq_test_raw_entry");
        super.new(name);
        factory_queue_id = 0;
    endfunction
endclass

class msgq_test_entry_factory extends msgq_entry_factory;
    `uvm_object_utils(msgq_test_entry_factory)

    int unsigned last_queue_id;
    gq_logical_seq_t last_logical_seq;
    int unsigned last_entry_size;
    int unsigned create_count;

    function new(string name = "msgq_test_entry_factory");
        super.new(name);
        last_queue_id   = 0;
        last_logical_seq = 0;
        last_entry_size = 0;
        create_count    = 0;
    endfunction

    virtual function msgq_entry_base create_entry(
        int unsigned queue_id, gq_logical_seq_t logical_seq,
        int unsigned entry_size);
        msgq_test_raw_entry entry;

        last_queue_id    = queue_id;
        last_logical_seq = logical_seq;
        last_entry_size  = entry_size;
        create_count++;
        entry = msgq_test_raw_entry::type_id::create(
            $sformatf("raw_%0d_entry_%0d", queue_id, logical_seq));
        entry.factory_queue_id = queue_id;
        return entry;
    endfunction
endclass

class msgq_profile_capture_driver extends uvm_driver #(gq_request, gq_response);
    `uvm_component_utils(msgq_profile_capture_driver)

    gq_request captured_request;

    function new(string name = "msgq_profile_capture_driver",
                 uvm_component parent = null);
        super.new(name, parent);
        captured_request = null;
    endfunction

    task run_phase(uvm_phase phase);
        gq_request request;
        gq_response response;

        seq_item_port.get_next_item(request);
        captured_request = request;
        response = gq_response::type_id::create("response");
        response.set_id_info(request);
        response.status          = GQ_OK;
        response.committed_count = 0;
        seq_item_port.item_done(response);
    endtask
endclass

class msgq_profile_test extends uvm_test;
    `uvm_component_utils(msgq_profile_test)

    host_mem_manager mem;
    msgq_mock_adapter adapter;
    msgq_env_cfg env_cfg;
    msgq_test_entry_factory raw_factory;
    gq_sequencer sequencer;
    msgq_profile_capture_driver driver;

    function new(string name = "msgq_profile_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void check_queue_defaults(
        int unsigned queue_id, int unsigned expected_depth,
        int unsigned expected_entry_size, msgq_kind_e expected_kind,
        msgq_format_profile_e expected_format);
        string key;
        gq_queue_cfg queue_cfg;
        msgq_refill_profile profile;
        msgq_ptr_codec installed_codec;
        msgq_completion installed_completion;
        string reason;

        key = gq_queue_key(GQ_RX, queue_id);
        if (!env_cfg.queues.exists(key) || env_cfg.queues[key] == null)
            `uvm_fatal("MSGQ_DEFAULT_QUEUE", {"missing queue ", key})
        queue_cfg = env_cfg.queues[key];
        if (queue_cfg.role != GQ_RX ||
            queue_cfg.depth != expected_depth ||
            queue_cfg.desc_size != expected_entry_size ||
            queue_cfg.alignment == 0 || queue_cfg.status_area_size != 0 ||
            queue_cfg.wait_mode != GQ_IRQ ||
            queue_cfg.poll_policy != GQ_POLL_ADAPTIVE ||
            queue_cfg.poll_min_interval != 50ns ||
            queue_cfg.poll_max_interval != 500ns ||
            queue_cfg.poll_backoff_factor != 2 ||
            queue_cfg.irq_watchdog_interval != 1us ||
            queue_cfg.completion_timeout != 0 ||
            queue_cfg.rx_slot_mode != GQ_RX_AUTO_RECYCLE)
            `uvm_fatal("MSGQ_DEFAULT_CFG", $sformatf(
                "queue %0d defaults do not match the business profile", queue_id))
        if (!$cast(installed_codec, queue_cfg.ptr_codec) ||
            !$cast(installed_completion, queue_cfg.completion_source) ||
            installed_completion.queue_id != queue_id)
            `uvm_fatal("MSGQ_DEFAULT_TYPES", $sformatf(
                "queue %0d did not install MSGQ codec/completion types", queue_id))

        profile = env_cfg.get_refill_profile(queue_id);
        if (profile == null || profile.kind != expected_kind ||
            profile.format_profile != expected_format ||
            profile.entry_size != expected_entry_size ||
            !profile.strict_reserved ||
            profile.initial_post_count != expected_depth - 1 ||
            profile.high_watermark != expected_depth - 1 ||
            profile.low_watermark != expected_depth - 2 ||
            profile.max_refill_batch != 0 ||
            !profile.validate(expected_depth, reason))
            `uvm_fatal("MSGQ_DEFAULT_REFILL", $sformatf(
                "queue %0d refill defaults are invalid: %s", queue_id, reason))
    endfunction

    function void check_factory_profile();
        msgq_refill_profile profile;
        gq_desc_base desc;
        msgq_test_raw_entry entry;
        byte packed_data[];
        byte wrong_size[] = new[23];
        byte expected[] = '{8'h00, 8'h01, 8'h02, 8'h03,
                            8'h04, 8'h05, 8'h06, 8'h07,
                            8'h08, 8'h09, 8'h0a, 8'h0b,
                            8'h0c, 8'h0d, 8'h0e, 8'h0f,
                            8'h10, 8'h11, 8'h12, 8'h13,
                            8'h14, 8'h15, 8'h16, 8'h17};
        string reason;

        profile = env_cfg.get_refill_profile(13);
        if (profile == null || profile.factory != raw_factory ||
            !profile.validate(64, reason))
            `uvm_fatal("MSGQ_RAW_PROFILE", {"valid raw profile rejected: ", reason})
        desc = profile.create_desc(13, 64'h0000_0001_0000_0005);
        if (!$cast(entry, desc) || entry == null)
            `uvm_fatal("MSGQ_RAW_FACTORY", "factory output type was not preserved")
        if (raw_factory.create_count != 1 || raw_factory.last_queue_id != 13 ||
            raw_factory.last_logical_seq != 64'h0000_0001_0000_0005 ||
            raw_factory.last_entry_size != 24 ||
            entry.factory_queue_id != 13 ||
            entry.logical_seq != 64'h0000_0001_0000_0005 ||
            entry.entry_size != 24)
            `uvm_fatal("MSGQ_RAW_ARGS",
                       "factory arguments and returned entry metadata diverged")
        entry.pack(packed_data);
        if (packed_data.size() != 24)
            `uvm_fatal("MSGQ_RAW_PACK", "raw factory entry packed wrong size")
        foreach (packed_data[i]) begin
            if (packed_data[i] !== 8'h00)
                `uvm_fatal("MSGQ_RAW_PACK", "raw factory entry was not cleared")
        end
        if (!entry.unpack(expected) || entry.raw_bytes != expected)
            `uvm_fatal("MSGQ_RAW_BYTES", "24-byte raw data was not preserved")
        if (entry.unpack(wrong_size) || entry.raw_bytes != expected)
            `uvm_fatal("MSGQ_RAW_SIZE",
                       "wrong-size raw data was accepted or changed prior data")
        if (!entry.is_complete(1'b0) || !entry.is_complete(1'b1) ||
            !entry.parse_completion())
            `uvm_fatal("MSGQ_RAW_COMPLETION",
                       "pointer-selected raw entry did not complete cleanly")
        if (entry.owned_allocation_count() != 0)
            `uvm_fatal("MSGQ_RAW_OWNERSHIP",
                       "raw factory entry unexpectedly owns an allocation")
    endfunction

    function void check_concrete_factory_output();
        msgq_refill_profile profile;
        gq_desc_base desc;
        msgq_mac_age_entry mac_entry;
        msgq_1588_entry timestamp_entry;

        profile = env_cfg.get_refill_profile(10);
        desc = profile.create_desc(10, 101);
        if (!$cast(mac_entry, desc) || mac_entry.entry_size != 16 ||
            mac_entry.logical_seq != 101 || !mac_entry.strict_reserved ||
            mac_entry.owned_allocation_count() != 0)
            `uvm_fatal("MSGQ_MAC_FACTORY",
                       "MAC profile did not create the exact standard entry")

        profile = env_cfg.get_refill_profile(11);
        desc = profile.create_desc(11, 102);
        if (!$cast(timestamp_entry, desc) || timestamp_entry.entry_size != 8 ||
            timestamp_entry.logical_seq != 102 ||
            timestamp_entry.format_profile != MSGQ_PROFILE_EMP_ACTIVE ||
            !timestamp_entry.strict_reserved ||
            timestamp_entry.owned_allocation_count() != 0)
            `uvm_fatal("MSGQ_EMP_FACTORY",
                       "EMP profile did not create the exact timestamp entry")

        profile = env_cfg.get_refill_profile(12);
        desc = profile.create_desc(12, 103);
        if (!$cast(timestamp_entry, desc) ||
            timestamp_entry.format_profile != MSGQ_PROFILE_LINUX_HEADER ||
            timestamp_entry.logical_seq != 103 ||
            timestamp_entry.owned_allocation_count() != 0)
            `uvm_fatal("MSGQ_LINUX_FACTORY",
                       "Linux profile choice was not explicit on the entry")
    endfunction

    function void build_phase(uvm_phase phase);
        msgq_kind_e raw_kinds[$] = '{MSGQ_FSE, MSGQ_IACL, MSGQ_EACL,
                                     MSGQ_VDPA, MSGQ_NOTIFY};
        msgq_refill_profile invalid_profile;
        gq_refill_profile cloned_base;
        msgq_refill_profile cloned_profile;
        msgq_wrong_adapter wrong_adapter;
        string reason;

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_c000_0000,
                        64'h0000_0001_c0ff_ffff, MODE_LINEAR, 16);
        adapter = msgq_mock_adapter::type_id::create("adapter");
        raw_factory = msgq_test_entry_factory::type_id::create("raw_factory");
        env_cfg = msgq_env_cfg::type_id::create("env_cfg");
        env_cfg.mem = mem;
        env_cfg.adapter = adapter;

        if (!env_cfg.add_msgq(10, MSGQ_MAC_AGE, MSGQ_PROFILE_LINUX_HEADER,
                              3, 99, null, reason) ||
            !env_cfg.add_msgq(11, MSGQ_1588, MSGQ_PROFILE_EMP_ACTIVE,
                              3, 99, null, reason) ||
            !env_cfg.add_msgq(12, MSGQ_1588, MSGQ_PROFILE_LINUX_HEADER,
                              3, 99, null, reason) ||
            !env_cfg.add_msgq(13, MSGQ_FSE, MSGQ_PROFILE_EMP_ACTIVE,
                              64, 24, raw_factory, reason))
            `uvm_fatal("MSGQ_ADD", {"valid business profile rejected: ", reason})

        foreach (raw_kinds[i]) begin
            if (env_cfg.add_msgq(20 + i, raw_kinds[i],
                                 MSGQ_PROFILE_EMP_ACTIVE, 64, 24,
                                 null, reason))
                `uvm_fatal("MSGQ_RAW_FACTORY_REQUIRED", $sformatf(
                    "raw kind %0d accepted a null factory", raw_kinds[i]))
        end
        if (env_cfg.add_msgq(30, MSGQ_FSE, MSGQ_PROFILE_EMP_ACTIVE,
                             0, 24, raw_factory, reason) ||
            env_cfg.add_msgq(31, MSGQ_FSE, MSGQ_PROFILE_EMP_ACTIVE,
                             3, 24, raw_factory, reason) ||
            env_cfg.add_msgq(32, MSGQ_FSE, MSGQ_PROFILE_EMP_ACTIVE,
                             64, 0, raw_factory, reason))
            `uvm_fatal("MSGQ_RAW_GEOMETRY",
                       "invalid raw depth or entry size was accepted")

        invalid_profile = msgq_refill_profile::type_id::create(
            "invalid_profile");
        invalid_profile.kind = MSGQ_FSE;
        invalid_profile.entry_size = 24;
        invalid_profile.initial_post_count = 63;
        invalid_profile.high_watermark = 63;
        invalid_profile.low_watermark = 62;
        invalid_profile.factory = null;
        if (invalid_profile.validate(64, reason))
            `uvm_fatal("MSGQ_RAW_PROFILE_FACTORY",
                       "raw refill profile accepted a null factory")

        cloned_base = env_cfg.get_refill_profile(13).clone_profile();
        if (!$cast(cloned_profile, cloned_base) ||
            cloned_profile.kind != MSGQ_FSE ||
            cloned_profile.format_profile != MSGQ_PROFILE_EMP_ACTIVE ||
            cloned_profile.entry_size != 24 ||
            cloned_profile.factory != raw_factory ||
            cloned_profile.initial_post_count != 63 ||
            cloned_profile.high_watermark != 63 ||
            cloned_profile.low_watermark != 62 ||
            !cloned_profile.strict_reserved)
            `uvm_fatal("MSGQ_PROFILE_CLONE",
                       "GQ profile cloning lost MSGQ factory or defaults")

        check_queue_defaults(10, 128, 16, MSGQ_MAC_AGE,
                             MSGQ_PROFILE_LINUX_HEADER);
        check_queue_defaults(11, 32, 8, MSGQ_1588,
                             MSGQ_PROFILE_EMP_ACTIVE);
        check_queue_defaults(12, 128, 8, MSGQ_1588,
                             MSGQ_PROFILE_LINUX_HEADER);
        check_queue_defaults(13, 64, 24, MSGQ_FSE,
                             MSGQ_PROFILE_EMP_ACTIVE);
        check_factory_profile();
        check_concrete_factory_output();

        if (!env_cfg.validate(reason))
            `uvm_fatal("MSGQ_ENV_VALIDATE", {"valid environment rejected: ", reason})
        wrong_adapter = msgq_wrong_adapter::type_id::create("wrong_adapter");
        env_cfg.adapter = wrong_adapter;
        if (env_cfg.validate(reason))
            `uvm_fatal("MSGQ_ENV_ADAPTER",
                       "environment accepted a non-MSGQ hardware adapter")
        env_cfg.adapter = adapter;
        if (adapter.trace.size() != 0)
            `uvm_fatal("MSGQ_VALIDATE_PROGRAMMED",
                       "configuration validation programmed the adapter")

        sequencer = gq_sequencer::type_id::create("sequencer", this);
        driver = msgq_profile_capture_driver::type_id::create("driver", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

    task run_phase(uvm_phase phase);
        msgq_rx_start_sequence start_sequence;
        msgq_refill_profile generated_profile;

        phase.raise_objection(this);
        generated_profile = env_cfg.get_refill_profile(10);
        start_sequence = msgq_rx_start_sequence::type_id::create(
            "start_sequence");
        start_sequence.set_refill_profile(generated_profile);
        start_sequence.start(sequencer);
        if (driver.captured_request == null ||
            driver.captured_request.kind != GQ_START_RX ||
            driver.captured_request.get_refill_profile() != generated_profile ||
            start_sequence.response == null ||
            start_sequence.response.status != GQ_OK)
            `uvm_fatal("MSGQ_RX_SEQUENCE",
                       "RX sequence did not use the public GQ start request API")
        phase.drop_objection(this);
    endtask
endclass

`endif
