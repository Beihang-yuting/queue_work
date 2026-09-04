// tb/mocks/cmdq_mock_dut.sv: 用于描述符完成和所有权断言的 CMDQ 模拟 DUT/内存辅助对象。
`ifndef CMDQ_MOCK_DUT_SV
`define CMDQ_MOCK_DUT_SV

class cmdq_driver_mem extends host_mem_manager;
    int unsigned free_counts[gq_addr_t];

    function new(string name = "cmdq_driver_mem");
        super.new(name);
    endfunction

    virtual function void free(bit [63:0] addr, string file = "",
                               int line = 0);
        free_counts[addr]++;
        super.free(addr, file, line);
    endfunction

    function int unsigned free_count(gq_addr_t addr);
        if (!free_counts.exists(addr))
            return 0;
        return free_counts[addr];
    endfunction
endclass

class cmdq_mock_completion extends cmdq_completion;
    `uvm_object_utils(cmdq_mock_completion)

    time query_times[$];
    int unsigned ack_counts_at_query[$];
    int unsigned queue_id;
    uvm_event query_event;
    uvm_event query_blocked;
    uvm_event query_release;
    bit block_next_query_value;

    function new(string name = "cmdq_mock_completion");
        super.new(name);
        query_event = new({name, "_query"});
        query_blocked = new({name, "_query_blocked"});
        query_release = new({name, "_query_release"});
        block_next_query_value = 0;
        queue_id = 0;
    endfunction

    function void block_next_query();
        block_next_query_value = 1;
        query_blocked.reset();
        query_release.reset();
    endfunction

    function void release_query();
        query_release.trigger();
    endfunction

    virtual task query_completed(
        host_mem_api mem,
        gq_hw_adapter adapter,
        gq_addr_t ring_base,
        gq_addr_t status_addr,
        int unsigned depth,
        int unsigned desc_size,
        gq_logical_seq_t logical_head,
        input gq_desc_base pending[$],
        output bit valid,
        output int unsigned completed_count);
        bit block_this_query;
        cmdq_mock_adapter cmdq_adapter;

        query_times.push_back($time);
        if ($cast(cmdq_adapter, adapter) &&
            cmdq_adapter.ack_irq_count.exists(queue_id))
            ack_counts_at_query.push_back(
                cmdq_adapter.ack_irq_count[queue_id]);
        else
            ack_counts_at_query.push_back(0);
        block_this_query = block_next_query_value;
        if (block_this_query) begin
            block_next_query_value = 0;
            query_blocked.trigger();
            query_release.wait_on();
        end
        super.query_completed(mem, adapter, ring_base, status_addr,
                              depth, desc_size, logical_head, pending,
                              valid, completed_count);
        query_event.trigger();
    endtask
endclass

class cmdq_mock_dut extends uvm_object;
    `uvm_object_utils(cmdq_mock_dut)

    host_mem_api mem;
    cmdq_mock_adapter adapter;
    int unsigned completion_write_count;

    function new(string name = "cmdq_mock_dut");
        super.new(name);
        mem = null;
        adapter = null;
        completion_write_count = 0;
    endfunction

    protected function gq_addr_t decode_u64(input byte data[],
                                             int unsigned offset);
        gq_addr_t value;

        value = 0;
        if (data.size() < offset + 8)
            return '1;
        for (int unsigned i = 0; i < 8; i++)
            value[(i * 8) +: 8] = data[offset + i];
        return value;
    endfunction

    function void decode_buffer_addresses(input byte raw[],
                                          output gq_addr_t tx_addr,
                                          output gq_addr_t rx_addr);
        tx_addr = decode_u64(raw, 4);
        rx_addr = decode_u64(raw, 16);
    endfunction

    function void read_slot(gq_queue_engine engine,
                            gq_logical_seq_t logical_seq,
                            ref byte raw[]);
        gq_addr_t slot_addr;

        raw = new[0];
        if (mem == null || engine == null || engine.ring_base() == 0)
            return;
        slot_addr = engine.ring_base() +
                    ((logical_seq % CMDQ_DEPTH) * CMDQ_DESC_BYTES);
        mem.read_mem(slot_addr, CMDQ_DESC_BYTES, raw,
                     `__FILE__, `__LINE__);
    endfunction

    function void read_buffer(gq_addr_t addr, int unsigned size,
                              ref byte data[]);
        data = new[0];
        if (mem == null || addr == '1 || size == 0)
            return;
        mem.read_mem(addr, size, data, `__FILE__, `__LINE__);
    endfunction

    function bit complete_slot(gq_queue_engine engine,
                               gq_logical_seq_t logical_seq,
                               input byte result_bytes[],
                               int unsigned rx_length,
                               int stable_corrupt_offset);
        byte raw[];
        gq_addr_t slot_addr;
        gq_addr_t rx_addr;

        if (mem == null || engine == null || engine.ring_base() == 0 ||
            result_bytes.size() > CMDQ_BUFFER_BYTES)
            return 0;
        read_slot(engine, logical_seq, raw);
        if (raw.size() != CMDQ_DESC_BYTES)
            return 0;
        rx_addr = decode_u64(raw, 16);
        if (rx_addr == '1)
            return 0;
        if (result_bytes.size() != 0)
            mem.write_mem(rx_addr, result_bytes, `__FILE__, `__LINE__);
        raw[0] = byte'(CMDQ_DESC_AVAIL | CMDQ_DESC_USED);
        raw[1] = 0;
        raw[14] = byte'(rx_length);
        raw[15] = byte'(rx_length >> 8);
        if (stable_corrupt_offset >= 0 &&
            stable_corrupt_offset < CMDQ_DESC_BYTES)
            raw[stable_corrupt_offset] ^= 8'h01;
        slot_addr = engine.ring_base() +
                    ((logical_seq % CMDQ_DEPTH) * CMDQ_DESC_BYTES);
        mem.write_mem(slot_addr, raw, `__FILE__, `__LINE__);
        completion_write_count++;
        return 1;
    endfunction

    function void trigger_irq(int unsigned queue_id);
        if (adapter != null)
            adapter.trigger_irq(queue_id);
    endfunction
endclass

`endif
