// src/msgq/msgq_completion.sv: 读取业务当前指针的 MSGQ 完成源。
`ifndef MSGQ_COMPLETION_SV
`define MSGQ_COMPLETION_SV

class msgq_completion extends gq_completion_source;
    `uvm_object_utils(msgq_completion)

    int unsigned queue_id;

    function new(string name = "msgq_completion",
                 int unsigned queue_id = 0);
        super.new(name);
        this.queue_id = queue_id;
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
        // 适配器当前指针是 MSGQ 的权威状态；引擎仍只退休已经投递的连续逻辑前缀。
        msgq_reg_adapter msgq_adapter;
        bit read_valid;
        bit [15:0] current_ptr;
        int unsigned observed_count;
        gq_logical_seq_t seq;
        gq_addr_t slot_addr;
        byte packed_data[];

        valid = 0;
        completed_count = 0;
        if (mem == null || adapter == null || depth == 0 || desc_size == 0 ||
            !$cast(msgq_adapter, adapter))
            return;

        msgq_adapter.read_msgq_current_ptr(queue_id, read_valid, current_ptr);
        if (!read_valid || int'(current_ptr) >= depth)
            return;

        observed_count = (int'(current_ptr) -
                          int'(logical_head % depth) + int'(depth)) %
                         int'(depth);
        if (observed_count > pending.size())
            return;

        for (int unsigned i = 0; i < observed_count; i++) begin
            if (pending[i] == null)
                return;
        end

        for (int unsigned i = 0; i < observed_count; i++) begin
            seq = logical_head + i;
            slot_addr = ring_base + ((seq % depth) * desc_size);
            packed_data = new[0];
            mem.read_mem(slot_addr, desc_size, packed_data,
                         `__FILE__, `__LINE__);
            if (packed_data.size() != desc_size ||
                !pending[i].unpack(packed_data))
                return;
        end

        completed_count = observed_count;
        valid = 1;
    endtask
endclass

`endif
