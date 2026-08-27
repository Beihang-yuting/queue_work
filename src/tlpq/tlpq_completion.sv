`ifndef TLPQ_COMPLETION_SV
`define TLPQ_COMPLETION_SV

class tlpq_completion extends gq_desc_writeback_completion;
    `uvm_object_utils(tlpq_completion)

    function new(string name = "tlpq_completion");
        super.new(name);
    endfunction
endclass

`endif
