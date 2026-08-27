`ifndef MSGQ_TEST_PKG_SV
`define MSGQ_TEST_PKG_SV

package msgq_test_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    import msgq_pkg::*;
    `include "uvm_macros.svh"

    `include "host_mem_manager.sv"
    `include "mocks/msgq_mock_adapter.sv"
    `include "tests/msgq_entry_test.sv"
    `include "tests/msgq_completion_test.sv"
    `include "tests/msgq_profile_test.sv"
endpackage

`endif
