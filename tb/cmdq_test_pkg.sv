`ifndef CMDQ_TEST_PKG_SV
`define CMDQ_TEST_PKG_SV

package cmdq_test_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    import cmdq_pkg::*;
    `include "uvm_macros.svh"

    `include "host_mem_manager.sv"
    `include "mocks/cmdq_mock_adapter.sv"
    `include "tests/cmdq_desc_test.sv"
endpackage

`endif
