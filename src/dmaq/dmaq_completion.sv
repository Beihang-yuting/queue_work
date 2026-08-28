`ifndef DMAQ_COMPLETION_SV
`define DMAQ_COMPLETION_SV

class dmaq_completion extends gq_desc_writeback_completion;
    `uvm_object_utils(dmaq_completion)

    function new(string name = "dmaq_completion");
        super.new(name);
    endfunction
endclass

`endif
