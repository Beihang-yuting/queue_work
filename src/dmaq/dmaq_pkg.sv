// src/dmaq/dmaq_pkg.sv: DMAQ 包的导入和源码包含顺序。
`ifndef DMAQ_PKG_SV
`define DMAQ_PKG_SV

package dmaq_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    `include "uvm_macros.svh"

    `include "dmaq_types.sv"
    `include "dmaq_tx_desc.sv"
    `include "dmaq_sequences.sv"
    `include "dmaq_ptr_codec.sv"
    `include "dmaq_completion.sv"
    `include "dmaq_reg_adapter.sv"
    `include "dmaq_env.sv"
endpackage

`endif
