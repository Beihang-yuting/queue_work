`ifndef GQ_COMPLETION_SOURCE_SV
`define GQ_COMPLETION_SOURCE_SV

virtual class gq_completion_source extends uvm_object;
    function new(string name = "gq_completion_source");
        super.new(name);
    endfunction

    virtual function bit validate(int unsigned status_area_size,
                                  output string reason);
        reason = "";
        return 1;
    endfunction

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
