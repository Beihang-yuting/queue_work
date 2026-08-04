`ifndef GQ_PTR_CODEC_SVH
`define GQ_PTR_CODEC_SVH

virtual class gq_ptr_codec extends uvm_object;
    function new(string name = "gq_ptr_codec");
        super.new(name);
    endfunction

    pure virtual function gq_raw_ptr_t encode_publish(
        gq_logical_seq_t old_tail,
        gq_logical_seq_t new_tail,
        int unsigned depth);

    virtual function bit decode_completion(
        gq_raw_ptr_t raw,
        gq_logical_seq_t logical_head,
        int unsigned depth,
        output gq_logical_seq_t completed_tail);
        completed_tail = logical_head;
        return 0;
    endfunction
endclass

`endif
