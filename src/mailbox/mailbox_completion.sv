`ifndef MAILBOX_COMPLETION_SV
`define MAILBOX_COMPLETION_SV

class mailbox_completion extends gq_completion_source;
    `uvm_object_utils(mailbox_completion)

    function new(string name = "mailbox_completion");
        super.new(name);
    endfunction

    virtual function int unsigned completed_count(
        host_mem_api mem,
        gq_addr_t ring_base,
        gq_addr_t status_addr,
        int unsigned depth,
        int unsigned desc_size,
        gq_logical_seq_t logical_head,
        input gq_desc_base pending[$]);
        int unsigned count;
        gq_logical_seq_t seq;
        gq_addr_t slot_addr;
        byte packed_data[];

        count = 0;
        if (mem == null || depth == 0 || desc_size == 0)
            return 0;

        foreach (pending[i]) begin
            if (pending[i] == null)
                return count;
            seq = logical_head + i;
            slot_addr = ring_base + ((seq % depth) * desc_size);
            mem.read_mem(slot_addr, desc_size, packed_data,
                         `__FILE__, `__LINE__);
            if (!pending[i].unpack(packed_data))
                return count;
            if (!pending[i].is_complete(gq_phase(seq, depth)))
                return count;
            count++;
        end
        return count;
    endfunction
endclass

`endif
