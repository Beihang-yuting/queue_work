`ifndef GQ_TEST_PKG_SV
`define GQ_TEST_PKG_SV

package gq_test_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    import mailbox_pkg::*;
    `include "uvm_macros.svh"

    `include "host_mem_manager.sv"
    `include "mocks/gq_test_ptr_codec.sv"
    `include "mocks/mailbox_mock_adapter.sv"
    `include "mocks/mailbox_mock_dut.sv"
    `include "tests/gq_config_test.sv"
    `include "tests/mailbox_desc_test.sv"
    `include "tests/mailbox_ptr_codec_test.sv"
    `include "tests/mailbox_reg_adapter_test.sv"
    `include "tests/mailbox_wrap_test.sv"
    `include "tests/gq_submit_test.sv"
    `include "tests/gq_completion_test.sv"
    `include "tests/gq_refill_test.sv"
    `include "tests/gq_reset_test.sv"
    `include "tests/gq_regression_test.sv"

    class gq_smoke_test extends uvm_test;
        `uvm_component_utils(gq_smoke_test)

        function new(string name = "gq_smoke_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction
    endclass
endpackage

`endif
