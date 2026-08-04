`ifndef GQ_PKG_SV
`define GQ_PKG_SV

package gq_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    `include "uvm_macros.svh"

    `include "gq_types.svh"
    `include "gq_ptr_codec.svh"
    `include "gq_hw_adapter.svh"
    `include "gq_completion_source.svh"
    `include "gq_queue_cfg.svh"
endpackage

`endif
