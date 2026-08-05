`ifndef GQ_PKG_SV
`define GQ_PKG_SV

package gq_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    `include "uvm_macros.svh"

    `include "gq_types.svh"
    `include "gq_desc_base.svh"
    `include "gq_refill_profile.svh"
    `include "gq_request.svh"
    `include "gq_ptr_codec.svh"
    `include "gq_hw_adapter.svh"
    `include "gq_completion_source.svh"
    `include "gq_tail_mem_completion.svh"
    `include "gq_queue_cfg.svh"
    `include "gq_wait_policy.svh"
    `include "gq_env_cfg.svh"
    `include "gq_queue_engine.svh"
    `include "gq_reset_controller.svh"
    `include "gq_agent.svh"
    `include "gq_env.svh"
endpackage

`endif
