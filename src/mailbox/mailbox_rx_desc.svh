`ifndef MAILBOX_RX_DESC_SVH
`define MAILBOX_RX_DESC_SVH

class mailbox_rx_desc extends gq_desc_base;
    `uvm_object_utils(mailbox_rx_desc)

    bit [15:0] flags;
    bit [31:0] buf_len;
    gq_addr_t  buf_addr;
    byte rx_data[];

    function new(string name = "mailbox_rx_desc");
        super.new(name);
        flags    = 0;
        buf_len  = 0;
        buf_addr = 0;
        rx_data  = new[0];
    endfunction

    virtual function bit prepare();
        rx_data = new[0];
        if (buf_len == 0) begin
            buf_addr = 0;
            return 1;
        end

        if (mem == null)
            return 0;

        buf_addr = alloc_owned(buf_len);
        return buf_addr != '1;
    endfunction

    virtual function void mark_available(bit phase);
        flags[0] = phase;
        flags[1] = !phase;
    endfunction

    virtual function void pack(ref byte packed_data[]);
        bit [127:0] raw;

        raw = '0;
        raw[15:0]   = flags;
        raw[31:16]  = 16'h0000;
        raw[63:32]  = buf_len;
        raw[127:64] = buf_addr;

        packed_data = new[16];
        for (int unsigned i = 0; i < 16; i++)
            packed_data[i] = raw[i*8 +: 8];
    endfunction

    virtual function bit unpack(input byte packed_data[]);
        bit [127:0] raw;

        if (packed_data.size() != 16)
            return 0;

        raw = '0;
        for (int unsigned i = 0; i < 16; i++)
            raw[i*8 +: 8] = packed_data[i];

        flags    = raw[15:0];
        buf_len  = raw[63:32];
        buf_addr = raw[127:64];
        return 1;
    endfunction

    virtual function bit is_complete(bit phase);
        return flags[1] == phase;
    endfunction

    virtual function bit parse_completion();
        rx_data = new[0];
        if (buf_len == 0)
            return 1;
        if (mem == null || buf_addr == '1)
            return 0;

        mem.read_mem(buf_addr, buf_len, rx_data, `__FILE__, `__LINE__);
        return rx_data.size() == buf_len;
    endfunction
endclass

`endif
