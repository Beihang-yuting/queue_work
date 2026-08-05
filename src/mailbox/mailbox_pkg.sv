`ifndef MAILBOX_PKG_SV
`define MAILBOX_PKG_SV

package mailbox_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    `include "uvm_macros.svh"

    `include "mailbox_tx_desc.svh"
    `include "mailbox_rx_desc.svh"
    `include "mailbox_completion.svh"
    `include "mailbox_refill_profile.svh"
    `include "mailbox_sequences.svh"
    `include "mailbox_env.svh"
endpackage

`endif
