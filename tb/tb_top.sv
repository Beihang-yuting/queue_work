// tb/tb_top.sv: 按编译期选择一个队列库测试包的 UVM 顶层测试平台。
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
`ifdef QUEUE_TEST_CMDQ
    import cmdq_test_pkg::*;
`endif
`ifdef QUEUE_TEST_TLPQ
    import tlpq_test_pkg::*;
`endif
`ifdef QUEUE_TEST_DMAQ
    import dmaq_test_pkg::*;
`endif

    initial run_test();
endmodule
