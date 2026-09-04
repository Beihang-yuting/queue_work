// tb/tests/gq_auto_recycle_test.sv: UVM 测试 gq_auto_recycle_test：验证对应队列组件的定向行为和接口契约。
`ifndef GQ_AUTO_RECYCLE_TEST_SV
`define GQ_AUTO_RECYCLE_TEST_SV

class gq_auto_recycle_desc extends gq_desc_base;
    `uvm_object_utils(gq_auto_recycle_desc)

    gq_logical_seq_t logical_seq;
    bit allocate_during_prepare;
    bit fail_prepare;
    bit allocate_before_failure;
    bit prepared;

    function new(string name = "gq_auto_recycle_desc");
        super.new(name);
        logical_seq = 0;
        allocate_during_prepare = 0;
        fail_prepare = 0;
        allocate_before_failure = 0;
        prepared = 0;
    endfunction

    virtual function bit prepare();
        prepared = 1;
        if (allocate_during_prepare)
            return alloc_owned(8) != '1;
        if (fail_prepare) begin
            if (allocate_before_failure)
                void'(alloc_owned(8));
            return 0;
        end
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
    bit fail_prepare_enabled;
    gq_logical_seq_t fail_prepare_seq;
    bit allocate_before_failure;

    function new(string name = "gq_auto_recycle_profile");
        super.new(name);
        allocate_during_prepare = 0;
        fail_prepare_enabled = 0;
        fail_prepare_seq = 0;
        allocate_before_failure = 0;
    endfunction

    virtual function gq_desc_base create_desc(
        int unsigned queue_id, gq_logical_seq_t logical_seq);
        gq_auto_recycle_desc desc;

        desc = gq_auto_recycle_desc::type_id::create(
            $sformatf("auto_rx_%0d_desc_%0d", queue_id, logical_seq));
        desc.logical_seq = logical_seq;
        desc.allocate_during_prepare = allocate_during_prepare;
        desc.fail_prepare = fail_prepare_enabled &&
                            logical_seq == fail_prepare_seq;
        desc.allocate_before_failure = allocate_before_failure;
        return desc;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        gq_auto_recycle_profile rhs_profile;

        super.do_copy(rhs);
        if (!$cast(rhs_profile, rhs))
            `uvm_fatal("AUTO_RECYCLE_COPY", "source profile type mismatch")
        allocate_during_prepare = rhs_profile.allocate_during_prepare;
        fail_prepare_enabled = rhs_profile.fail_prepare_enabled;
        fail_prepare_seq = rhs_profile.fail_prepare_seq;
        allocate_before_failure = rhs_profile.allocate_before_failure;
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
    host_mem_manager partial_mem;
    gq_test_ptr_codec ptr_codec;
    mailbox_mock_adapter adapter;
    gq_queue_cfg recycle_cfg;
    gq_queue_cfg allocation_cfg;
    gq_queue_cfg partial_cfg;
    gq_queue_engine recycle_engine;
    gq_queue_engine allocation_engine;
    gq_queue_engine partial_engine;
    uvm_analysis_port #(gq_desc_base) recycle_completion_ap;
    uvm_analysis_port #(gq_desc_base) partial_completion_ap;
    gq_auto_recycle_collector collector;
    gq_auto_recycle_collector partial_collector;
    int unsigned expectation_failures;
    bit recycle_worker_returned;
    bit partial_worker_returned;

    function new(string name = "gq_auto_recycle_test",
                 uvm_component parent = null);
        super.new(name, parent);
        expectation_failures = 0;
        recycle_worker_returned = 0;
        partial_worker_returned = 0;
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
        recycle_completion_ap = new("recycle_completion_ap", this);
        partial_completion_ap = new("partial_completion_ap", this);
        mem = new("mem");
        mem.init_region(64'h0000_0001_6000_0000,
                        64'h0000_0001_60ff_ffff, MODE_LINEAR, 16);
        partial_mem = new("partial_mem");
        partial_mem.init_region(64'h0000_0001_6100_0000,
                                64'h0000_0001_61ff_ffff,
                                MODE_LINEAR, 16);
        ptr_codec = gq_test_ptr_codec::type_id::create("ptr_codec");
        adapter = mailbox_mock_adapter::type_id::create("adapter");
        recycle_cfg = make_cfg("recycle_cfg", 60);
        allocation_cfg = make_cfg("allocation_cfg", 61);
        partial_cfg = make_cfg("partial_cfg", 62);

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
        uvm_config_db#(gq_queue_cfg)::set(
            this, "partial_engine", "cfg", partial_cfg);
        uvm_config_db#(host_mem_api)::set(
            this, "partial_engine", "mem", partial_mem);
        uvm_config_db#(gq_hw_adapter)::set(
            this, "partial_engine", "adapter", adapter);
        partial_engine = gq_queue_engine::type_id::create(
            "partial_engine", this);
        collector = gq_auto_recycle_collector::type_id::create(
            "collector", this);
        partial_collector = gq_auto_recycle_collector::type_id::create(
            "partial_collector", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        recycle_engine.bind_completion_port(recycle_completion_ap);
        recycle_completion_ap.connect(collector.analysis_export);
        partial_engine.bind_completion_port(partial_completion_ap);
        partial_completion_ap.connect(partial_collector.analysis_export);
    endfunction

    task run_phase(uvm_phase phase);
        gq_auto_recycle_profile profile;
        gq_auto_recycle_profile allocation_profile;
        gq_auto_recycle_profile partial_profile;
        gq_request request;
        gq_request allocation_request;
        gq_response response;
        gq_response allocation_response;
        gq_response partial_response;
        gq_auto_recycle_error_catcher allocation_catcher;
        gq_auto_recycle_error_catcher partial_catcher;
        byte ring_prefill[];
        byte ring_before[];
        byte ring_after[];
        byte partial_ring_before[];
        byte partial_ring_after[];
        bit ring_unchanged;
        bit initial_slots_zero;
        bit sentinel_untouched;

        phase.raise_objection(this);
        recycle_engine.initialize();
        allocation_engine.initialize();
        partial_engine.initialize();

        ring_prefill = new[8 * 16];
        foreach (ring_prefill[i])
            ring_prefill[i] = 8'ha5;
        mem.write_mem(recycle_engine.ring_base(), ring_prefill,
                      `__FILE__, `__LINE__);

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
        initial_slots_zero = 1;
        for (int unsigned i = 0; i < 7 * 16; i++) begin
            if (ring_before[i] != 0)
                initial_slots_zero = 0;
        end
        sentinel_untouched = 1;
        for (int unsigned i = 7 * 16; i < 8 * 16; i++) begin
            if (ring_before[i] != 8'ha5)
                sentinel_untouched = 0;
        end
        if (!initial_slots_zero || !sentinel_untouched)
            observe_failure($sformatf(
                "auto-recycle activation did not explicitly clear only the seven initial slots: zero=%0d sentinel=%0d",
                initial_slots_zero, sentinel_untouched));

        fork : recycle_worker
            begin
                recycle_engine.run_completion_monitor();
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

        partial_profile =
            gq_auto_recycle_profile::type_id::create("partial_profile");
        partial_profile.initial_post_count = 7;
        partial_profile.low_watermark = 6;
        partial_profile.high_watermark = 7;
        partial_profile.fail_prepare_enabled = 1;
        partial_profile.fail_prepare_seq = 8;
        partial_profile.allocate_before_failure = 1;
        request = gq_request::type_id::create("partial_request");
        request.kind = GQ_START_RX;
        request.set_refill_profile(partial_profile);
        partial_engine.start_rx(request, partial_response);
        if (partial_response == null || partial_response.status != GQ_OK ||
            partial_response.committed_count != 7)
            observe_failure("partial-failure auto-recycle activation failed");
        partial_mem.read_mem(partial_engine.ring_base(), 8 * 16,
                             partial_ring_before, `__FILE__, `__LINE__);
        partial_catcher = new("partial_catcher");
        uvm_report_cb::add(null, partial_catcher);
        partial_worker_returned = 0;
        fork : partial_worker
            begin
                partial_engine.run_completion_monitor();
                partial_worker_returned = 1;
            end
        join_none
        adapter.report_directed_completions(GQ_RX, 62, 3);
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #10ns;
            if (partial_catcher.caught_allocation_errors == 1 &&
                partial_engine.head_seq() == 3 &&
                partial_engine.tail_seq() >= 8)
                break;
        end
        uvm_report_cb::delete(null, partial_catcher);
        partial_mem.read_mem(partial_engine.ring_base(), 8 * 16,
                             partial_ring_after, `__FILE__, `__LINE__);
        if (partial_catcher.caught_allocation_errors != 1)
            observe_failure($sformatf(
                "partial recycle failure reported GQ_RX_AUTO_RECYCLE_ALLOC %0d times",
                partial_catcher.caught_allocation_errors));
        if (partial_collector.delivered_sequences.size() != 3 ||
            partial_engine.head_seq() != 3 ||
            partial_engine.tail_seq() != 8 ||
            partial_engine.outstanding_count() != 5)
            observe_failure($sformatf(
                "partial recycle did not preserve one successful replacement: deliveries=%0d head=%0d tail=%0d outstanding=%0d",
                partial_collector.delivered_sequences.size(),
                partial_engine.head_seq(), partial_engine.tail_seq(),
                partial_engine.outstanding_count()));
        if (!bytes_equal(partial_ring_before, partial_ring_after))
            observe_failure("partial recycle failure changed ring bytes");
        if (adapter.published_tails["rx_62"].size() != 1 ||
            adapter.published_tails["rx_62"][0] !=
                ptr_codec.encode_publish(0, 7, 8))
            observe_failure("partial recycle failure changed publish history");

        recycle_engine.cleanup();
        allocation_engine.cleanup();
        partial_engine.cleanup();
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #10ns;
            if (recycle_worker_returned)
                break;
        end
        if (!recycle_worker_returned)
            observe_failure("auto-recycle worker did not terminate during cleanup");
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #10ns;
            if (partial_worker_returned)
                break;
        end
        if (!partial_worker_returned)
            observe_failure("partial-failure worker did not terminate during cleanup");
        disable partial_worker;
        mem.leak_check(`__FILE__, `__LINE__);
        partial_mem.leak_check(`__FILE__, `__LINE__);
        if (expectation_failures != 0)
            `uvm_fatal("AUTO_RECYCLE_EXPECT", $sformatf(
                "%0d auto-recycle expectations failed", expectation_failures))
        phase.drop_objection(this);
    endtask
endclass

`endif
