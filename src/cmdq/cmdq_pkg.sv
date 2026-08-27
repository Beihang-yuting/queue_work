`ifndef CMDQ_PKG_SV
`define CMDQ_PKG_SV

package cmdq_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    `include "uvm_macros.svh"

    `include "cmdq_types.sv"
    `include "cmdq_tx_desc.sv"
endpackage

`endif
