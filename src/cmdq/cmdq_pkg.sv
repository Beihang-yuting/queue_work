// src/cmdq/cmdq_pkg.sv: CMDQ 包的导入和源码包含顺序。
`ifndef CMDQ_PKG_SV
`define CMDQ_PKG_SV

package cmdq_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    `include "uvm_macros.svh"

    `include "cmdq_types.sv"
    `include "cmdq_ptr_codec.sv"
    `include "cmdq_reg_adapter.sv"
    `include "cmdq_tx_desc.sv"
    `include "cmdq_completion.sv"
    `include "cmdq_env.sv"
    `include "cmdq_sequences.sv"
endpackage

`endif
