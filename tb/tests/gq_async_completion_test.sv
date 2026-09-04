// tb/tests/gq_async_completion_test.sv: UVM 测试 gq_async_completion_test：验证对应队列组件的定向行为和接口契约。
`ifndef GQ_ASYNC_COMPLETION_TEST_SV
`define GQ_ASYNC_COMPLETION_TEST_SV

class gq_async_invalid_query_catcher extends uvm_report_catcher;
    `uvm_object_utils(gq_async_invalid_query_catcher)

    bit armed;
    int unsigned caught_count;

    function new(string name = "gq_async_invalid_query_catcher");
        super.new(name);
        armed = 0;
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if (armed && get_severity() == UVM_WARNING &&
            get_id() == "GQ_COMPLETION_QUERY") begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class gq_async_completion_test extends uvm_test;
    `uvm_component_utils(gq_async_completion_test)

    host_mem_manager mem;
    gq_test_ptr_codec ptr_codec;
    mailbox_mock_adapter adapter;
    gq_async_completion_source async_source;
    gq_queue_cfg cfg;
    gq_queue_engine engine;

    function new(string name = "gq_async_completion_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function mailbox_tx_desc make_tx(string name, int unsigned index);
        mailbox_tx_desc desc;

        desc = mailbox_tx_desc::type_id::create(name);
        desc.srcid = 16'h6100 + index;
        desc.dstid = 16'h6200 + index;
        desc.msg_type = 16'h6300 + index;
        desc.data_len = 1;
        desc.data[0] = byte'(index);
        return desc;
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        mem = new("mem");
        mem.init_region(64'h0000_0001_4800_0000,
                        64'h0000_0001_48ff_ffff, MODE_LINEAR, 16);
        ptr_codec = gq_test_ptr_codec::type_id::create("ptr_codec");
        adapter = mailbox_mock_adapter::type_id::create("adapter");
        async_source = gq_async_completion_source::type_id::create(
            "async_source");

        cfg = gq_queue_cfg::type_id::create("cfg");
        cfg.queue_id = 31;
        cfg.role = GQ_TX;
        cfg.depth = 32;
        cfg.desc_size = 64;
        cfg.alignment = 64;
        cfg.status_area_size = 0;
        cfg.wait_mode = GQ_POLL;
        cfg.poll_min_interval = 10ns;
        cfg.poll_max_interval = 10ns;
        cfg.completion_timeout = 1us;
        cfg.ptr_codec = ptr_codec;
        cfg.completion_source = async_source;

        uvm_config_db#(gq_queue_cfg)::set(this, "engine", "cfg", cfg);
        uvm_config_db#(host_mem_api)::set(this, "engine", "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "engine", "adapter", adapter);
        engine = gq_queue_engine::type_id::create("engine", this);
    endfunction

    task submit_one(mailbox_tx_desc desc);
        gq_request request;
        gq_response response;

        request = gq_request::type_id::create("request");
        request.add_desc(desc);
        response = gq_response::type_id::create("response");
        engine.submit_batch(request, response);
        if (response.status != GQ_OK || response.committed_count != 1)
            `uvm_fatal("ASYNC_SETUP", "single descriptor submit failed")
    endtask

    task check_public_completion_contract();
        gq_completion_source source;
        gq_desc_base pending[$];
        bit valid;
        int unsigned count;

        source = async_source;
        async_source.release_query.trigger();
        source.query_completed(mem, adapter, 0, 0, 32, 64, 0,
                               pending, valid, count);
        async_source.query_entered.reset();
        async_source.release_query.reset();
        if (!valid || count != 0)
            `uvm_fatal("ASYNC_CONTRACT", "base completion task lost outputs")
    endtask

    task check_invalid_and_stale_query();
        mailbox_tx_desc desc;
        gq_async_invalid_query_catcher invalid_query_catcher;
        bit drain_returned;
        bit reset_entered;
        int unsigned invalid_query_count_before;
        longint unsigned starting_epoch;

        engine.initialize();
        desc = make_tx("async_desc", 0);
        submit_one(desc);

        async_source.next_valid = 0;
        async_source.next_count = 1;
        async_source.release_query.trigger();
        invalid_query_catcher = gq_async_invalid_query_catcher::type_id::create(
            "invalid_query_catcher");
        uvm_report_cb::add(engine, invalid_query_catcher);
        invalid_query_count_before = invalid_query_catcher.caught_count;
        invalid_query_catcher.armed = 1;
        engine.drain_completed();
        invalid_query_catcher.armed = 0;
        uvm_report_cb::delete(engine, invalid_query_catcher);
        if (invalid_query_catcher.caught_count !=
            invalid_query_count_before + 1)
            `uvm_fatal("ASYNC_INVALID_REPORT", $sformatf(
                "expected one invalid-query warning, caught %0d",
                invalid_query_catcher.caught_count -
                invalid_query_count_before))
        if (engine.head_seq() != 0 || engine.outstanding_count() != 1)
            `uvm_fatal("ASYNC_INVALID",
                       "invalid completion query retired a descriptor")

        async_source.query_entered.reset();
        async_source.release_query.reset();
        async_source.next_valid = 1;
        async_source.next_count = 1;
        drain_returned = 0;
        fork : delayed_query
            begin
                engine.drain_completed();
                drain_returned = 1;
            end
        join_none
        async_source.query_entered.wait_on();

        starting_epoch = engine.reset_epoch();
        fork : reset_entry
            begin
                engine.begin_reset();
            end
        join_none
        reset_entered = 0;
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #10ns;
            if (engine.reset_epoch() == starting_epoch + 1) begin
                reset_entered = 1;
                break;
            end
        end
        if (!reset_entered)
            `uvm_fatal("ASYNC_LOCK",
                       "blocked completion query retained the state lock")

        async_source.release_query.trigger();
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #10ns;
            if (drain_returned)
                break;
        end
        if (!drain_returned)
            `uvm_fatal("ASYNC_RETURN", "completion query did not return")
        if (engine.head_seq() != 0 || engine.outstanding_count() != 1)
            `uvm_fatal("ASYNC_STALE",
                       "completion result from the prior epoch was committed")

        engine.finish_reset();
        if (engine.outstanding_count() != 0)
            `uvm_fatal("ASYNC_RESET", "reset did not release the descriptor")
    endtask

    task check_writeback_completion();
        gq_desc_writeback_completion source;
        mailbox_tx_desc pending_desc;
        mailbox_tx_desc ring_desc;
        gq_desc_base pending[$];
        gq_addr_t ring_base;
        byte packed_data[];
        bit valid;
        int unsigned count;

        source = gq_desc_writeback_completion::type_id::create(
            "writeback_source");
        ring_base = mem.alloc(3 * 64, 64, `__FILE__, `__LINE__);
        if (ring_base == '1)
            `uvm_fatal("WRITEBACK_SETUP", "ring allocation failed")

        for (int unsigned i = 0; i < 3; i++) begin
            pending_desc = make_tx($sformatf("pending_%0d", i), i + 1);
            pending.push_back(pending_desc);
            ring_desc = make_tx($sformatf("ring_%0d", i), i + 1);
            ring_desc.flags = i < 2 ? 16'h0002 : 16'h0001;
            ring_desc.pack(packed_data);
            mem.write_mem(ring_base + (i * 64), packed_data,
                          `__FILE__, `__LINE__);
        end

        source.query_completed(mem, adapter, ring_base, 0, 32, 64, 0,
                               pending, valid, count);
        if (!valid || count != 2)
            `uvm_fatal("WRITEBACK_COUNT", $sformatf(
                "expected valid contiguous count 2, got valid=%0b count=%0d",
                valid, count))
        mem.free(ring_base, `__FILE__, `__LINE__);
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        check_public_completion_contract();
        check_invalid_and_stale_query();
        check_writeback_completion();
        engine.cleanup();
        mem.leak_check(`__FILE__, `__LINE__);
        phase.drop_objection(this);
    endtask
endclass

`endif
