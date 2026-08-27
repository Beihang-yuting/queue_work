`ifndef MSGQ_PKG_SV
`define MSGQ_PKG_SV

package msgq_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    `include "uvm_macros.svh"

    `include "msgq_types.sv"
    `include "msgq_entry_base.sv"
    `include "msgq_raw_entry.sv"
endpackage

`endif
