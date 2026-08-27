`ifndef GQ_AUTO_RECYCLE_TEST_SV
`define GQ_AUTO_RECYCLE_TEST_SV

class gq_auto_recycle_desc extends gq_desc_base;
    `uvm_object_utils(gq_auto_recycle_desc)

    gq_logical_seq_t logical_seq;
    bit allocate_during_prepare;
    bit prepared;

    function new(string name = "gq_auto_recycle_desc");
        super.new(name);
        logical_seq = 0;
        allocate_during_prepare = 0;
        prepared = 0;
    endfunction

    virtual function bit prepare();
        prepared = 1;
        if (allocate_during_prepare)
            return alloc_owned(8) != '1;
        return 1;
    endfunction

    virtual function void mark_available(bit phase);
    endfunction

    virtual function void pack(ref byte packed_data[]);
        packed_data = new[16];
        foreach (packed_data[i])
            packed_data[i] = byte'((logical_seq * 17) + i);
    endfunction

    virtual function bit parse_completion();
        return prepared;
    endfunction
endclass

class gq_auto_recycle_profile extends gq_refill_profile;
    `uvm_object_utils(gq_auto_recycle_profile)

    bit allocate_during_prepare;

    function new(string name = "gq_auto_recycle_profile");
        super.new(name);
        allocate_during_prepare = 0;
    endfunction

    virtual function gq_desc_base create_desc(
        int unsigned queue_id, gq_logical_seq_t logical_seq);
        gq_auto_recycle_desc desc;

        desc = gq_auto_recycle_desc::type_id::create(
            $sformatf("auto_rx_%0d_desc_%0d", queue_id, logical_seq));
        desc.logical_seq = logical_seq;
        desc.allocate_during_prepare = allocate_during_prepare;
        return desc;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        gq_auto_recycle_profile rhs_profile;

        super.do_copy(rhs);
        if (!$cast(rhs_profile, rhs))
            `uvm_fatal("AUTO_RECYCLE_COPY", "source profile type mismatch")
        allocate_during_prepare = rhs_profile.allocate_during_prepare;
    endfunction
endclass

class gq_auto_recycle_collector extends uvm_component;
    `uvm_component_utils(gq_auto_recycle_collector)

    uvm_analysis_imp #(gq_desc_base, gq_auto_recycle_collector) analysis_export;
    gq_logical_seq_t delivered_sequences[$];

    function new(string name = "gq_auto_recycle_collector",
                 uvm_component parent = null);
        super.new(name, parent);
        analysis_export = new("analysis_export", this);
    endfunction

    function void write(gq_desc_base desc);
        gq_auto_recycle_desc recycle_desc;

        if (!$cast(recycle_desc, desc))
            `uvm_fatal("AUTO_RECYCLE_DELIVERY", "unexpected descriptor type")
        delivered_sequences.push_back(recycle_desc.logical_seq);
    endfunction
endclass

class gq_auto_recycle_error_catcher extends uvm_report_catcher;
    `uvm_object_utils(gq_auto_recycle_error_catcher)

    int unsigned caught_allocation_errors;

    function new(string name = "gq_auto_recycle_error_catcher");
        super.new(name);
        caught_allocation_errors = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR &&
            get_id() == "GQ_RX_AUTO_RECYCLE_ALLOC") begin
            caught_allocation_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class gq_auto_recycle_test extends uvm_test;
    `uvm_component_utils(gq_auto_recycle_test)

    host_mem_manager mem;
    gq_test_ptr_codec ptr_codec;
    mailbox_mock_adapter adapter;
    gq_queue_cfg recycle_cfg;
    gq_queue_cfg allocation_cfg;
    gq_queue_engine recycle_engine;
    gq_queue_engine allocation_engine;
    gq_auto_recycle_collector collector;
    int unsigned expectation_failures;
    bit recycle_worker_returned;

    function new(string name = "gq_auto_recycle_test",
                 uvm_component parent = null);
        super.new(name, parent);
        expectation_failures = 0;
        recycle_worker_returned = 0;
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
        result.rx_slot_mode = GQ_RX_AUTO_RECYCLE;
        result.ptr_codec = ptr_codec;
        completion_source = gq_directed_completion_source::type_id::create(
            {name, "_completion"});
        completion_source.role = GQ_RX;
        completion_source.queue_id = queue_id;
        result.completion_source = completion_source;
        return result;
    endfunction

    function bit bytes_equal(input byte lhs[], input byte rhs[]);
        if (lhs.size() != rhs.size())
            return 0;
        foreach (lhs[i]) begin
            if (lhs[i] != rhs[i])
                return 0;
        end
        return 1;
    endfunction

    function void observe_failure(string message);
        expectation_failures++;
        `uvm_info("TASK6_RED", message, UVM_LOW)
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_6000_0000,
                        64'h0000_0001_60ff_ffff, MODE_LINEAR, 16);
        ptr_codec = gq_test_ptr_codec::type_id::create("ptr_codec");
        adapter = mailbox_mock_adapter::type_id::create("adapter");
        recycle_cfg = make_cfg("recycle_cfg", 60);
        allocation_cfg = make_cfg("allocation_cfg", 61);

        uvm_config_db#(gq_queue_cfg)::set(
            this, "recycle_engine", "cfg", recycle_cfg);
        uvm_config_db#(host_mem_api)::set(
            this, "recycle_engine", "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(
            this, "recycle_engine", "adapter", adapter);
        recycle_engine = gq_queue_engine::type_id::create(
            "recycle_engine", this);

        uvm_config_db#(gq_queue_cfg)::set(
            this, "allocation_engine", "cfg", allocation_cfg);
        uvm_config_db#(host_mem_api)::set(
            this, "allocation_engine", "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(
            this, "allocation_engine", "adapter", adapter);
        allocation_engine = gq_queue_engine::type_id::create(
            "allocation_engine", this);
        collector = gq_auto_recycle_collector::type_id::create(
            "collector", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        recycle_engine.completion_ap.connect(collector.analysis_export);
    endfunction

    task run_phase(uvm_phase phase);
        gq_auto_recycle_profile profile;
        gq_auto_recycle_profile allocation_profile;
        gq_request request;
        gq_request allocation_request;
        gq_response response;
        gq_response allocation_response;
        gq_auto_recycle_error_catcher allocation_catcher;
        byte ring_before[];
        byte ring_after[];
        bit ring_unchanged;

        phase.raise_objection(this);
        recycle_engine.initialize();
        allocation_engine.initialize();

        profile = gq_auto_recycle_profile::type_id::create("profile");
        profile.initial_post_count = 7;
        profile.low_watermark = 6;
        profile.high_watermark = 7;
        request = gq_request::type_id::create("request");
        request.kind = GQ_START_RX;
        request.set_refill_profile(profile);
        recycle_engine.start_rx(request, response);
        if (response == null || response.status != GQ_OK ||
            response.committed_count != 7 ||
            adapter.published_tails["rx_60"].size() != 1 ||
            adapter.published_tails["rx_60"][0] !=
                ptr_codec.encode_publish(0, 7, 8))
            observe_failure("initial auto-recycle activation was not one depth-minus-one publish");
        mem.read_mem(recycle_engine.ring_base(), 8 * 16, ring_before,
                     `__FILE__, `__LINE__);

        fork : recycle_worker
            begin
                recycle_engine.run_completion_worker();
                recycle_worker_returned = 1;
            end
        join_none
        adapter.report_directed_completions(GQ_RX, 60, 3);
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #10ns;
            if (recycle_engine.head_seq() == 3 &&
                recycle_engine.tail_seq() >= 10)
                break;
        end
        mem.read_mem(recycle_engine.ring_base(), 8 * 16, ring_after,
                     `__FILE__, `__LINE__);
        ring_unchanged = bytes_equal(ring_before, ring_after);
        `uvm_info("TASK6_OBS", $sformatf(
            "auto recycle deliveries=%0d head=%0d tail=%0d outstanding=%0d publishes=%0d ring_equal=%0d",
            collector.delivered_sequences.size(), recycle_engine.head_seq(),
            recycle_engine.tail_seq(), recycle_engine.outstanding_count(),
            adapter.published_tails["rx_60"].size(), ring_unchanged), UVM_LOW)
        if (collector.delivered_sequences.size() != 3 ||
            collector.delivered_sequences[0] != 0 ||
            collector.delivered_sequences[1] != 1 ||
            collector.delivered_sequences[2] != 2 ||
            recycle_engine.head_seq() != 3 ||
            recycle_engine.tail_seq() != 10 ||
            recycle_engine.outstanding_count() != 7)
            observe_failure("auto-recycle did not restore the ordered seven-entry logical window");
        if (!ring_unchanged)
            observe_failure("auto-recycle rewrote hardware ring bytes");
        if (adapter.published_tails["rx_60"].size() != 1 ||
            adapter.published_tails["rx_60"][0] !=
                ptr_codec.encode_publish(0, 7, 8))
            observe_failure("auto-recycle published a replacement tail");

        allocation_profile =
            gq_auto_recycle_profile::type_id::create("allocation_profile");
        allocation_profile.initial_post_count = 7;
        allocation_profile.low_watermark = 6;
        allocation_profile.high_watermark = 7;
        allocation_profile.allocate_during_prepare = 1;
        allocation_request = gq_request::type_id::create(
            "allocation_request");
        allocation_request.kind = GQ_START_RX;
        allocation_request.set_refill_profile(allocation_profile);
        allocation_catcher = new("allocation_catcher");
        uvm_report_cb::add(null, allocation_catcher);
        allocation_engine.start_rx(allocation_request, allocation_response);
        uvm_report_cb::delete(null, allocation_catcher);
        `uvm_info("TASK6_OBS", $sformatf(
            "allocation reject caught=%0d status=%0d head=%0d tail=%0d outstanding=%0d publishes=%0d",
            allocation_catcher.caught_allocation_errors,
            allocation_response == null ? -1 : allocation_response.status,
            allocation_engine.head_seq(), allocation_engine.tail_seq(),
            allocation_engine.outstanding_count(),
            adapter.published_tails["rx_61"].size()), UVM_LOW)
        if (allocation_catcher.caught_allocation_errors != 1 ||
            allocation_response == null ||
            allocation_response.status != GQ_RESOURCE_ERROR ||
            allocation_response.committed_count != 0 ||
            allocation_engine.head_seq() != 0 ||
            allocation_engine.tail_seq() != 0 ||
            allocation_engine.outstanding_count() != 0 ||
            adapter.published_tails["rx_61"].size() != 0)
            observe_failure("owned allocation was not rejected once before auto-recycle publication");

        recycle_engine.cleanup();
        allocation_engine.cleanup();
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #10ns;
            if (recycle_worker_returned)
                break;
        end
        if (!recycle_worker_returned)
            observe_failure("auto-recycle worker did not terminate during cleanup");
        mem.leak_check(`__FILE__, `__LINE__);
        if (expectation_failures != 0)
            `uvm_fatal("AUTO_RECYCLE_EXPECT", $sformatf(
                "%0d auto-recycle expectations failed", expectation_failures))
        phase.drop_objection(this);
    endtask
endclass

`endif
