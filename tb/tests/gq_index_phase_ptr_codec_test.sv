// tb/tests/gq_index_phase_ptr_codec_test.sv: UVM 测试 gq_index_phase_ptr_codec_test：验证对应队列组件的定向行为和接口契约。
`ifndef GQ_INDEX_PHASE_PTR_CODEC_TEST_SV
`define GQ_INDEX_PHASE_PTR_CODEC_TEST_SV

class gq_ptr_callback_test_engine extends gq_queue_engine;
    `uvm_component_utils(gq_ptr_callback_test_engine)

    function new(string name = "gq_ptr_callback_test_engine",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function bit request_reset_from_codec();
        bit acquired;

        acquired = state_lock.try_get(1);
        if (!acquired)
            return 0;
        reset_requested_value = 1;
        ready_value = 0;
        reset_epoch_value++;
        state_lock.put(1);
        return 1;
    endfunction
endclass

class gq_lock_probe_ptr_codec extends gq_index_phase_ptr_codec;
    `uvm_object_utils(gq_lock_probe_ptr_codec)

    gq_ptr_callback_test_engine engine;
    bit arm_reset;
    bit callback_lock_free;
    int unsigned callback_count;

    function new(string name = "gq_lock_probe_ptr_codec");
        super.new(name, 15, 15);
        engine = null;
        arm_reset = 0;
        callback_lock_free = 0;
        callback_count = 0;
    endfunction

    virtual function gq_raw_ptr_t encode_publish(
        gq_logical_seq_t old_tail,
        gq_logical_seq_t new_tail,
        int unsigned depth);
        callback_count++;
        if (arm_reset && engine != null)
            callback_lock_free = engine.request_reset_from_codec();
        return super.encode_publish(old_tail, new_tail, depth);
    endfunction
endclass

class gq_ptr_validation_catcher extends uvm_report_catcher;
    `uvm_object_utils(gq_ptr_validation_catcher)

    int unsigned engine_cfg_fatals;
    int unsigned late_encode_errors;

    function new(string name = "gq_ptr_validation_catcher");
        super.new(name);
        engine_cfg_fatals = 0;
        late_encode_errors = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_FATAL &&
            get_id() == "GQ_ENGINE_CFG") begin
            engine_cfg_fatals++;
            return CAUGHT;
        end
        if (get_severity() == UVM_ERROR && get_id() == "GQ_PTR_CFG") begin
            late_encode_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class gq_index_phase_ptr_codec_test extends uvm_test;
    `uvm_component_utils(gq_index_phase_ptr_codec_test)

    host_mem_manager mem;
    gq_queue_cfg invalid_cfg;
    gq_queue_cfg callback_cfg;
    gq_index_phase_ptr_codec invalid_queue_codec;
    gq_lock_probe_ptr_codec callback_codec;
    mailbox_mock_adapter invalid_adapter;
    mailbox_mock_adapter callback_adapter;
    gq_queue_engine invalid_engine;
    gq_ptr_callback_test_engine callback_engine;
    int unsigned expectation_failures;

    function new(string name = "gq_index_phase_ptr_codec_test",
                 uvm_component parent = null);
        super.new(name, parent);
        expectation_failures = 0;
    endfunction

    function gq_queue_cfg make_cfg(string name, int unsigned queue_id,
                                   gq_ptr_codec ptr_codec);
        gq_queue_cfg result;

        result = gq_queue_cfg::type_id::create(name);
        result.queue_id = queue_id;
        result.role = GQ_TX;
        result.depth = 32;
        result.desc_size = 64;
        result.alignment = 64;
        result.status_area_size = 0;
        result.wait_mode = GQ_POLL;
        result.poll_policy = GQ_POLL_FIXED;
        result.poll_min_interval = 10ns;
        result.poll_max_interval = 10ns;
        result.completion_timeout = 1us;
        result.ptr_codec = ptr_codec;
        result.completion_source = mailbox_completion::type_id::create(
            {name, "_completion"});
        return result;
    endfunction

    function void configure_engine(string path, gq_queue_cfg cfg,
                                   gq_hw_adapter adapter);
        uvm_config_db#(gq_queue_cfg)::set(this, path, "cfg", cfg);
        uvm_config_db#(host_mem_api)::set(this, path, "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(this, path, "adapter", adapter);
    endfunction

    function mailbox_tx_desc make_tx(string name, int unsigned srcid);
        mailbox_tx_desc desc;

        desc = mailbox_tx_desc::type_id::create(name);
        desc.srcid = srcid;
        desc.dstid = 16'h1234;
        desc.msg_type = 16'h5678;
        desc.buf_len = 0;
        desc.data_len = 1;
        desc.data[0] = 8'h5a;
        return desc;
    endfunction

    function void observe_failure(string message);
        expectation_failures++;
        `uvm_error("GQ_PTR_EXPECT", message)
    endfunction

    function void build_phase(uvm_phase phase);
        gq_index_phase_ptr_codec codec;
        gq_index_phase_ptr_codec invalid_index_width;
        gq_index_phase_ptr_codec invalid_phase_before_index;
        gq_index_phase_ptr_codec invalid_phase_out_of_range;
        string reason;

        super.build_phase(phase);
        codec = new("codec", 15, 15);

        if (codec.encode_publish(0, 1, 32) != 32'h0000_0001)
            `uvm_error("PTR", "slot 1")
        if (codec.encode_publish(31, 32, 32) != 32'h0000_8000)
            `uvm_error("PTR", "first wrap")
        if (codec.encode_publish(63, 64, 32) != 32'h0000_0000)
            `uvm_error("PTR", "second wrap")
        if (codec.validate_depth(32768, reason) != 1)
            `uvm_error("PTR", reason)
        if (codec.validate_depth(65536, reason) != 0)
            `uvm_error("PTR", "index overflow accepted")

        invalid_index_width = new("invalid_index_width", 0, 15);
        if (invalid_index_width.validate_depth(32, reason) != 0)
            `uvm_error("PTR", "index_width=0 was accepted")

        invalid_phase_before_index = new("invalid_phase_before_index", 15, 14);
        if (invalid_phase_before_index.validate_depth(32, reason) != 0)
            `uvm_error("PTR", "phase_bit below index width was accepted")

        invalid_phase_out_of_range = new("invalid_phase_out_of_range", 15, 32);
        if (invalid_phase_out_of_range.validate_depth(32, reason) != 0)
            `uvm_error("PTR", "phase_bit outside raw pointer was accepted")

        mem = new("mem");
        mem.init_region(64'h0000_0001_9000_0000,
                        64'h0000_0001_90ff_ffff, MODE_LINEAR, 16);
        invalid_queue_codec = new("invalid_queue_codec", 4, 4);
        callback_codec = gq_lock_probe_ptr_codec::type_id::create(
            "callback_codec");
        invalid_cfg = make_cfg("invalid_cfg", 70, invalid_queue_codec);
        callback_cfg = make_cfg("callback_cfg", 71, callback_codec);
        invalid_adapter = mailbox_mock_adapter::type_id::create(
            "invalid_adapter");
        callback_adapter = mailbox_mock_adapter::type_id::create(
            "callback_adapter");
        configure_engine("invalid_engine", invalid_cfg, invalid_adapter);
        invalid_engine = gq_queue_engine::type_id::create(
            "invalid_engine", this);
        configure_engine("callback_engine", callback_cfg, callback_adapter);
        callback_engine = gq_ptr_callback_test_engine::type_id::create(
            "callback_engine", this);
        callback_codec.engine = callback_engine;
    endfunction

    task run_phase(uvm_phase phase);
        gq_ptr_validation_catcher catcher;
        mailbox_tx_desc desc;
        gq_request request;
        gq_response response;
        string reason;

        phase.raise_objection(this);
        if (invalid_cfg.validate(reason) || reason == "")
            observe_failure("queue validation accepted an incompatible pointer codec");

        catcher = new("catcher");
        uvm_report_cb::add(null, catcher);
        invalid_engine.initialize();
        if (invalid_engine.is_ready()) begin
            desc = make_tx("invalid_codec_desc", 16'h7000);
            request = gq_request::type_id::create("invalid_codec_request");
            request.add_desc(desc);
            invalid_engine.submit_batch(request, response);
        end
        if (catcher.engine_cfg_fatals != 1 ||
            catcher.late_encode_errors != 0 ||
            invalid_engine.is_ready() ||
            invalid_adapter.configure_calls != 0 ||
            invalid_adapter.publish_calls != 0)
            observe_failure($sformatf(
                "invalid pointer config was not rejected before configure/publish: cfg_fatal=%0d late_encode=%0d ready=%0d configure=%0d publish=%0d",
                catcher.engine_cfg_fatals, catcher.late_encode_errors,
                invalid_engine.is_ready(), invalid_adapter.configure_calls,
                invalid_adapter.publish_calls));
        invalid_engine.cleanup();

        callback_engine.initialize();
        callback_codec.arm_reset = 1;
        desc = make_tx("callback_desc", 16'h7100);
        request = gq_request::type_id::create("callback_request");
        request.add_desc(desc);
        response = null;
        callback_engine.submit_batch(request, response);
        if (callback_codec.callback_count != 1 ||
            !callback_codec.callback_lock_free ||
            response == null || response.status != GQ_ABORTED_BY_RESET ||
            callback_engine.tail_seq() != 0 ||
            callback_engine.outstanding_count() != 0 ||
            callback_adapter.publish_calls != 0)
            observe_failure($sformatf(
                "codec callback lock/epoch reservation failed: calls=%0d lock_free=%0d status=%0d tail=%0d outstanding=%0d publish=%0d",
                callback_codec.callback_count,
                callback_codec.callback_lock_free,
                response == null ? -1 : response.status,
                callback_engine.tail_seq(),
                callback_engine.outstanding_count(),
                callback_adapter.publish_calls));
        callback_engine.cleanup();
        uvm_report_cb::delete(null, catcher);
        mem.leak_check(`__FILE__, `__LINE__);

        if (expectation_failures != 0)
            `uvm_fatal("GQ_PTR_EXPECT", $sformatf(
                "%0d pointer expectation(s) failed", expectation_failures))
        phase.drop_objection(this);
    endtask
endclass

`endif
