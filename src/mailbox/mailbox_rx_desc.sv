// src/mailbox/mailbox_rx_desc.sv: Mailbox 接收描述符打包、接收缓存所有权和写回校验。
`ifndef MAILBOX_RX_DESC_SV
`define MAILBOX_RX_DESC_SV

class mailbox_rx_desc extends gq_desc_base;
    `uvm_object_utils(mailbox_rx_desc)

    bit [15:0] flags;
    bit [31:0] buf_len;
    gq_addr_t  buf_addr;
    byte rx_data[];

    protected bit prepared;
    protected host_mem_api prepared_mem;
    protected gq_addr_t prepared_buf_addr;
    protected bit [31:0] prepared_buf_len;

    // 零长度 RX 描述符是合法的无缓存哨兵；其他描述符一直持有分配的缓存，直到
    // 引擎退休或复位。
    function new(string name = "mailbox_rx_desc");
        super.new(name);
        flags    = 0;
        buf_len  = 0;
        buf_addr = 0;
        rx_data  = new[0];
        prepared          = 0;
        prepared_mem      = null;
        prepared_buf_addr = 0;
        prepared_buf_len  = 0;
    endfunction

    virtual function bit prepare();
        // prepare() 记录后续解析/释放所需的分配器；拒绝重复准备以避免重复所有权。
        if (prepared)
            return 0;

        rx_data = new[0];
        if (buf_len == 0) begin
            buf_addr = 0;
            prepared_mem      = mem;
            prepared_buf_addr = 0;
            prepared_buf_len  = 0;
            prepared           = 1;
            return 1;
        end

        if (mem == null)
            return 0;

        buf_addr = alloc_owned(buf_len);
        if (buf_addr == '1)
            return 0;

        prepared_mem      = mem;
        prepared_buf_addr = buf_addr;
        prepared_buf_len  = buf_len;
        prepared           = 1;
        return 1;
    endfunction

    virtual function void mark_available(bit phase);
        flags = 16'h0001;
    endfunction

    virtual function void pack(ref byte packed_data[]);
        bit [127:0] raw;

        raw = '0;
        raw[15:0]   = flags;
        raw[31:16]  = 16'h0000;
        raw[63:32]  = prepared ? prepared_buf_len : buf_len;
        raw[127:64] = prepared ? prepared_buf_addr : buf_addr;

        packed_data = new[16];
        for (int unsigned i = 0; i < 16; i++)
            packed_data[i] = raw[i*8 +: 8];
    endfunction

    virtual function bit unpack(input byte packed_data[]);
        bit [127:0] raw;
        bit [15:0] decoded_flags;
        bit [15:0] decoded_reserved;
        bit [31:0] decoded_buf_len;
        gq_addr_t decoded_buf_addr;

        // 准备后地址和容量不可变；未准备对象可用于检查外部提供的条目。
        if (packed_data.size() != 16)
            return 0;

        raw = '0;
        for (int unsigned i = 0; i < 16; i++)
            raw[i*8 +: 8] = packed_data[i];

        decoded_flags    = raw[15:0];
        decoded_reserved = raw[31:16];
        decoded_buf_len  = raw[63:32];
        decoded_buf_addr = raw[127:64];

        if (prepared) begin
            if (decoded_reserved != 0 || decoded_buf_len != prepared_buf_len ||
                decoded_buf_addr != prepared_buf_addr)
                return 0;
            flags = decoded_flags;
            return 1;
        end

        flags    = decoded_flags;
        buf_len  = decoded_buf_len;
        buf_addr = decoded_buf_addr;
        return 1;
    endfunction

    virtual function bit is_complete(bit phase);
        return flags[1] == 1'b1;
    endfunction

    virtual function bit parse_completion();
        rx_data = new[0];
        if (!prepared)
            return 0;
        if (prepared_buf_len == 0)
            return 1;
        if (prepared_mem == null || prepared_buf_addr == '1)
            return 0;

        prepared_mem.read_mem(prepared_buf_addr, prepared_buf_len, rx_data,
                              `__FILE__, `__LINE__);
        return rx_data.size() == prepared_buf_len;
    endfunction
endclass

`endif
