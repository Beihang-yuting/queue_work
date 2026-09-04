// tb/tests/cmdq_desc_test.sv: UVM 测试 cmdq_desc_test：验证对应队列组件的定向行为和接口契约。
`ifndef CMDQ_DESC_TEST_SV
`define CMDQ_DESC_TEST_SV

class cmdq_alloc_error_catcher extends uvm_report_catcher;
    `uvm_object_utils(cmdq_alloc_error_catcher)

    int unsigned caught_errors;

    function new(string name = "cmdq_alloc_error_catcher");
        super.new(name);
        caught_errors = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR && get_id() == "HOST_MEM") begin
            caught_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class cmdq_reg_error_catcher extends uvm_report_catcher;
    `uvm_object_utils(cmdq_reg_error_catcher)

    int unsigned role_errors;
    int unsigned pointer_errors;

    function new(string name = "cmdq_reg_error_catcher");
        super.new(name);
        role_errors = 0;
        pointer_errors = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR && get_id() == "CMDQ_REG_ROLE") begin
            role_errors++;
            return CAUGHT;
        end
        if (get_severity() == UVM_ERROR && get_id() == "CMDQ_REG_PTR") begin
            pointer_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class cmdq_desc_test extends uvm_test;
    `uvm_component_utils(cmdq_desc_test)

    function new(string name = "cmdq_desc_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void expect_byte(string field_name, byte actual, byte expected);
        if (actual !== expected)
            `uvm_fatal("CMDQ_LAYOUT", $sformatf(
                "%s: got 0x%02h expected 0x%02h",
                field_name, actual, expected))
    endfunction

    function void copy_bytes(input byte source[], ref byte destination[]);
        destination = new[source.size()];
        foreach (source[i])
            destination[i] = source[i];
    endfunction

    function void expect_bytes_equal(string check_name, input byte actual[],
                                     input byte expected[]);
        if (actual.size() != expected.size())
            `uvm_fatal("CMDQ_STATE", $sformatf(
                "%s: got size %0d expected %0d", check_name,
                actual.size(), expected.size()))
        foreach (expected[i]) begin
            if (actual[i] !== expected[i])
                `uvm_fatal("CMDQ_STATE", $sformatf(
                    "%s: byte %0d got 0x%02h expected 0x%02h",
                    check_name, i, actual[i], expected[i]))
        end
    endfunction

    function void expect_stable_state(cmdq_tx_desc desc,
                                      byte expected_packed[],
                                      string check_name);
        byte actual_packed[];

        desc.pack(actual_packed);
        expect_bytes_equal(check_name, actual_packed, expected_packed);
        if (desc.tx_buf_len != 16'd3 ||
            desc.tx_buf_addr != 64'h0000_0000_1000_0000 ||
            desc.dst_id != CMDQ_DST_FSE ||
            desc.rx_buf_addr != 64'h0000_0000_1000_0100 ||
            desc.reserved != 64'h0)
            `uvm_fatal("CMDQ_STATE", {check_name,
                ": rejected unpack changed a trusted stable field"})
    endfunction

    function void check_layout_and_buffers(host_mem_manager mem,
                                           output cmdq_tx_desc desc,
                                           output byte submitted[]);
        byte tx_contents[];
        byte rx_contents[];

        desc = cmdq_tx_desc::type_id::create("desc");
        desc.request = new[3];
        desc.request[0] = 8'haa;
        desc.request[1] = 8'h55;
        desc.request[2] = 8'hc3;
        desc.dst_id = CMDQ_DST_FSE;
        desc.attach_mem(mem);

        if (!desc.prepare())
            `uvm_fatal("CMDQ_PREP", "three-byte request preparation failed")
        if (desc.owned_allocation_count() != 2)
            `uvm_fatal("CMDQ_OWNER", $sformatf(
                "got %0d owned allocations expected 2",
                desc.owned_allocation_count()))
        if (desc.tx_buf_addr != 64'h0000_0000_1000_0000 ||
            desc.rx_buf_addr != 64'h0000_0000_1000_0100 ||
            desc.tx_buf_addr == desc.rx_buf_addr)
            `uvm_fatal("CMDQ_ADDR",
                "TX and RX are not the expected distinct 256-byte allocations")
        if (desc.tx_buf_len != 16'd3 ||
            desc.rx_buf_len != CMDQ_BUFFER_BYTES)
            `uvm_fatal("CMDQ_LENGTH",
                "prepared descriptor lengths do not advertise request and RX capacity")

        mem.read_mem(desc.tx_buf_addr, CMDQ_BUFFER_BYTES, tx_contents,
                     `__FILE__, `__LINE__);
        mem.read_mem(desc.rx_buf_addr, CMDQ_BUFFER_BYTES, rx_contents,
                     `__FILE__, `__LINE__);
        if (tx_contents.size() != CMDQ_BUFFER_BYTES ||
            rx_contents.size() != CMDQ_BUFFER_BYTES)
            `uvm_fatal("CMDQ_BUFFER", "owned buffer size is not exactly 256")
        foreach (tx_contents[i]) begin
            if (i < 3) begin
                if (tx_contents[i] !== desc.request[i])
                    `uvm_fatal("CMDQ_TX_DATA", $sformatf(
                        "request byte %0d was not copied", i))
            end else if (tx_contents[i] !== 8'h00) begin
                `uvm_fatal("CMDQ_TX_ZERO", $sformatf(
                    "TX padding byte %0d is not zero", i))
            end
        end
        foreach (rx_contents[i]) begin
            if (rx_contents[i] !== 8'h00)
                `uvm_fatal("CMDQ_RX_ZERO", $sformatf(
                    "RX byte %0d is not zero", i))
        end

        desc.mark_available(1'b1);
        if (desc.flags != CMDQ_DESC_AVAIL ||
            (desc.flags & CMDQ_DESC_USED) != 0)
            `uvm_fatal("CMDQ_FLAGS",
                "submission did not set AVAIL=1 and USED=0")
        desc.pack(submitted);
        if (submitted.size() != CMDQ_DESC_BYTES)
            `uvm_fatal("CMDQ_SIZE", $sformatf(
                "got %0d descriptor bytes expected 32", submitted.size()))

        expect_byte("flags[7:0]",       submitted[0],  8'h01);
        expect_byte("flags[15:8]",      submitted[1],  8'h00);
        expect_byte("tx_buf_len[7:0]",  submitted[2],  8'h03);
        expect_byte("tx_buf_len[15:8]", submitted[3],  8'h00);
        for (int unsigned i = 0; i < 8; i++)
            expect_byte($sformatf("tx_buf_addr[%0d]", i), submitted[4+i],
                        byte'(64'h0000_0000_1000_0000 >> (8*i)));
        expect_byte("dst_id[7:0]",       submitted[12], 8'h02);
        expect_byte("dst_id[15:8]",      submitted[13], 8'h00);
        expect_byte("rx_buf_len[7:0]",   submitted[14], 8'h00);
        expect_byte("rx_buf_len[15:8]",  submitted[15], 8'h01);
        for (int unsigned i = 0; i < 8; i++)
            expect_byte($sformatf("rx_buf_addr[%0d]", i), submitted[16+i],
                        byte'(64'h0000_0000_1000_0100 >> (8*i)));
        for (int unsigned i = 24; i < 32; i++)
            expect_byte($sformatf("reserved[%0d]", i-24), submitted[i], 8'h00);
    endfunction

    function void check_prepare_rejections(host_mem_manager mem);
        cmdq_tx_desc oversized;
        cmdq_tx_desc repeated;
        byte before_tx[];
        byte before_rx[];
        byte after_tx[];
        byte after_rx[];
        gq_addr_t tx_addr;
        gq_addr_t rx_addr;

        oversized = cmdq_tx_desc::type_id::create("oversized");
        oversized.request = new[CMDQ_BUFFER_BYTES + 1];
        foreach (oversized.request[i])
            oversized.request[i] = byte'(i);
        oversized.attach_mem(mem);
        if (oversized.prepare())
            `uvm_fatal("CMDQ_OVERSIZE", "257-byte request was accepted")
        if (oversized.owned_allocation_count() != 0 ||
            oversized.tx_buf_addr != 0 || oversized.rx_buf_addr != 0 ||
            oversized.tx_buf_len != 0 || oversized.rx_buf_len != 0)
            `uvm_fatal("CMDQ_OVERSIZE",
                "oversized request caused allocation or descriptor side effects")

        repeated = cmdq_tx_desc::type_id::create("repeated");
        repeated.request = new[1];
        repeated.request[0] = 8'h7e;
        repeated.dst_id = CMDQ_DST_PSTAT;
        repeated.attach_mem(mem);
        if (!repeated.prepare())
            `uvm_fatal("CMDQ_REPEAT", "initial preparation failed")
        tx_addr = repeated.tx_buf_addr;
        rx_addr = repeated.rx_buf_addr;
        mem.read_mem(tx_addr, CMDQ_BUFFER_BYTES, before_tx,
                     `__FILE__, `__LINE__);
        mem.read_mem(rx_addr, CMDQ_BUFFER_BYTES, before_rx,
                     `__FILE__, `__LINE__);
        repeated.request[0] = 8'h99;
        if (repeated.prepare())
            `uvm_fatal("CMDQ_REPEAT", "second preparation was accepted")
        if (repeated.owned_allocation_count() != 2 ||
            repeated.tx_buf_addr != tx_addr || repeated.rx_buf_addr != rx_addr)
            `uvm_fatal("CMDQ_REPEAT",
                "second preparation changed allocation ownership")
        mem.read_mem(tx_addr, CMDQ_BUFFER_BYTES, after_tx,
                     `__FILE__, `__LINE__);
        mem.read_mem(rx_addr, CMDQ_BUFFER_BYTES, after_rx,
                     `__FILE__, `__LINE__);
        expect_bytes_equal("second prepare TX", after_tx, before_tx);
        expect_bytes_equal("second prepare RX", after_rx, before_rx);

        oversized.release_owned();
        oversized.release_owned();
        repeated.release_owned();
        repeated.release_owned();
    endfunction

    function void check_allocation_rollback();
        host_mem_manager small_mem;
        cmdq_tx_desc desc;
        cmdq_alloc_error_catcher catcher;

        small_mem = new("small_mem");
        small_mem.init_region(64'h2000_0000, 64'h2000_00ff,
                              MODE_LINEAR, 16);
        desc = cmdq_tx_desc::type_id::create("rollback_desc");
        desc.request = new[1];
        desc.request[0] = 8'h5a;
        desc.attach_mem(small_mem);
        catcher = new("catcher");
        uvm_report_cb::add(null, catcher);
        if (desc.prepare())
            `uvm_fatal("CMDQ_ROLLBACK",
                "preparation succeeded without space for the RX buffer")
        uvm_report_cb::delete(null, catcher);
        if (catcher.caught_errors != 1)
            `uvm_fatal("CMDQ_ROLLBACK", $sformatf(
                "caught %0d allocation errors expected 1", catcher.caught_errors))
        if (desc.owned_allocation_count() != 0 ||
            desc.tx_buf_addr != 0 || desc.rx_buf_addr != 0 ||
            desc.tx_buf_len != 0 || desc.rx_buf_len != 0)
            `uvm_fatal("CMDQ_ROLLBACK",
                "failed preparation retained ownership or descriptor state")
        uvm_report_cb::add(null, catcher);
        if (desc.prepare())
            `uvm_fatal("CMDQ_ROLLBACK",
                "allocation-failed descriptor was prepared a second time")
        uvm_report_cb::delete(null, catcher);
        if (catcher.caught_errors != 1)
            `uvm_fatal("CMDQ_ROLLBACK",
                "second prepare retried allocation after a failed attempt")
        desc.release_owned();
        desc.release_owned();
        small_mem.leak_check(`__FILE__, `__LINE__);
    endfunction

    function void expect_corruption_rejected(cmdq_tx_desc desc,
                                             byte submitted[],
                                             int unsigned offset,
                                             string field_name);
        byte corrupted[];

        copy_bytes(submitted, corrupted);
        corrupted[offset] = corrupted[offset] ^ 8'h01;
        if (desc.unpack(corrupted))
            `uvm_fatal("CMDQ_CORRUPT", {field_name, " corruption was accepted"})
        expect_stable_state(desc, submitted, {field_name, " rejection"});
    endfunction

    function void check_stable_fields(cmdq_tx_desc desc, byte submitted[]);
        byte wrong_size[];

        expect_corruption_rejected(desc, submitted, 2,  "TX length");
        expect_corruption_rejected(desc, submitted, 4,  "TX address");
        expect_corruption_rejected(desc, submitted, 12, "destination");
        expect_corruption_rejected(desc, submitted, 16, "RX address");
        expect_corruption_rejected(desc, submitted, 24, "reserved");

        wrong_size = new[CMDQ_DESC_BYTES - 1];
        if (desc.unpack(wrong_size))
            `uvm_fatal("CMDQ_CORRUPT", "wrong-size descriptor was accepted")
        expect_stable_state(desc, submitted, "wrong-size rejection");
    endfunction

    function void check_completion(host_mem_manager mem,
                                   cmdq_tx_desc desc,
                                   byte submitted[]);
        byte completion[];
        byte result_bytes[];

        if (desc.parse_completion())
            `uvm_fatal("CMDQ_USED", "completion without USED was accepted")
        if (desc.completion_event.is_on() || desc.result.size() != 0)
            `uvm_fatal("CMDQ_USED",
                "incomplete descriptor changed result or completion event")

        copy_bytes(submitted, completion);
        completion[0]  = byte'(CMDQ_DESC_AVAIL | CMDQ_DESC_USED);
        completion[1]  = 8'h00;
        completion[14] = 8'h01;
        completion[15] = 8'h01;
        if (!desc.unpack(completion))
            `uvm_fatal("CMDQ_RX_LEN",
                "permitted oversized RX completion length was rejected by unpack")
        if (!desc.is_complete(1'b1))
            `uvm_fatal("CMDQ_USED", "USED completion was not detected")
        if (desc.parse_completion())
            `uvm_fatal("CMDQ_RX_LEN", "257-byte completion result was accepted")
        if (desc.completion_event.is_on())
            `uvm_fatal("CMDQ_EVENT",
                "invalid completion triggered the persistent event")
        if (desc.result.size() != 0)
            `uvm_fatal("CMDQ_RESULT",
                "invalid completion produced result bytes")

        copy_bytes(submitted, completion);
        completion[0]  = byte'(CMDQ_DESC_AVAIL | CMDQ_DESC_USED);
        completion[1]  = 8'h00;
        completion[14] = 8'h05;
        completion[15] = 8'h00;
        result_bytes = new[5];
        result_bytes[0] = 8'h10;
        result_bytes[1] = 8'h20;
        result_bytes[2] = 8'h30;
        result_bytes[3] = 8'h40;
        result_bytes[4] = 8'h50;
        mem.write_mem(desc.rx_buf_addr, result_bytes, `__FILE__, `__LINE__);
        if (!desc.unpack(completion))
            `uvm_fatal("CMDQ_COMPLETION", "valid completion was rejected")
        if (!desc.is_complete(1'b0))
            `uvm_fatal("CMDQ_COMPLETION", "valid USED completion was not detected")
        if (!desc.parse_completion())
            `uvm_fatal("CMDQ_COMPLETION", "valid result parse failed")
        expect_bytes_equal("copied completion result", desc.result, result_bytes);
        if (!desc.completion_event.is_on())
            `uvm_fatal("CMDQ_EVENT", "completion event was not persistent")

        desc.release_owned();
        desc.release_owned();
        expect_bytes_equal("released completion result", desc.result, result_bytes);
        if (!desc.completion_event.is_on())
            `uvm_fatal("CMDQ_EVENT",
                "completion event did not survive buffer release")
    endfunction

    function cmdq_tx_desc make_strategy_desc(
        string name, host_mem_manager mem, byte request_byte);
        cmdq_tx_desc desc;

        desc = cmdq_tx_desc::type_id::create(name);
        desc.request = new[1];
        desc.request[0] = request_byte;
        desc.dst_id = CMDQ_DST_FSE;
        desc.attach_mem(mem);
        if (!desc.prepare())
            `uvm_fatal("CMDQ_STRATEGY_SETUP", {name, " preparation failed"})
        desc.mark_available(1'b0);
        return desc;
    endfunction

    task check_pointer_and_queue_validation();
        cmdq_ptr_codec codec;
        cmdq_completion completion;
        gq_queue_cfg cfg;
        string reason;

        codec = cmdq_ptr_codec::type_id::create("codec");
        if (codec.encode_publish(0, 1, CMDQ_DEPTH) != 32'h0000_0001 ||
            codec.encode_publish(1, 31, CMDQ_DEPTH) != 32'h0000_001f ||
            codec.encode_publish(31, 32, CMDQ_DEPTH) != 32'h0000_8000 ||
            codec.encode_publish(32, 64, CMDQ_DEPTH) != 32'h0000_0000)
            `uvm_fatal("CMDQ_PTR", "bit-15 pointer vectors did not match")

        completion = cmdq_completion::type_id::create("cfg_completion");
        cfg = gq_queue_cfg::type_id::create("cfg");
        cfg.role = GQ_TX;
        cfg.depth = 32'h0001_0000;
        cfg.desc_size = CMDQ_DESC_BYTES;
        cfg.alignment = CMDQ_DESC_BYTES;
        cfg.completion_timeout = 100ns;
        cfg.poll_min_interval = 10ns;
        cfg.poll_max_interval = 10ns;
        cfg.ptr_codec = codec;
        cfg.completion_source = completion;
        if (cfg.validate(reason) ||
            reason != "pointer codec: depth must be between 1 and 32768 (got 65536)")
            `uvm_fatal("CMDQ_PTR_VALIDATE", $sformatf(
                "unsupported queue depth was not rejected before programming: %s",
                reason))
    endtask

    task check_completion_strategy();
        host_mem_manager mem;
        cmdq_mock_adapter adapter;
        cmdq_completion completion;
        cmdq_tx_desc first;
        cmdq_tx_desc second;
        gq_desc_base pending[$];
        gq_addr_t ring_base;
        byte first_bytes[];
        byte second_bytes[];
        byte first_tx_before[];
        byte first_tx_after[];
        byte first_rx_before[];
        byte first_rx_after[];
        byte second_tx_before[];
        byte second_tx_after[];
        byte second_rx_before[];
        byte second_rx_after[];
        byte first_after[];
        byte second_after[];
        bit valid;
        int unsigned count;

        mem = new("strategy_mem");
        mem.init_region(64'h3000_0000, 64'h3000_ffff,
                        MODE_LINEAR, 16);
        ring_base = mem.alloc(2 * CMDQ_DESC_BYTES, CMDQ_DESC_BYTES,
                              `__FILE__, `__LINE__);
        if (ring_base == '1)
            `uvm_fatal("CMDQ_STRATEGY_SETUP", "ring allocation failed")

        first = make_strategy_desc("first", mem, 8'ha1);
        second = make_strategy_desc("second", mem, 8'hb2);
        first.pack(first_bytes);
        second.pack(second_bytes);
        first_bytes[0] = byte'(CMDQ_DESC_AVAIL | CMDQ_DESC_USED);
        mem.write_mem(ring_base, first_bytes, `__FILE__, `__LINE__);
        mem.write_mem(ring_base + CMDQ_DESC_BYTES, second_bytes,
                      `__FILE__, `__LINE__);
        mem.read_mem(first.tx_buf_addr, CMDQ_BUFFER_BYTES, first_tx_before,
                     `__FILE__, `__LINE__);
        mem.read_mem(first.rx_buf_addr, CMDQ_BUFFER_BYTES, first_rx_before,
                     `__FILE__, `__LINE__);
        mem.read_mem(second.tx_buf_addr, CMDQ_BUFFER_BYTES, second_tx_before,
                     `__FILE__, `__LINE__);
        mem.read_mem(second.rx_buf_addr, CMDQ_BUFFER_BYTES, second_rx_before,
                     `__FILE__, `__LINE__);

        pending.push_back(first);
        pending.push_back(second);
        adapter = cmdq_mock_adapter::type_id::create("completion_adapter");
        completion = cmdq_completion::type_id::create("completion");
        completion.query_completed(mem, adapter, ring_base, 0, 2,
                                   CMDQ_DESC_BYTES, 0, pending, valid, count);
        if (!valid || count != 1)
            `uvm_fatal("CMDQ_COMPLETION_STRATEGY", $sformatf(
                "got valid=%0b count=%0d expected valid=1 count=1",
                valid, count))
        if ((first.flags & CMDQ_DESC_USED) == 0 ||
            (second.flags & CMDQ_DESC_USED) != 0 ||
            first.tx_buf_addr == second.tx_buf_addr ||
            first.rx_buf_addr == second.rx_buf_addr)
            `uvm_fatal("CMDQ_COMPLETION_STABLE",
                "writeback changed stable descriptor ownership or ordering")
        first.pack(first_after);
        second.pack(second_after);
        expect_bytes_equal("first completion descriptor",
                           first_after, first_bytes);
        expect_bytes_equal("second incomplete descriptor",
                           second_after, second_bytes);
        mem.read_mem(first.tx_buf_addr, CMDQ_BUFFER_BYTES, first_tx_after,
                     `__FILE__, `__LINE__);
        mem.read_mem(first.rx_buf_addr, CMDQ_BUFFER_BYTES, first_rx_after,
                     `__FILE__, `__LINE__);
        mem.read_mem(second.tx_buf_addr, CMDQ_BUFFER_BYTES, second_tx_after,
                     `__FILE__, `__LINE__);
        mem.read_mem(second.rx_buf_addr, CMDQ_BUFFER_BYTES, second_rx_after,
                     `__FILE__, `__LINE__);
        expect_bytes_equal("first completion TX buffer",
                           first_tx_after, first_tx_before);
        expect_bytes_equal("first completion RX buffer",
                           first_rx_after, first_rx_before);
        expect_bytes_equal("second completion TX buffer",
                           second_tx_after, second_tx_before);
        expect_bytes_equal("second completion RX buffer",
                           second_rx_after, second_rx_before);

        first.release_owned();
        second.release_owned();
        mem.free(ring_base, `__FILE__, `__LINE__);
        mem.leak_check(`__FILE__, `__LINE__);
    endtask

    task check_semantic_adapter();
        localparam int unsigned QUEUE_ID = 0;
        localparam gq_addr_t RING_BASE = 64'h0000_0000_4000_0000;
        cmdq_hw_cfg_t hw_cfg;
        cmdq_mock_adapter adapter;
        cmdq_reg_error_catcher catcher;
        string expected_trace[$] = '{"RESET(queue=0)",
                                     {"CONFIGURE(queue=0,base=0x0000000040000000,",
                                      "depth=32,size=32,hid=0x5a,fid=0x1234,",
                                      "msix=0x0042,valid=1)"},
                                     "ENABLE(queue=0)",
                                     "PUBLISH(queue=0,tail=0x801f)"};
        string expected_control_trace[$] = '{"WAIT_IRQ(queue=0)",
                                             "ACK_IRQ(queue=0)",
                                             "DISABLE(queue=0)"};

        hw_cfg.host_id = 8'h5a;
        hw_cfg.function_id = 16'h1234;
        hw_cfg.msix_index = 16'h0042;
        hw_cfg.msix_valid = 1'b1;
        adapter = new("adapter", hw_cfg);

        adapter.configure_queue(GQ_TX, QUEUE_ID, RING_BASE,
                                CMDQ_DEPTH, CMDQ_DESC_BYTES);
        adapter.publish(GQ_TX, QUEUE_ID, 32'h0000_801f);
        if (adapter.trace != expected_trace)
            `uvm_fatal("CMDQ_ADAPTER_TRACE", "semantic event order changed")
        if (adapter.reset_count[QUEUE_ID] != 1 ||
            adapter.configure_count[QUEUE_ID] != 1 ||
            adapter.enable_count[QUEUE_ID] != 1 ||
            adapter.publish_count[QUEUE_ID] != 1 ||
            adapter.configured_base[QUEUE_ID] != RING_BASE ||
            adapter.configured_depth[QUEUE_ID] != CMDQ_DEPTH ||
            adapter.configured_desc_size[QUEUE_ID] != CMDQ_DESC_BYTES ||
            adapter.configured_hw_cfg[QUEUE_ID] != hw_cfg ||
            adapter.published_tails[QUEUE_ID].size() != 1 ||
            adapter.published_tails[QUEUE_ID][0] != 16'h801f)
            `uvm_fatal("CMDQ_ADAPTER_ARGS",
                "semantic metadata, counters, or tail were not preserved")

        adapter.clear_trace();
        adapter.trigger_irq(QUEUE_ID);
        adapter.wait_irq(GQ_TX, QUEUE_ID);
        adapter.ack_irq(GQ_TX, QUEUE_ID);
        adapter.disable_queue(GQ_TX, QUEUE_ID);
        if (adapter.trace != expected_control_trace ||
            adapter.wait_irq_count[QUEUE_ID] != 1 ||
            adapter.ack_irq_count[QUEUE_ID] != 1 ||
            adapter.disable_count[QUEUE_ID] != 1)
            `uvm_fatal("CMDQ_ADAPTER_CONTROL",
                "semantic IRQ/disable callbacks were not queue-indexed")

        adapter.clear_trace();
        catcher = cmdq_reg_error_catcher::type_id::create("reg_catcher");
        uvm_report_cb::add(null, catcher);
        adapter.configure_queue(GQ_RX, QUEUE_ID, RING_BASE,
                                CMDQ_DEPTH, CMDQ_DESC_BYTES);
        adapter.disable_queue(GQ_RX, QUEUE_ID);
        adapter.publish(GQ_RX, QUEUE_ID, 32'h0000_0001);
        adapter.wait_irq(GQ_RX, QUEUE_ID);
        adapter.ack_irq(GQ_RX, QUEUE_ID);
        adapter.publish(GQ_TX, QUEUE_ID, 32'h0001_0001);
        uvm_report_cb::delete(null, catcher);
        if (catcher.role_errors != 5 || catcher.pointer_errors != 1)
            `uvm_fatal("CMDQ_ADAPTER_REJECT", $sformatf(
                "got role/pointer errors %0d/%0d expected 5/1",
                catcher.role_errors, catcher.pointer_errors))
        if (adapter.trace.size() != 0 ||
            adapter.reset_count[QUEUE_ID] != 1 ||
            adapter.configure_count[QUEUE_ID] != 1 ||
            adapter.enable_count[QUEUE_ID] != 1 ||
            adapter.disable_count[QUEUE_ID] != 1 ||
            adapter.publish_count[QUEUE_ID] != 1 ||
            adapter.wait_irq_count[QUEUE_ID] != 1 ||
            adapter.ack_irq_count[QUEUE_ID] != 1)
            `uvm_fatal("CMDQ_ADAPTER_LEAK",
                "rejected generic operation reached a semantic callback")
    endtask

    function void build_phase(uvm_phase phase);
        host_mem_manager mem;
        cmdq_tx_desc desc;
        byte submitted[];

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h1000_0000, 64'h1000_ffff,
                        MODE_LINEAR, 16);

        check_layout_and_buffers(mem, desc, submitted);
        check_prepare_rejections(mem);
        check_allocation_rollback();
        check_stable_fields(desc, submitted);
        check_completion(mem, desc, submitted);
        mem.leak_check(`__FILE__, `__LINE__);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        check_pointer_and_queue_validation();
        check_completion_strategy();
        check_semantic_adapter();
        phase.drop_objection(this);
    endtask
endclass

`endif
