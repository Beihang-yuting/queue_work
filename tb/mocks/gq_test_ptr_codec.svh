`ifndef GQ_TEST_PTR_CODEC_SVH
`define GQ_TEST_PTR_CODEC_SVH

class gq_test_ptr_codec extends gq_ptr_codec;
    `uvm_object_utils(gq_test_ptr_codec)

    function new(string name = "gq_test_ptr_codec");
        super.new(name);
    endfunction

    virtual function gq_raw_ptr_t encode_publish(
        gq_logical_seq_t old_tail,
        gq_logical_seq_t new_tail,
        int unsigned depth);
        return gq_raw_ptr_t'({15'b0, gq_phase(new_tail, depth), new_tail[15:0]});
    endfunction

endclass

`endif
