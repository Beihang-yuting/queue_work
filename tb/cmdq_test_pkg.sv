// tb/cmdq_test_pkg.sv: 包含 CMDQ 描述符、序列和一致性回归测试的测试包。
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
    `include "mocks/cmdq_mock_dut.sv"
    `include "tests/cmdq_desc_test.sv"
    `include "tests/cmdq_sequence_test.sv"
    `include "tests/cmdq_driver_conformance_test.sv"
endpackage

`endif
