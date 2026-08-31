`ifndef GQ_DESC_WRITEBACK_COMPLETION_SV
`define GQ_DESC_WRITEBACK_COMPLETION_SV

class gq_desc_writeback_completion extends gq_completion_source;
    `uvm_object_utils(gq_desc_writeback_completion)

    function new(string name = "gq_desc_writeback_completion");
        super.new(name);
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
        gq_logical_seq_t seq;
        gq_addr_t slot_addr;
        byte packed_data[];

        valid = 0;
        completed_count = 0;
        if (mem == null || depth == 0 || desc_size == 0)
            return;

        foreach (pending[i]) begin
            if (pending[i] == null) begin
                completed_count = 0;
                return;
            end
            seq = logical_head + i;
            slot_addr = ring_base + ((seq % depth) * desc_size);
            mem.read_mem(slot_addr, desc_size, packed_data,
                         `__FILE__, `__LINE__);
            if (packed_data.size() != desc_size ||
                !pending[i].unpack(packed_data)) begin
                completed_count = 0;
                return;
            end
            if (!pending[i].is_complete(gq_phase(seq, depth))) begin
                valid = 1;
                return;
            end
            completed_count++;
        end
        valid = 1;
    endtask
endclass

`endif
