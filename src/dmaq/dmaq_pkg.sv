`ifndef DMAQ_PKG_SV
`define DMAQ_PKG_SV

package dmaq_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    `include "uvm_macros.svh"

    `include "dmaq_types.sv"
    `include "dmaq_tx_desc.sv"
endpackage

`endif
