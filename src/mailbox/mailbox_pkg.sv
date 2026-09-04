// src/mailbox/mailbox_pkg.sv: Mailbox 包的导入和源码包含顺序。
`ifndef MAILBOX_PKG_SV
`define MAILBOX_PKG_SV

package mailbox_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    `include "uvm_macros.svh"

    `include "mailbox_ptr_codec.sv"
    `include "mailbox_reg_adapter.sv"
    `include "mailbox_tx_desc.sv"
    `include "mailbox_rx_desc.sv"
    `include "mailbox_completion.sv"
    `include "mailbox_refill_profile.sv"
    `include "mailbox_sequences.sv"
    `include "mailbox_env.sv"
endpackage

`endif
