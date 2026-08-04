`ifndef MAILBOX_TX_DESC_SVH
`define MAILBOX_TX_DESC_SVH

class mailbox_tx_desc extends gq_desc_base;
    `uvm_object_utils(mailbox_tx_desc)

    bit [15:0] flags;
    bit [15:0] srcid;
    bit [15:0] dstid;
    bit [15:0] msg_type;
    gq_addr_t  buf_addr;
    bit [15:0] buf_len;
    rand bit [15:0] data_len;
    rand byte data[44];
    byte external_data[];

    constraint valid_data_len_c {
        data_len <= 44;
    }

    function new(string name = "mailbox_tx_desc");
        super.new(name);
        flags    = 0;
        srcid    = 0;
        dstid    = 0;
        msg_type = 0;
        buf_addr = 0;
        buf_len  = 0;
        data_len = 0;
        foreach (data[i])
            data[i] = 0;
        external_data = new[0];
    endfunction

    virtual function bit prepare();
        if (data_len > 44)
            return 0;

        if (buf_len == 0) begin
            buf_addr = 0;
            external_data = new[0];
            return 1;
        end

        if (mem == null)
            return 0;

        buf_addr = alloc_owned(buf_len);
        if (buf_addr == '1) begin
            external_data = new[0];
            return 0;
        end

        external_data = new[buf_len];
        foreach (external_data[i])
            external_data[i] = byte'($urandom());
        mem.write_mem(buf_addr, external_data, `__FILE__, `__LINE__);
        return 1;
    endfunction

    virtual function void mark_available(bit phase);
        flags[0] = phase;
        flags[1] = !phase;
    endfunction

    virtual function void pack(ref byte packed_data[]);
        bit [511:0] raw;

        raw = '0;
        raw[15:0]    = flags;
        raw[31:16]   = srcid;
        raw[47:32]   = dstid;
        raw[63:48]   = msg_type;
        raw[127:64]  = buf_addr;
        raw[143:128] = buf_len;
        raw[159:144] = data_len;
        for (int unsigned i = 0; i < 44; i++)
            raw[160 + i*8 +: 8] = data[i];

        packed_data = new[64];
        for (int unsigned i = 0; i < 64; i++)
            packed_data[i] = raw[i*8 +: 8];
    endfunction

    virtual function bit unpack(input byte packed_data[]);
        bit [511:0] raw;

        if (packed_data.size() != 64)
            return 0;

        raw = '0;
        for (int unsigned i = 0; i < 64; i++)
            raw[i*8 +: 8] = packed_data[i];

        flags    = raw[15:0];
        srcid    = raw[31:16];
        dstid    = raw[47:32];
        msg_type = raw[63:48];
        buf_addr = raw[127:64];
        buf_len  = raw[143:128];
        data_len = raw[159:144];
        for (int unsigned i = 0; i < 44; i++)
            data[i] = raw[160 + i*8 +: 8];

        return data_len <= 44;
    endfunction

    virtual function bit is_complete(bit phase);
        return flags[1] == phase;
    endfunction
endclass

`endif
