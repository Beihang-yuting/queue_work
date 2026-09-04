// src/mailbox/mailbox_tx_desc.sv: Mailbox 发送描述符打包、载荷所有权和稳定字段检查。
`ifndef MAILBOX_TX_DESC_SV
`define MAILBOX_TX_DESC_SV

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

    protected bit prepared;
    protected host_mem_api prepared_mem;
    protected gq_addr_t prepared_buf_addr;
    protected bit [15:0] prepared_buf_len;

    constraint valid_data_len_c {
        data_len <= 44;
    }

    // 描述符保存 44 字节内嵌载荷，也可以根据 buf_len 引用一块自有外部缓存。
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
        prepared         = 0;
        prepared_mem     = null;
        prepared_buf_addr = 0;
        prepared_buf_len  = 0;
    endfunction

    virtual function bit prepare();
        // 准备后的描述符冻结缓存地址/长度，供引擎持有分配期间检查稳定字段。
        if (prepared)
            return 0;

        if (data_len > 44)
            return 0;

        if (buf_len == 0) begin
            buf_addr = 0;
            external_data = new[0];
            prepared_mem      = mem;
            prepared_buf_addr = 0;
            prepared_buf_len  = 0;
            prepared           = 1;
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
        bit [511:0] raw;

        raw = '0;
        raw[15:0]    = flags;
        raw[31:16]   = srcid;
        raw[47:32]   = dstid;
        raw[63:48]   = msg_type;
        raw[127:64]  = prepared ? prepared_buf_addr : buf_addr;
        raw[143:128] = prepared ? prepared_buf_len : buf_len;
        raw[159:144] = data_len;
        for (int unsigned i = 0; i < 44; i++)
            raw[160 + i*8 +: 8] = data[i];

        packed_data = new[64];
        for (int unsigned i = 0; i < 64; i++)
            packed_data[i] = raw[i*8 +: 8];
    endfunction

    virtual function bit unpack(input byte packed_data[]);
        bit [511:0] raw;
        bit [15:0] decoded_flags;
        bit [15:0] decoded_srcid;
        bit [15:0] decoded_dstid;
        bit [15:0] decoded_msg_type;
        gq_addr_t  decoded_buf_addr;
        bit [15:0] decoded_buf_len;
        bit [15:0] decoded_data_len;
        byte decoded_data[44];

        // 接受硬件 flags 前比较所有稳定字段和内嵌字节，防止已发布 TX 请求被
        // 静默修改。
        if (packed_data.size() != 64)
            return 0;

        raw = '0;
        for (int unsigned i = 0; i < 64; i++)
            raw[i*8 +: 8] = packed_data[i];

        decoded_flags    = raw[15:0];
        decoded_srcid    = raw[31:16];
        decoded_dstid    = raw[47:32];
        decoded_msg_type = raw[63:48];
        decoded_buf_addr = raw[127:64];
        decoded_buf_len  = raw[143:128];
        decoded_data_len = raw[159:144];
        for (int unsigned i = 0; i < 44; i++)
            decoded_data[i] = raw[160 + i*8 +: 8];

        if (decoded_data_len > 44)
            return 0;

        if (prepared) begin
            if (decoded_buf_addr != prepared_buf_addr ||
                decoded_buf_len != prepared_buf_len ||
                decoded_srcid != srcid || decoded_dstid != dstid ||
                decoded_msg_type != msg_type || decoded_data_len != data_len)
                return 0;
            for (int unsigned i = 0; i < 44; i++) begin
                if (decoded_data[i] !== data[i])
                    return 0;
            end
            flags = decoded_flags;
            return 1;
        end

        flags    = decoded_flags;
        srcid    = decoded_srcid;
        dstid    = decoded_dstid;
        msg_type = decoded_msg_type;
        buf_addr = decoded_buf_addr;
        buf_len  = decoded_buf_len;
        data_len = decoded_data_len;
        for (int unsigned i = 0; i < 44; i++)
            data[i] = decoded_data[i];
        return 1;
    endfunction

    virtual function bit is_complete(bit phase);
        return flags[1] == 1'b1;
    endfunction
endclass

`endif
