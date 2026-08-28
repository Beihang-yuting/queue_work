`ifndef DMAQ_MOCK_DUT_SV
`define DMAQ_MOCK_DUT_SV

class dmaq_driver_mem extends host_mem_manager;
    int unsigned allocation_calls;
    int unsigned free_calls;
    int unsigned free_counts[gq_addr_t];
    int unsigned borrowed_free_attempts;
    bit borrowed_addresses[gq_addr_t];

    function new(string name = "dmaq_driver_mem");
        super.new(name);
        allocation_calls = 0;
        free_calls = 0;
        borrowed_free_attempts = 0;
    endfunction

    function void register_borrowed(gq_addr_t address);
        borrowed_addresses[address] = 1;
    endfunction

    virtual function bit [63:0] alloc(int unsigned size,
                                      int unsigned align = 1,
                                      string file = "", int line = 0);
        allocation_calls++;
        return super.alloc(size, align, file, line);
    endfunction

    virtual function void free(bit [63:0] addr, string file = "",
                               int line = 0);
        free_calls++;
        free_counts[addr]++;
        if (borrowed_addresses.exists(addr)) begin
            borrowed_free_attempts++;
            return;
        end
        super.free(addr, file, line);
    endfunction

    function int unsigned free_count(gq_addr_t address);
        if (!free_counts.exists(address))
            return 0;
        return free_counts[address];
    endfunction
endclass

class dmaq_mock_completion extends dmaq_completion;
    `uvm_object_utils(dmaq_mock_completion)

    time query_times[$];
    int unsigned ack_counts_at_query[$];
    int unsigned queue_id;
    uvm_event query_event;
    uvm_event query_blocked;
    uvm_event query_release;
    bit block_next_query_value;

    function new(string name = "dmaq_mock_completion");
        super.new(name);
        queue_id = 0;
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
        dmaq_mock_adapter dmaq_adapter;
        bit block_this_query;

        query_times.push_back($time);
        if ($cast(dmaq_adapter, adapter) &&
            dmaq_adapter.ack_irq_count.exists(queue_id))
            ack_counts_at_query.push_back(
                dmaq_adapter.ack_irq_count[queue_id]);
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

class dmaq_mock_dut extends uvm_object;
    `uvm_object_utils(dmaq_mock_dut)

    host_mem_api mem;
    dmaq_mock_adapter adapter;
    int unsigned completion_write_count;

    function new(string name = "dmaq_mock_dut");
        super.new(name);
        mem = null;
        adapter = null;
        completion_write_count = 0;
    endfunction

    function void read_slot(gq_queue_engine engine,
                            gq_logical_seq_t logical_seq,
                            int unsigned depth,
                            ref byte raw[]);
        gq_addr_t slot_addr;

        raw = new[0];
        if (mem == null || engine == null || engine.ring_base() == 0 ||
            depth == 0)
            return;
        slot_addr = engine.ring_base() +
                    ((logical_seq % depth) * DMAQ_DESC_BYTES);
        mem.read_mem(slot_addr, DMAQ_DESC_BYTES, raw,
                     `__FILE__, `__LINE__);
    endfunction

    function bit complete_slot(gq_queue_engine engine,
                               gq_logical_seq_t logical_seq,
                               int unsigned depth,
                               int stable_corrupt_offset = -1);
        byte raw[];
        gq_addr_t slot_addr;

        if (mem == null || engine == null || engine.ring_base() == 0 ||
            depth == 0)
            return 0;
        read_slot(engine, logical_seq, depth, raw);
        if (raw.size() != DMAQ_DESC_BYTES)
            return 0;
        raw[0] = byte'(DMAQ_DESC_AVAIL | DMAQ_DESC_USED);
        raw[1] = 8'h00;
        if (stable_corrupt_offset >= 0 &&
            stable_corrupt_offset < DMAQ_DESC_BYTES)
            raw[stable_corrupt_offset] ^= 8'h01;
        slot_addr = engine.ring_base() +
                    ((logical_seq % depth) * DMAQ_DESC_BYTES);
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
