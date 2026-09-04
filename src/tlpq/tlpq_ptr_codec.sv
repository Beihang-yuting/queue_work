// src/tlpq/tlpq_ptr_codec.sv: 通用索引加 phase 指针编码器的 TLPQ 特化实现。
`ifndef TLPQ_PTR_CODEC_SV
`define TLPQ_PTR_CODEC_SV

class tlpq_ptr_codec extends gq_index_phase_ptr_codec;
    `uvm_object_utils(tlpq_ptr_codec)

    function new(string name = "tlpq_ptr_codec");
        super.new(name, 15, 15);
    endfunction
endclass

`endif
