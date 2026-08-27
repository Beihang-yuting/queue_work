`ifndef CMDQ_COMPLETION_SV
`define CMDQ_COMPLETION_SV

class cmdq_completion extends gq_desc_writeback_completion;
    `uvm_object_utils(cmdq_completion)

    function new(string name = "cmdq_completion");
        super.new(name);
    endfunction
endclass

`endif
