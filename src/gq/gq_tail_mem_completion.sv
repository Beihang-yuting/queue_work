`ifndef GQ_TAIL_MEM_COMPLETION_SV
`define GQ_TAIL_MEM_COMPLETION_SV

class gq_tail_mem_completion extends gq_completion_source;
    `uvm_object_utils(gq_tail_mem_completion)

    protected gq_ptr_codec ptr_codec;
    protected int unsigned status_byte_offset;
    protected gq_byte_order_e byte_order;

    function new(string name = "gq_tail_mem_completion",
                 gq_ptr_codec codec = null,
                 int unsigned byte_offset = 0,
                 gq_byte_order_e order = GQ_LITTLE_ENDIAN);
        super.new(name);
        ptr_codec         = codec;
        status_byte_offset = byte_offset;
        byte_order        = order;
    endfunction

    virtual function bit validate(int unsigned status_area_size,
                                  output string reason);
        longint unsigned required_bytes;

        if (ptr_codec == null) begin
            reason = "tail pointer codec must not be null";
            return 0;
        end
        required_bytes = status_byte_offset;
        required_bytes += 4;
        if (required_bytes > 32'hffff_ffff ||
            required_bytes > status_area_size) begin
            reason = $sformatf(
                "status area size %0d is shorter than tail read requirement %0d",
                status_area_size, required_bytes);
            return 0;
        end
        reason = "";
        return 1;
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
        byte raw_bytes[];
        gq_raw_ptr_t raw;
        gq_logical_seq_t completed_tail;
        gq_logical_seq_t delta;
        gq_addr_t read_addr;
        gq_addr_t max_addr;

        valid = 0;
        completed_count = 0;
        if (mem == null || ptr_codec == null)
            return;
        max_addr = '1;
        if (status_addr > (max_addr - status_byte_offset)) begin
            `uvm_error("GQ_COMPLETION_ADDR", $sformatf(
                "status base 0x%016h plus offset %0d overflows",
                status_addr, status_byte_offset))
            return;
        end
        read_addr = status_addr + status_byte_offset;
        if (read_addr > (max_addr - 3)) begin
            `uvm_error("GQ_COMPLETION_ADDR", $sformatf(
                "four-byte status read at 0x%016h overflows", read_addr))
            return;
        end
        mem.read_mem(read_addr, 4, raw_bytes,
                     `__FILE__, `__LINE__);
        if (raw_bytes.size() != 4)
            return;

        raw = '0;
        for (int unsigned i = 0; i < 4; i++) begin
            if (byte_order == GQ_LITTLE_ENDIAN)
                raw[i*8 +: 8] = raw_bytes[i];
            else
                raw[(3-i)*8 +: 8] = raw_bytes[i];
        end
        if (!ptr_codec.decode_completion(raw, logical_head, depth,
                                         completed_tail))
            return;
        if (completed_tail < logical_head)
            return;
        delta = completed_tail - logical_head;
        if (delta > 32'hffff_ffff)
            return;
        valid = 1;
        completed_count = int'(delta);
    endtask
endclass

`endif
