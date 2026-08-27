`ifndef TLPQ_MOCK_DUT_SV
`define TLPQ_MOCK_DUT_SV

class tlpq_driver_mem extends host_mem_manager;
    int unsigned free_counts[gq_addr_t];
    int unsigned allocation_generations[gq_addr_t];
    int unsigned allocation_sizes[gq_addr_t];
    int unsigned allocation_counts_by_size[int unsigned];

    function new(string name = "tlpq_driver_mem");
        super.new(name);
    endfunction

    virtual function bit [63:0] alloc(
        int unsigned size, int unsigned align = 1,
        string file = "", int line = 0);
        gq_addr_t addr;

        addr = super.alloc(size, align, file, line);
        if (addr != '1) begin
            allocation_generations[addr]++;
            allocation_sizes[addr] = size;
            allocation_counts_by_size[size]++;
        end
        return addr;
    endfunction

    virtual function void free(
        bit [63:0] addr, string file = "", int line = 0);
        free_counts[addr]++;
        super.free(addr, file, line);
    endfunction

    function int unsigned free_count(gq_addr_t addr);
        if (!free_counts.exists(addr))
            return 0;
        return free_counts[addr];
    endfunction

    function int unsigned allocation_generation(gq_addr_t addr);
        if (!allocation_generations.exists(addr))
            return 0;
        return allocation_generations[addr];
    endfunction

    function int unsigned allocation_size(gq_addr_t addr);
        if (!allocation_sizes.exists(addr))
            return 0;
        return allocation_sizes[addr];
    endfunction

    function int unsigned allocation_count_for_size(int unsigned size);
        if (!allocation_counts_by_size.exists(size))
            return 0;
        return allocation_counts_by_size[size];
    endfunction
endclass

class tlpq_mock_completion extends tlpq_completion;
    `uvm_object_utils(tlpq_mock_completion)

    tlpq_channel_e channel;
    time query_times[$];
    int unsigned ack_counts_at_query[$];
    uvm_event query_event;
    uvm_event query_blocked;
    uvm_event query_release;
    bit block_next_query_value;

    function new(string name = "tlpq_mock_completion");
        super.new(name);
        channel = TLPQ_HOST;
        query_event = new({name, "_query"});
        query_blocked = new({name, "_query_blocked"});
        query_release = new({name, "_query_release"});
        block_next_query_value = 0;
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
        tlpq_mock_adapter tlpq_adapter;
        int channel_key;
        bit block_this_query;

        channel_key = int'(channel);
        query_times.push_back($time);
        if ($cast(tlpq_adapter, adapter) &&
            tlpq_adapter.ack_irq_count.exists(channel_key))
            ack_counts_at_query.push_back(
                tlpq_adapter.ack_irq_count[channel_key]);
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

class tlpq_mock_dut extends uvm_object;
    `uvm_object_utils(tlpq_mock_dut)

    host_mem_api mem;
    int unsigned completion_write_count;

    function new(string name = "tlpq_mock_dut");
        super.new(name);
        mem = null;
        completion_write_count = 0;
    endfunction

    function gq_addr_t decode_buffer_address(input byte raw[]);
        gq_addr_t value;

        value = 0;
        if (raw.size() < 12)
            return '1;
        for (int unsigned i = 0; i < 8; i++)
            value[(i * 8) +: 8] = raw[4 + i];
        return value;
    endfunction

    function void read_slot(
        gq_queue_engine engine, gq_logical_seq_t logical_seq,
        ref byte raw[]);
        gq_addr_t slot_addr;

        raw = new[0];
        if (mem == null || engine == null || engine.ring_base() == 0)
            return;
        slot_addr = engine.ring_base() +
                    ((logical_seq % TLPQ_DEPTH) * TLPQ_DESC_BYTES);
        mem.read_mem(slot_addr, TLPQ_DESC_BYTES, raw,
                     `__FILE__, `__LINE__);
    endfunction

    function bit complete_slot(
        gq_queue_engine engine,
        gq_logical_seq_t logical_seq,
        input byte dpu_bytes[],
        int unsigned completed_length,
        tlpq_route_metadata_t metadata,
        int stable_corrupt_offset);
        byte raw[];
        gq_addr_t slot_addr;
        gq_addr_t buffer_addr;

        if (mem == null || engine == null || engine.ring_base() == 0 ||
            dpu_bytes.size() > TLPQ_BUFFER_BYTES ||
            completed_length > 16'hffff)
            return 0;
        read_slot(engine, logical_seq, raw);
        if (raw.size() != TLPQ_DESC_BYTES)
            return 0;
        buffer_addr = decode_buffer_address(raw);
        if (buffer_addr == 0 || buffer_addr == '1)
            return 0;
        if (dpu_bytes.size() != 0)
            mem.write_mem(buffer_addr, dpu_bytes, `__FILE__, `__LINE__);
        raw[0] = 8'h03;
        raw[1] = 8'h00;
        raw[2] = byte'(completed_length);
        raw[3] = byte'(completed_length >> 8);
        raw[12] = {metadata.tlp_type, metadata.host_id};
        raw[13] = metadata.primary_bus;
        raw[14] = metadata.secondary_bus;
        raw[15] = metadata.subordinate_bus;
        if (stable_corrupt_offset >= 0 &&
            stable_corrupt_offset < TLPQ_DESC_BYTES)
            raw[stable_corrupt_offset] ^= 8'h01;
        slot_addr = engine.ring_base() +
                    ((logical_seq % TLPQ_DEPTH) * TLPQ_DESC_BYTES);
        mem.write_mem(slot_addr, raw, `__FILE__, `__LINE__);
        completion_write_count++;
        return 1;
    endfunction

    function void trigger_irq(
        tlpq_mock_adapter adapter, tlpq_channel_e channel);
        if (adapter != null)
            adapter.trigger_irq(channel);
    endfunction
endclass

`endif
