// src/gq/gq_completion_source.sv: 供写回、尾指针内存和业务专用完成源共享的抽象查询契约。
`ifndef GQ_COMPLETION_SOURCE_SV
`define GQ_COMPLETION_SOURCE_SV

virtual class gq_completion_source extends uvm_object;
    function new(string name = "gq_completion_source");
        super.new(name);
    endfunction

    virtual function bit validate(int unsigned status_area_size,
                                  output string reason);
        // 需要状态内存的完成源覆盖此钩子；描述符写回完成源没有独立状态区。
        reason = "";
        return 1;
    endfunction

    // 查询操作只观察状态：可以解码待完成描述符，但不能自行推进引擎所有权
    // 或逻辑指针。
    pure virtual task query_completed(
        host_mem_api mem,
        gq_hw_adapter adapter,
        gq_addr_t ring_base,
        gq_addr_t status_addr,
        int unsigned depth,
        int unsigned desc_size,
        gq_logical_seq_t logical_head,
        input gq_desc_base pending[$],
        output bit valid,
        output int unsigned completed_count);
endclass

`endif
