`ifndef GQ_COMPLETION_SOURCE_SVH
`define GQ_COMPLETION_SOURCE_SVH

virtual class gq_completion_source extends uvm_object;
    function new(string name = "gq_completion_source");
        super.new(name);
    endfunction

    pure virtual function int unsigned completed_count(
        host_mem_api mem,
        gq_addr_t ring_base,
        gq_addr_t status_addr,
        int unsigned depth,
        int unsigned desc_size,
        gq_logical_seq_t logical_head,
        input gq_desc_base pending[$]);
endclass

`endif
