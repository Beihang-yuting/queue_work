// tb/mocks/msgq_mock_dut.sv: 用于条目写入、指针更新和原始完成数据的 MSGQ 模拟 DUT 辅助对象。
`ifndef MSGQ_MOCK_DUT_SV
`define MSGQ_MOCK_DUT_SV

class msgq_mock_dut extends uvm_object;
    `uvm_object_utils(msgq_mock_dut)

    host_mem_api mem;
    msgq_mock_adapter adapter;
    int unsigned slot_write_count[int unsigned];
    int unsigned pointer_update_count[int unsigned];
    int unsigned written_slots[int unsigned][$];
    bit [15:0] pointer_history[int unsigned][$];

    function new(string name = "msgq_mock_dut");
        super.new(name);
        mem = null;
        adapter = null;
    endfunction

    function bit write_slot(
        gq_queue_engine engine,
        int unsigned queue_id,
        int unsigned slot,
        int unsigned depth,
        int unsigned entry_size,
        input byte data[]);
        gq_addr_t slot_addr;

        if (mem == null || engine == null || engine.ring_base() == 0 ||
            depth == 0 || slot >= depth || entry_size == 0 ||
            data.size() != entry_size)
            return 0;
        slot_addr = engine.ring_base() + (slot * entry_size);
        mem.write_mem(slot_addr, data, `__FILE__, `__LINE__);
        slot_write_count[queue_id]++;
        written_slots[queue_id].push_back(slot);
        return 1;
    endfunction

    function void set_current_ptr(int unsigned queue_id,
                                  bit [15:0] current_ptr);
        if (adapter == null)
            return;
        adapter.set_current_ptr(queue_id, 1, current_ptr);
        pointer_update_count[queue_id]++;
        pointer_history[queue_id].push_back(current_ptr);
    endfunction

    function void fail_next_current_ptr_read(int unsigned queue_id);
        if (adapter != null)
            adapter.fail_next_read(queue_id);
    endfunction

    function void trigger_irq(int unsigned queue_id);
        if (adapter != null)
            adapter.trigger_irq(queue_id);
    endfunction

    function void snapshot_ring(
        gq_queue_engine engine,
        int unsigned depth,
        int unsigned entry_size,
        ref byte snapshot[]);
        snapshot = new[0];
        if (mem == null || engine == null || engine.ring_base() == 0 ||
            depth == 0 || entry_size == 0)
            return;
        mem.read_mem(engine.ring_base(), depth * entry_size, snapshot,
                     `__FILE__, `__LINE__);
    endfunction
endclass

`endif
