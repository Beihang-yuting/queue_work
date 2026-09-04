// src/tlpq/tlpq_completion.sv: 通用描述符写回完成源的 TLPQ 特化实现。
`ifndef TLPQ_COMPLETION_SV
`define TLPQ_COMPLETION_SV

class tlpq_completion extends gq_desc_writeback_completion;
    `uvm_object_utils(tlpq_completion)

    function new(string name = "tlpq_completion");
        super.new(name);
    endfunction
endclass

`endif
