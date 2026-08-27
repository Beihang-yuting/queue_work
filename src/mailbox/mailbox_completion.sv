`ifndef MAILBOX_COMPLETION_SV
`define MAILBOX_COMPLETION_SV

class mailbox_completion extends gq_desc_writeback_completion;
    `uvm_object_utils(mailbox_completion)

    function new(string name = "mailbox_completion");
        super.new(name);
    endfunction

endclass

`endif
