// tb/mocks/gq_async_completion_source.sv: 用于覆盖引擎查询竞争的可控异步完成源。
`ifndef GQ_ASYNC_COMPLETION_SOURCE_SV
`define GQ_ASYNC_COMPLETION_SOURCE_SV

class gq_async_completion_source extends gq_completion_source;
    `uvm_object_utils(gq_async_completion_source)

    uvm_event query_entered = new("query_entered");
    uvm_event release_query = new("release_query");
    bit next_valid = 1;
    int unsigned next_count = 0;

    function new(string name = "gq_async_completion_source");
        super.new(name);
    endfunction

    virtual task query_completed(
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
        query_entered.trigger();
        release_query.wait_on();
        valid = next_valid;
        completed_count = next_count;
    endtask
endclass

`endif
