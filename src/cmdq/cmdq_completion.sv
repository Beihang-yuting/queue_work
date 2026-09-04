// src/cmdq/cmdq_completion.sv: 通用描述符写回完成源的 CMDQ 特化实现。
`ifndef CMDQ_COMPLETION_SV
`define CMDQ_COMPLETION_SV

class cmdq_completion extends gq_desc_writeback_completion;
    `uvm_object_utils(cmdq_completion)

    function new(string name = "cmdq_completion");
        super.new(name);
    endfunction
endclass

`endif
