`ifndef DMAQ_PTR_CODEC_SV
`define DMAQ_PTR_CODEC_SV

class dmaq_ptr_codec extends gq_index_phase_ptr_codec;
    `uvm_object_utils(dmaq_ptr_codec)

    function new(string name = "dmaq_ptr_codec");
        super.new(name, 15, 15);
    endfunction
endclass

`endif
