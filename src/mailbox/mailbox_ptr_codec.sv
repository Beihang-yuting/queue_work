`ifndef MAILBOX_PTR_CODEC_SV
`define MAILBOX_PTR_CODEC_SV

class mailbox_ptr_codec extends gq_index_phase_ptr_codec;
    `uvm_object_utils(mailbox_ptr_codec)

    function new(string name = "mailbox_ptr_codec");
        super.new(name, 15, 15);
    endfunction

    virtual function bit decode_completion(
        gq_raw_ptr_t raw,
        gq_logical_seq_t logical_head,
        int unsigned depth,
        output gq_logical_seq_t completed_tail);
        gq_logical_seq_t candidate;
        gq_logical_seq_t cycle;
        int unsigned index;

        completed_tail = logical_head;
        if (depth == 0 || depth > 32768 || raw[31:16] != 0)
            return 0;

        index = raw[14:0];
        if (index >= depth)
            return 0;

        cycle = logical_head / depth;
        candidate = (cycle * depth) + index;
        if (candidate < logical_head)
            candidate += depth;
        if (bit'((candidate / depth) & 1) != raw[15])
            candidate += depth;

        if (candidate < logical_head ||
            (candidate - logical_head) > depth)
            return 0;

        completed_tail = candidate;
        return 1;
    endfunction
endclass

`endif
