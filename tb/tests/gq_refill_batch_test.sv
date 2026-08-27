`ifndef GQ_REFILL_BATCH_TEST_SV
`define GQ_REFILL_BATCH_TEST_SV

class gq_refill_batch_desc extends gq_desc_base;
    `uvm_object_utils(gq_refill_batch_desc)

    gq_logical_seq_t logical_seq;
    bit prepared;

    function new(string name = "gq_refill_batch_desc");
        super.new(name);
        logical_seq = 0;
        prepared = 0;
    endfunction

    virtual function bit prepare();
        prepared = 1;
        return 1;
    endfunction

    virtual function void mark_available(bit phase);
    endfunction

    virtual function void pack(ref byte packed_data[]);
        packed_data = new[16];
        foreach (packed_data[i])
            packed_data[i] = byte'((logical_seq * 29) + i);
    endfunction

    virtual function bit parse_completion();
        return prepared;
    endfunction
endclass

class gq_refill_batch_profile extends gq_refill_profile;
    `uvm_object_utils(gq_refill_batch_profile)

    function new(string name = "gq_refill_batch_profile");
        super.new(name);
    endfunction

    virtual function gq_desc_base create_desc(
        int unsigned queue_id, gq_logical_seq_t logical_seq);
        gq_refill_batch_desc desc;

        desc = gq_refill_batch_desc::type_id::create(
            $sformatf("batch_rx_%0d_desc_%0d", queue_id, logical_seq));
        desc.logical_seq = logical_seq;
        return desc;
    endfunction
endclass

class gq_refill_batch_test extends uvm_test;
    `uvm_component_utils(gq_refill_batch_test)

    host_mem_manager mem;
    gq_test_ptr_codec ptr_codec;
    mailbox_mock_adapter adapter;
    gq_queue_cfg bounded_cfg;
    gq_queue_cfg unlimited_cfg;
    gq_queue_engine bounded_engine;
    gq_queue_engine unlimited_engine;
    int unsigned expectation_failures;
    bit bounded_worker_returned;
    bit unlimited_worker_returned;

    function new(string name = "gq_refill_batch_test",
                 uvm_component parent = null);
        super.new(name, parent);
        expectation_failures = 0;
        bounded_worker_returned = 0;
        unlimited_worker_returned = 0;
    endfunction

    function gq_queue_cfg make_cfg(string name, int unsigned queue_id);
        gq_queue_cfg result;
        gq_directed_completion_source completion_source;

        result = gq_queue_cfg::type_id::create(name);
        result.queue_id = queue_id;
        result.role = GQ_RX;
        result.depth = 8;
        result.desc_size = 16;
        result.alignment = 64;
        result.status_area_size = 0;
        result.wait_mode = GQ_POLL;
        result.poll_policy = GQ_POLL_FIXED;
        result.poll_min_interval = 10ns;
        result.poll_max_interval = 10ns;
        result.completion_timeout = 0;
        result.rx_slot_mode = GQ_RX_EXPLICIT_REFILL;
        result.ptr_codec = ptr_codec;
        completion_source = gq_directed_completion_source::type_id::create(
            {name, "_completion"});
        completion_source.role = GQ_RX;
        completion_source.queue_id = queue_id;
        result.completion_source = completion_source;
        return result;
    endfunction

    function void observe_failure(string message);
        expectation_failures++;
        `uvm_info("TASK6_RED", message, UVM_LOW)
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_6100_0000,
                        64'h0000_0001_61ff_ffff, MODE_LINEAR, 16);
        ptr_codec = gq_test_ptr_codec::type_id::create("ptr_codec");
        adapter = mailbox_mock_adapter::type_id::create("adapter");
        bounded_cfg = make_cfg("bounded_cfg", 62);
        unlimited_cfg = make_cfg("unlimited_cfg", 63);

        uvm_config_db#(gq_queue_cfg)::set(
            this, "bounded_engine", "cfg", bounded_cfg);
        uvm_config_db#(host_mem_api)::set(
            this, "bounded_engine", "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(
            this, "bounded_engine", "adapter", adapter);
        bounded_engine = gq_queue_engine::type_id::create(
            "bounded_engine", this);

        uvm_config_db#(gq_queue_cfg)::set(
            this, "unlimited_engine", "cfg", unlimited_cfg);
        uvm_config_db#(host_mem_api)::set(
            this, "unlimited_engine", "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(
            this, "unlimited_engine", "adapter", adapter);
        unlimited_engine = gq_queue_engine::type_id::create(
            "unlimited_engine", this);
    endfunction

    task run_phase(uvm_phase phase);
        gq_refill_batch_profile bounded_profile;
        gq_refill_batch_profile unlimited_profile;
        gq_request bounded_request;
        gq_request unlimited_request;
        gq_response bounded_response;
        gq_response unlimited_response;

        phase.raise_objection(this);
        bounded_engine.initialize();
        unlimited_engine.initialize();

        bounded_profile = gq_refill_batch_profile::type_id::create(
            "bounded_profile");
        bounded_profile.initial_post_count = 7;
        bounded_profile.low_watermark = 6;
        bounded_profile.high_watermark = 7;
        bounded_profile.max_refill_batch = 1;
        bounded_request = gq_request::type_id::create("bounded_request");
        bounded_request.kind = GQ_START_RX;
        bounded_request.set_refill_profile(bounded_profile);
        bounded_engine.start_rx(bounded_request, bounded_response);

        unlimited_profile = gq_refill_batch_profile::type_id::create(
            "unlimited_profile");
        unlimited_profile.initial_post_count = 7;
        unlimited_profile.low_watermark = 6;
        unlimited_profile.high_watermark = 7;
        unlimited_profile.max_refill_batch = 0;
        unlimited_request = gq_request::type_id::create("unlimited_request");
        unlimited_request.kind = GQ_START_RX;
        unlimited_request.set_refill_profile(unlimited_profile);
        unlimited_engine.start_rx(unlimited_request, unlimited_response);

        if (bounded_response == null || bounded_response.status != GQ_OK ||
            unlimited_response == null || unlimited_response.status != GQ_OK ||
            adapter.published_tails["rx_62"].size() != 1 ||
            adapter.published_tails["rx_63"].size() != 1)
            observe_failure("explicit-refill activation did not publish seven entries once");

        fork : refill_workers
            begin
                bounded_engine.run_completion_worker();
                bounded_worker_returned = 1;
            end
            begin
                unlimited_engine.run_completion_worker();
                unlimited_worker_returned = 1;
            end
        join_none
        adapter.report_directed_completions(GQ_RX, 62, 3);
        adapter.report_directed_completions(GQ_RX, 63, 3);
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #10ns;
            if (bounded_engine.head_seq() == 3 &&
                bounded_engine.tail_seq() == 10 &&
                unlimited_engine.head_seq() == 3 &&
                unlimited_engine.tail_seq() == 10)
                break;
        end

        `uvm_info("TASK6_OBS", $sformatf(
            "bounded head=%0d tail=%0d outstanding=%0d publish_count=%0d tails=%h,%h,%h,%h",
            bounded_engine.head_seq(), bounded_engine.tail_seq(),
            bounded_engine.outstanding_count(),
            adapter.published_tails["rx_62"].size(),
            adapter.published_tails["rx_62"].size() > 0 ?
                adapter.published_tails["rx_62"][0] : '1,
            adapter.published_tails["rx_62"].size() > 1 ?
                adapter.published_tails["rx_62"][1] : '1,
            adapter.published_tails["rx_62"].size() > 2 ?
                adapter.published_tails["rx_62"][2] : '1,
            adapter.published_tails["rx_62"].size() > 3 ?
                adapter.published_tails["rx_62"][3] : '1), UVM_LOW)
        if (bounded_engine.head_seq() != 3 ||
            bounded_engine.tail_seq() != 10 ||
            bounded_engine.outstanding_count() != 7 ||
            adapter.published_tails["rx_62"].size() != 4 ||
            adapter.published_tails["rx_62"][0] !=
                ptr_codec.encode_publish(0, 7, 8) ||
            adapter.published_tails["rx_62"][1] !=
                ptr_codec.encode_publish(7, 8, 8) ||
            adapter.published_tails["rx_62"][2] !=
                ptr_codec.encode_publish(8, 9, 8) ||
            adapter.published_tails["rx_62"][3] !=
                ptr_codec.encode_publish(9, 10, 8))
            observe_failure("max_refill_batch=1 did not publish three one-entry replacements");

        `uvm_info("TASK6_OBS", $sformatf(
            "unlimited head=%0d tail=%0d outstanding=%0d publish_count=%0d tails=%h,%h",
            unlimited_engine.head_seq(), unlimited_engine.tail_seq(),
            unlimited_engine.outstanding_count(),
            adapter.published_tails["rx_63"].size(),
            adapter.published_tails["rx_63"].size() > 0 ?
                adapter.published_tails["rx_63"][0] : '1,
            adapter.published_tails["rx_63"].size() > 1 ?
                adapter.published_tails["rx_63"][1] : '1), UVM_LOW)
        if (unlimited_engine.head_seq() != 3 ||
            unlimited_engine.tail_seq() != 10 ||
            unlimited_engine.outstanding_count() != 7 ||
            adapter.published_tails["rx_63"].size() != 2 ||
            adapter.published_tails["rx_63"][0] !=
                ptr_codec.encode_publish(0, 7, 8) ||
            adapter.published_tails["rx_63"][1] !=
                ptr_codec.encode_publish(7, 10, 8))
            observe_failure("max_refill_batch=0 did not preserve one legacy batched publish");

        bounded_engine.cleanup();
        unlimited_engine.cleanup();
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #10ns;
            if (bounded_worker_returned && unlimited_worker_returned)
                break;
        end
        if (!bounded_worker_returned || !unlimited_worker_returned)
            observe_failure("explicit-refill workers did not terminate during cleanup");
        mem.leak_check(`__FILE__, `__LINE__);
        if (expectation_failures != 0)
            `uvm_fatal("REFILL_BATCH_EXPECT", $sformatf(
                "%0d refill-batch expectations failed", expectation_failures))
        phase.drop_objection(this);
    endtask
endclass

`endif
