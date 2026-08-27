`ifndef TLPQ_RX_DESC_SV
`define TLPQ_RX_DESC_SV

class tlpq_rx_desc extends gq_desc_base;
    `uvm_object_utils(tlpq_rx_desc)

    bit [15:0] flags;
    bit [15:0] buf_len;
    gq_addr_t  buf_addr;
    tlpq_route_metadata_t metadata;

    bit [7:0] dpu_bytes[];
    pcie_tl_tlp decoded_tlp;

    protected bit prepare_attempted;
    protected bit prepared;
    protected host_mem_api prepared_mem;
    protected gq_addr_t prepared_buf_addr;

    function new(string name = "tlpq_rx_desc");
        super.new(name);
        flags       = 0;
        buf_len     = 0;
        buf_addr    = 0;
        metadata    = '0;
        dpu_bytes   = new[0];
        decoded_tlp = null;
        prepare_attempted = 0;
        prepared          = 0;
        prepared_mem      = null;
        prepared_buf_addr = 0;
    endfunction

    virtual function bit prepare();
        gq_addr_t allocated;
        byte cleared_buffer[];

        if (prepare_attempted)
            return 0;
        prepare_attempted = 1;
        if (mem == null)
            return 0;

        allocated = alloc_owned(TLPQ_BUFFER_BYTES);
        if (allocated == '1)
            return 0;

        cleared_buffer = new[TLPQ_BUFFER_BYTES];
        foreach (cleared_buffer[i])
            cleared_buffer[i] = 0;
        mem.write_mem(allocated, cleared_buffer, `__FILE__, `__LINE__);

        flags       = 0;
        buf_len     = TLPQ_BUFFER_BYTES;
        buf_addr    = allocated;
        metadata    = '0;
        dpu_bytes   = new[0];
        decoded_tlp = null;

        prepared_mem      = mem;
        prepared_buf_addr = allocated;
        prepared          = 1;
        return 1;
    endfunction

    virtual function void mark_available(bit phase);
        flags = TLPQ_DESC_AVAIL;
    endfunction

    virtual function void pack(ref byte packed_data[]);
        bit [127:0] raw;

        raw = '0;
        raw[15:0]    = flags;
        raw[31:16]   = buf_len;
        raw[95:32]   = prepared ? prepared_buf_addr : buf_addr;
        raw[99:96]   = metadata.host_id;
        raw[103:100] = metadata.tlp_type;
        raw[111:104] = metadata.primary_bus;
        raw[119:112] = metadata.secondary_bus;
        raw[127:120] = metadata.subordinate_bus;

        packed_data = new[TLPQ_DESC_BYTES];
        foreach (packed_data[i])
            packed_data[i] = raw[i*8 +: 8];
    endfunction

    virtual function bit unpack(input byte packed_data[]);
        bit [127:0] raw;
        bit [15:0] decoded_flags;
        bit [15:0] decoded_buf_len;
        gq_addr_t decoded_buf_addr;
        tlpq_route_metadata_t decoded_metadata;

        if (!prepared || packed_data.size() != TLPQ_DESC_BYTES)
            return 0;

        raw = '0;
        foreach (packed_data[i])
            raw[i*8 +: 8] = packed_data[i];

        decoded_flags                    = raw[15:0];
        decoded_buf_len                  = raw[31:16];
        decoded_buf_addr                 = raw[95:32];
        decoded_metadata.host_id         = raw[99:96];
        decoded_metadata.tlp_type        = raw[103:100];
        decoded_metadata.primary_bus     = raw[111:104];
        decoded_metadata.secondary_bus   = raw[119:112];
        decoded_metadata.subordinate_bus = raw[127:120];

        if (decoded_buf_addr != prepared_buf_addr)
            return 0;

        flags    = decoded_flags;
        buf_len  = decoded_buf_len;
        buf_addr = prepared_buf_addr;
        metadata = decoded_metadata;
        return 1;
    endfunction

    virtual function bit is_complete(bit phase);
        return (flags & TLPQ_DESC_USED) != 0;
    endfunction

    virtual function bit parse_completion();
        return 0;
    endfunction
endclass

`endif
