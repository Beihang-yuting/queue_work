`ifndef CMDQ_PTR_CODEC_SV
`define CMDQ_PTR_CODEC_SV

class cmdq_ptr_codec extends gq_index_phase_ptr_codec;
    `uvm_object_utils(cmdq_ptr_codec)

    function new(string name = "cmdq_ptr_codec");
        super.new(name, 15, 15);
    endfunction
endclass

`endif
