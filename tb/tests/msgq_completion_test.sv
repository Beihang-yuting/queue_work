// tb/tests/msgq_completion_test.sv: UVM 测试 msgq_completion_test：验证对应队列组件的定向行为和接口契约。
`ifndef MSGQ_COMPLETION_TEST_SV
`define MSGQ_COMPLETION_TEST_SV

class msgq_completion_test_mem extends host_mem_manager;
    `uvm_object_utils(msgq_completion_test_mem)

    gq_addr_t read_addrs[$];
    int unsigned read_sizes[$];
    bit short_next_read;

    function new(string name = "msgq_completion_test_mem");
        super.new(name);
        short_next_read = 0;
    endfunction

    function void clear_reads();
        read_addrs.delete();
        read_sizes.delete();
    endfunction

    virtual function void read_mem(
        bit [63:0] addr,
        int unsigned size,
        ref byte data[],
        input string file = "",
        input int line = 0);
        read_addrs.push_back(addr);
        read_sizes.push_back(size);
        if (short_next_read) begin
            short_next_read = 0;
            data = new[size == 0 ? 0 : size - 1];
            return;
        end
        super.read_mem(addr, size, data, file, line);
    endfunction
endclass

class msgq_wrong_adapter extends gq_hw_adapter;
    `uvm_object_utils(msgq_wrong_adapter)

    function new(string name = "msgq_wrong_adapter");
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

class msgq_reg_error_catcher extends uvm_report_catcher;
    `uvm_object_utils(msgq_reg_error_catcher)

    int unsigned role_errors;
    int unsigned pointer_errors;

    function new(string name = "msgq_reg_error_catcher");
        super.new(name);
        role_errors = 0;
        pointer_errors = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR && get_id() == "MSGQ_REG_ROLE") begin
            role_errors++;
            return CAUGHT;
        end
        if (get_severity() == UVM_ERROR && get_id() == "MSGQ_REG_PTR") begin
            pointer_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class msgq_completion_test extends uvm_test;
    `uvm_component_utils(msgq_completion_test)

    localparam int unsigned TEST_QUEUE_ID = 9;
    localparam int unsigned TEST_DEPTH = 8;
    localparam int unsigned TEST_ENTRY_SIZE = 4;

    msgq_completion_test_mem mem;
    msgq_mock_adapter adapter;
    msgq_completion completion;
    gq_addr_t ring_base;

    function new(string name = "msgq_completion_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function msgq_raw_entry make_pending(string name,
                                         int unsigned entry_size =
                                             TEST_ENTRY_SIZE);
        msgq_raw_entry entry;

        entry = msgq_raw_entry::type_id::create(name);
        entry.set_entry_size(entry_size);
        return entry;
    endfunction

    function void check_bytes(msgq_raw_entry entry, byte expected[],
                              string description);
        if (entry.raw_bytes != expected)
            `uvm_fatal("MSGQ_COMPLETION_BYTES", $sformatf(
                "%s unpacked bytes out of order", description))
    endfunction

    function void write_slot(int unsigned slot, byte data[]);
        mem.write_mem(ring_base + (slot * TEST_ENTRY_SIZE), data,
                      `__FILE__, `__LINE__);
    endfunction

    task query(gq_hw_adapter query_adapter,
               gq_logical_seq_t logical_head,
               input gq_desc_base pending[$],
               output bit valid,
               output int unsigned count);
        completion.query_completed(mem, query_adapter, ring_base, 0,
                                   TEST_DEPTH, TEST_ENTRY_SIZE,
                                   logical_head, pending, valid, count);
    endtask

    task check_adapter_and_pointer();
        msgq_ptr_codec codec;
        msgq_reg_error_catcher catcher;
        bit read_valid;
        bit [15:0] current_ptr;
        string expected_trace[$] = '{"RESET", "CONFIGURE", "ENABLE",
                                     "PUBLISH", "WAIT_IRQ", "ACK_IRQ",
                                     "READ_CURRENT_PTR", "DISABLE"};
        int unsigned trace_before;

        codec = msgq_ptr_codec::type_id::create("codec");
        if (codec.encode_publish(0, 127, 128) != 32'h0000_007f)
            `uvm_fatal("MSGQ_PTR_INITIAL",
                       "depth-128 initial tail did not encode as 16'h007f")
        if (codec.encode_publish(127, 128, 128) != 32'h0000_8000)
            `uvm_fatal("MSGQ_PTR_WRAP",
                       "depth-128 wrap did not encode as 16'h8000")

        adapter.clear_trace();
        adapter.record_reset(TEST_QUEUE_ID);
        adapter.configure_queue(GQ_RX, TEST_QUEUE_ID, ring_base,
                                TEST_DEPTH, TEST_ENTRY_SIZE);
        adapter.record_enable(TEST_QUEUE_ID);
        adapter.publish(GQ_RX, TEST_QUEUE_ID, 32'h0000_007f);
        adapter.trigger_irq(TEST_QUEUE_ID);
        adapter.wait_irq(GQ_RX, TEST_QUEUE_ID);
        adapter.ack_irq(GQ_RX, TEST_QUEUE_ID);
        adapter.set_current_ptr(TEST_QUEUE_ID, 1, 16'h0003);
        adapter.read_msgq_current_ptr(TEST_QUEUE_ID, read_valid, current_ptr);
        adapter.disable_queue(GQ_RX, TEST_QUEUE_ID);
        if (!read_valid || current_ptr != 16'h0003 ||
            adapter.trace != expected_trace)
            `uvm_fatal("MSGQ_ADAPTER_TRACE",
                       "semantic adapter trace or readback did not match")
        if (adapter.configured_base[TEST_QUEUE_ID] != ring_base ||
            adapter.configured_depth[TEST_QUEUE_ID] != TEST_DEPTH ||
            adapter.configured_entry_size[TEST_QUEUE_ID] != TEST_ENTRY_SIZE ||
            adapter.published_tails[TEST_QUEUE_ID].size() != 1 ||
            adapter.published_tails[TEST_QUEUE_ID][0] != 16'h007f ||
            adapter.wait_irq_count[TEST_QUEUE_ID] != 1 ||
            adapter.ack_irq_count[TEST_QUEUE_ID] != 1)
            `uvm_fatal("MSGQ_ADAPTER_ARGS",
                       "semantic adapter arguments were not preserved")

        adapter.clear_trace();
        catcher = msgq_reg_error_catcher::type_id::create("catcher");
        uvm_report_cb::add(null, catcher);
        adapter.configure_queue(GQ_TX, TEST_QUEUE_ID, ring_base,
                                TEST_DEPTH, TEST_ENTRY_SIZE);
        adapter.disable_queue(GQ_TX, TEST_QUEUE_ID);
        adapter.publish(GQ_TX, TEST_QUEUE_ID, 32'h0000_0001);
        adapter.wait_irq(GQ_TX, TEST_QUEUE_ID);
        adapter.ack_irq(GQ_TX, TEST_QUEUE_ID);
        adapter.publish(GQ_RX, TEST_QUEUE_ID, 32'h0001_0001);
        uvm_report_cb::delete(null, catcher);
        if (catcher.role_errors != 5 || catcher.pointer_errors != 1)
            `uvm_fatal("MSGQ_ADAPTER_REJECT", $sformatf(
                "expected five role errors and one pointer error, got %0d/%0d",
                catcher.role_errors, catcher.pointer_errors))
        if (adapter.trace.size() != 0)
            `uvm_fatal("MSGQ_ADAPTER_LEAK",
                       "rejected generic operation reached a semantic callback")

        trace_before = adapter.trace.size();
        adapter.set_current_ptr(TEST_QUEUE_ID, 1, 0);
        if (adapter.trace.size() != trace_before)
            `uvm_fatal("MSGQ_ADAPTER_CONTROL",
                       "per-queue pointer control polluted semantic trace")
    endtask

    task check_pointer_arithmetic_and_order();
        gq_desc_base pending[$];
        msgq_raw_entry pending_entry[3];
        byte slot7[] = '{8'h70, 8'h71, 8'h72, 8'h73};
        byte slot0[] = '{8'h00, 8'h01, 8'h02, 8'h03};
        byte slot1[] = '{8'h10, 8'h11, 8'h12, 8'h13};
        bit valid;
        int unsigned count;

        adapter.set_current_ptr(TEST_QUEUE_ID, 1, 0);
        query(adapter, 0, pending, valid, count);
        if (!valid || count != 0 || mem.read_addrs.size() != 0)
            `uvm_fatal("MSGQ_COMPLETION_IDLE",
                       "equal current/head pointer was not zero progress")

        write_slot(0, slot0);
        write_slot(1, slot1);
        write_slot(7, slot7);
        for (int unsigned i = 0; i < 3; i++) begin
            pending_entry[i] = make_pending($sformatf("ordered_%0d", i));
            pending.push_back(pending_entry[i]);
        end
        mem.clear_reads();
        adapter.set_current_ptr(TEST_QUEUE_ID, 1, 3);
        query(adapter, 0, pending, valid, count);
        if (!valid || count != 3 || mem.read_addrs.size() != 3 ||
            mem.read_addrs[0] != ring_base ||
            mem.read_addrs[1] != ring_base + TEST_ENTRY_SIZE ||
            mem.read_addrs[2] != ring_base + (2 * TEST_ENTRY_SIZE))
            `uvm_fatal("MSGQ_COMPLETION_LINEAR",
                       "head=0 current=3 did not read exactly slots 0,1,2")

        pending.delete();
        for (int unsigned i = 0; i < 3; i++) begin
            pending_entry[i] = make_pending($sformatf("wrapped_%0d", i));
            pending.push_back(pending_entry[i]);
        end
        mem.clear_reads();
        adapter.set_current_ptr(TEST_QUEUE_ID, 1, 2);
        query(adapter, 7, pending, valid, count);
        if (!valid || count != 3 || mem.read_addrs.size() != 3 ||
            mem.read_addrs[0] != ring_base + (7 * TEST_ENTRY_SIZE) ||
            mem.read_addrs[1] != ring_base ||
            mem.read_addrs[2] != ring_base + TEST_ENTRY_SIZE)
            `uvm_fatal("MSGQ_COMPLETION_WRAP",
                       "head=7 current=2 did not read exactly slots 7,0,1")
        check_bytes(pending_entry[0], slot7, "wrapped pending[0]");
        check_bytes(pending_entry[1], slot0, "wrapped pending[1]");
        check_bytes(pending_entry[2], slot1, "wrapped pending[2]");
    endtask

    task check_invalid_queries();
        gq_desc_base pending[$];
        gq_hw_adapter null_adapter;
        msgq_wrong_adapter wrong_adapter;
        bit valid;
        int unsigned count;

        for (int unsigned i = 0; i < 2; i++)
            pending.push_back(make_pending($sformatf("guard_%0d", i)));

        mem.clear_reads();
        adapter.set_current_ptr(TEST_QUEUE_ID, 1, 3);
        query(adapter, 0, pending, valid, count);
        if (valid || count != 0 || mem.read_addrs.size() != 0)
            `uvm_fatal("MSGQ_COMPLETION_PENDING",
                       "count exceeding pending was not rejected before indexing")

        adapter.set_current_ptr(TEST_QUEUE_ID, 1, TEST_DEPTH);
        query(adapter, 0, pending, valid, count);
        if (valid || count != 0)
            `uvm_fatal("MSGQ_COMPLETION_RANGE",
                       "current pointer at depth was accepted")

        adapter.set_current_ptr(TEST_QUEUE_ID, 0, 0);
        query(adapter, 0, pending, valid, count);
        if (valid || count != 0)
            `uvm_fatal("MSGQ_COMPLETION_READ",
                       "invalid adapter read was accepted")

        null_adapter = null;
        query(null_adapter, 0, pending, valid, count);
        if (valid || count != 0)
            `uvm_fatal("MSGQ_COMPLETION_ADAPTER",
                       "null adapter was accepted")

        wrong_adapter = msgq_wrong_adapter::type_id::create("wrong_adapter");
        query(wrong_adapter, 0, pending, valid, count);
        if (valid || count != 0)
            `uvm_fatal("MSGQ_COMPLETION_CAST",
                       "non-MSGQ adapter was accepted")

        adapter.set_current_ptr(TEST_QUEUE_ID, 1, 1);
        mem.short_next_read = 1;
        query(adapter, 0, pending, valid, count);
        if (valid || count != 0)
            `uvm_fatal("MSGQ_COMPLETION_SHORT",
                       "short ring read was accepted")

        pending.delete();
        pending.push_back(null);
        query(adapter, 0, pending, valid, count);
        if (valid || count != 0)
            `uvm_fatal("MSGQ_COMPLETION_NULL",
                       "null pending entry was accepted")

        pending.delete();
        pending.push_back(make_pending("bad_unpack", TEST_ENTRY_SIZE + 1));
        query(adapter, 0, pending, valid, count);
        if (valid || count != 0)
            `uvm_fatal("MSGQ_COMPLETION_UNPACK",
                       "failed pending-entry unpack was accepted")
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        mem = new("mem");
        mem.init_region(64'h0000_0001_b000_0000,
                        64'h0000_0001_b0ff_ffff, MODE_LINEAR, 16);
        ring_base = mem.alloc(TEST_DEPTH * TEST_ENTRY_SIZE,
                              TEST_ENTRY_SIZE, `__FILE__, `__LINE__);
        if (ring_base == '1)
            `uvm_fatal("MSGQ_COMPLETION_SETUP", "ring allocation failed")
        adapter = msgq_mock_adapter::type_id::create("adapter");
        completion = new("completion", TEST_QUEUE_ID);

        check_adapter_and_pointer();
        mem.clear_reads();
        check_pointer_arithmetic_and_order();
        check_invalid_queries();

        mem.free(ring_base, `__FILE__, `__LINE__);
        mem.leak_check(`__FILE__, `__LINE__);
        phase.drop_objection(this);
    endtask
endclass

`endif
