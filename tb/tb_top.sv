`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import gq_pkg::*;
`ifdef QUEUE_TEST_GQ
    import gq_test_pkg::*;
`endif
`ifdef QUEUE_TEST_MSGQ
    import msgq_test_pkg::*;
`endif

    initial run_test();
endmodule
