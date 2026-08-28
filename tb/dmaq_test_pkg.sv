`ifndef DMAQ_TEST_PKG_SV
`define DMAQ_TEST_PKG_SV

package dmaq_test_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    import dmaq_pkg::*;
    `include "uvm_macros.svh"

    `include "host_mem_manager.sv"
    `include "mocks/dmaq_mock_adapter.sv"
    `include "tests/dmaq_desc_test.sv"
    `include "tests/dmaq_sequence_test.sv"
endpackage

`endif
