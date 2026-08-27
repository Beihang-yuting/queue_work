`ifndef GQ_PKG_SV
`define GQ_PKG_SV

package gq_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    `include "uvm_macros.svh"

    `include "gq_types.sv"
    `include "gq_desc_base.sv"
    `include "gq_refill_profile.sv"
    `include "gq_request.sv"
    `include "gq_ptr_codec.sv"
    `include "gq_hw_adapter.sv"
    `include "gq_completion_source.sv"
    `include "gq_desc_writeback_completion.sv"
    `include "gq_tail_mem_completion.sv"
    `include "gq_queue_cfg.sv"
    `include "gq_wait_policy.sv"
    `include "gq_env_cfg.sv"
    `include "gq_queue_engine.sv"
    `include "gq_reset_controller.sv"
    `include "gq_agent.sv"
    `include "gq_env.sv"
endpackage

`endif
