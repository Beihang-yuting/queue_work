`ifndef TLPQ_PTR_CODEC_SV
`define TLPQ_PTR_CODEC_SV

class tlpq_ptr_codec extends gq_index_phase_ptr_codec;
    `uvm_object_utils(tlpq_ptr_codec)

    function new(string name = "tlpq_ptr_codec");
        super.new(name, 15, 15);
    endfunction
endclass

`endif
