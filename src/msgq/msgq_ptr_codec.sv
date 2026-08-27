`ifndef MSGQ_PTR_CODEC_SV
`define MSGQ_PTR_CODEC_SV

class msgq_ptr_codec extends gq_index_phase_ptr_codec;
    `uvm_object_utils(msgq_ptr_codec)

    function new(string name = "msgq_ptr_codec");
        super.new(name, 15, 15);
    endfunction
endclass

`endif
