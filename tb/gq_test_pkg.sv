`ifndef GQ_TEST_PKG_SV
`define GQ_TEST_PKG_SV

package gq_test_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
    import mailbox_pkg::*;
    `include "uvm_macros.svh"

    `include "host_mem_manager.sv"
    `include "mocks/gq_test_ptr_codec.svh"
    `include "mocks/mailbox_mock_adapter.svh"
    `include "tests/gq_config_test.svh"
    `include "tests/mailbox_desc_test.svh"

    class gq_smoke_test extends uvm_test;
        `uvm_component_utils(gq_smoke_test)

        function new(string name = "gq_smoke_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction
    endclass
endpackage

`endif
