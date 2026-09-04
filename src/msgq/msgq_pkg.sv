// src/msgq/msgq_pkg.sv: MSGQ 包的导入和源码包含顺序。
`ifndef MSGQ_PKG_SV
`define MSGQ_PKG_SV

package msgq_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    `include "uvm_macros.svh"

    `include "msgq_types.sv"
    `include "msgq_ptr_codec.sv"
    `include "msgq_reg_adapter.sv"
    `include "msgq_entry_base.sv"
    `include "msgq_raw_entry.sv"
    `include "msgq_mac_age_entry.sv"
    `include "msgq_1588_entry.sv"
    `include "msgq_completion.sv"
    `include "msgq_refill_profile.sv"
    `include "msgq_sequences.sv"
    `include "msgq_env.sv"
endpackage

`endif
