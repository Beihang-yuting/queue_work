`ifndef TLPQ_TEST_PKG_SV
`define TLPQ_TEST_PKG_SV

package tlpq_test_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import pcie_tl_pkg::*;
    import gq_pkg::*;
    import tlpq_pkg::*;
    `include "uvm_macros.svh"
    `include "host_mem_manager.sv"

    class tlpq_pcie_smoke_test extends uvm_test;
        `uvm_component_utils(tlpq_pcie_smoke_test)

        function new(string name = "tlpq_pcie_smoke_test",
                     uvm_component parent = null);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            pcie_tl_codec codec;
            pcie_tl_mem_tlp request;
            pcie_tl_tlp decoded;
            bit [7:0] encoded[];
            codec = pcie_tl_codec::type_id::create("codec");
            request = pcie_tl_mem_tlp::type_id::create("request");
            request.kind = TLP_MEM_RD;
            request.fmt = FMT_3DW_NO_DATA;
            request.type_f = TLP_TYPE_MEM_RD;
            request.length = 1;
            request.requester_id = 16'h0100;
            request.tag = 10'h012;
            request.addr = 64'h0000_0000_1000_0000;
            request.first_be = 4'hf;
            request.last_be = 0;
            request.is_64bit = 0;
            codec.encode(request, encoded);
            decoded = codec.decode(encoded);
            if (encoded.size() != 12 || decoded == null)
                `uvm_error("TLPQ_PCIE", "codec smoke failed")
        endtask
    endclass

    `include "tests/tlpq_desc_test.sv"
    `include "tests/tlpq_bridge_test.sv"
    `include "mocks/tlpq_mock_adapter.sv"
    `include "tests/tlpq_driver_conformance_test.sv"
endpackage

`endif
