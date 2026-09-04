// src/cmdq/cmdq_tx_desc.sv: CMDQ 32 字节发送描述符的序列化、主机缓存所有权和完成解析。
`ifndef CMDQ_TX_DESC_SV
`define CMDQ_TX_DESC_SV

class cmdq_tx_desc extends gq_desc_base;
    `uvm_object_utils(cmdq_tx_desc)

    byte request[];
    byte result[];

    bit [15:0] flags;
    bit [15:0] tx_buf_len;
    gq_addr_t  tx_buf_addr;
    bit [15:0] dst_id;
    bit [15:0] rx_buf_len;
    gq_addr_t  rx_buf_addr;
    bit [63:0] reserved;

    uvm_event completion_event;

    protected bit prepare_attempted;
    protected bit prepared;
    protected host_mem_api prepared_mem;
    protected bit [15:0] prepared_tx_buf_len;
    protected gq_addr_t  prepared_tx_buf_addr;
    protected bit [15:0] prepared_dst_id;
    protected gq_addr_t  prepared_rx_buf_addr;
    protected bit [63:0] prepared_reserved;

    // prepare() 保存线缆稳定字段的快照，防止硬件写回破坏它们；发布后只允许
    // flags 和硬件报告的 RX 长度发生变化。
    function new(string name = "cmdq_tx_desc");
        super.new(name);
        request = new[0];
        result  = new[0];
        flags       = 0;
        tx_buf_len  = 0;
        tx_buf_addr = 0;
        dst_id      = 0;
        rx_buf_len  = 0;
        rx_buf_addr = 0;
        reserved    = 0;
        completion_event = new({name, "_completion_event"});
        prepare_attempted    = 0;
        prepared             = 0;
        prepared_mem         = null;
        prepared_tx_buf_len  = 0;
        prepared_tx_buf_addr = 0;
        prepared_dst_id      = 0;
        prepared_rx_buf_addr = 0;
        prepared_reserved    = 0;
    endfunction

    virtual function bit prepare();
        gq_addr_t allocated_tx;
        gq_addr_t allocated_rx;
        byte tx_storage[];
        byte rx_storage[];

        // 准备过程只能执行一次，因为描述符被提交路径接受后，缓存所有权即转
        // 移给引擎。
        if (prepare_attempted)
            return 0;
        prepare_attempted = 1;
        if (request.size() > CMDQ_BUFFER_BYTES)
            return 0;
        if (mem == null)
            return 0;

        allocated_tx = alloc_owned(CMDQ_BUFFER_BYTES);
        if (allocated_tx == '1)
            return 0;

        allocated_rx = alloc_owned(CMDQ_BUFFER_BYTES);
        if (allocated_rx == '1) begin
            release_owned();
            return 0;
        end

        tx_storage = new[CMDQ_BUFFER_BYTES];
        rx_storage = new[CMDQ_BUFFER_BYTES];
        foreach (tx_storage[i])
            tx_storage[i] = 0;
        foreach (rx_storage[i])
            rx_storage[i] = 0;
        foreach (request[i])
            tx_storage[i] = request[i];
        mem.write_mem(allocated_tx, tx_storage, `__FILE__, `__LINE__);
        mem.write_mem(allocated_rx, rx_storage, `__FILE__, `__LINE__);

        flags       = 0;
        tx_buf_len  = request.size();
        tx_buf_addr = allocated_tx;
        rx_buf_len  = CMDQ_BUFFER_BYTES;
        rx_buf_addr = allocated_rx;
        reserved    = 0;
        result      = new[0];

        prepared_mem         = mem;
        prepared_tx_buf_len  = tx_buf_len;
        prepared_tx_buf_addr = tx_buf_addr;
        prepared_dst_id      = dst_id;
        prepared_rx_buf_addr = rx_buf_addr;
        prepared_reserved    = reserved;
        prepared             = 1;
        return 1;
    endfunction

    virtual function void mark_available(bit phase);
        // CMDQ 将 phase 放在已发布尾指针中，而不是描述符 flags 中。
        flags = CMDQ_DESC_AVAIL;
    endfunction

    virtual function void pack(ref byte packed_data[]);
        bit [255:0] raw;

        // 优先使用 prepare() 保存的字段，避免 pack() 暴露调用者对已提交环项的
        // 后续修改。
        raw = '0;
        raw[15:0]    = flags;
        raw[31:16]   = prepared ? prepared_tx_buf_len : tx_buf_len;
        raw[95:32]   = prepared ? prepared_tx_buf_addr : tx_buf_addr;
        raw[111:96]  = prepared ? prepared_dst_id : dst_id;
        raw[127:112] = rx_buf_len;
        raw[191:128] = prepared ? prepared_rx_buf_addr : rx_buf_addr;
        raw[255:192] = prepared ? prepared_reserved : reserved;

        packed_data = new[CMDQ_DESC_BYTES];
        foreach (packed_data[i])
            packed_data[i] = raw[i*8 +: 8];
    endfunction

    virtual function bit unpack(input byte packed_data[]);
        bit [255:0] raw;
        bit [15:0] decoded_flags;
        bit [15:0] decoded_tx_buf_len;
        gq_addr_t  decoded_tx_buf_addr;
        bit [15:0] decoded_dst_id;
        bit [15:0] decoded_rx_buf_len;
        gq_addr_t  decoded_rx_buf_addr;
        bit [63:0] decoded_reserved;

        // 在接受硬件 flags 之前，先拒绝稳定字段被破坏的描述符。
        if (!prepared || packed_data.size() != CMDQ_DESC_BYTES)
            return 0;

        raw = '0;
        foreach (packed_data[i])
            raw[i*8 +: 8] = packed_data[i];

        decoded_flags       = raw[15:0];
        decoded_tx_buf_len  = raw[31:16];
        decoded_tx_buf_addr = raw[95:32];
        decoded_dst_id      = raw[111:96];
        decoded_rx_buf_len  = raw[127:112];
        decoded_rx_buf_addr = raw[191:128];
        decoded_reserved    = raw[255:192];

        if (decoded_tx_buf_len != prepared_tx_buf_len ||
            decoded_tx_buf_addr != prepared_tx_buf_addr ||
            decoded_dst_id != prepared_dst_id ||
            decoded_rx_buf_addr != prepared_rx_buf_addr ||
            decoded_reserved != prepared_reserved)
            return 0;

        flags      = decoded_flags;
        rx_buf_len = decoded_rx_buf_len;
        return 1;
    endfunction

    virtual function bit is_complete(bit phase);
        return (flags & CMDQ_DESC_USED) != 0;
    endfunction

    virtual function bit parse_completion();
        byte copied_result[];

        // 在回收阶段 release_owned() 将 RX 缓存归还分配器前，先复制其内容。
        if (!prepared || (flags & CMDQ_DESC_USED) == 0)
            return 0;
        if (rx_buf_len > CMDQ_BUFFER_BYTES)
            return 0;
        if (prepared_mem == null || prepared_rx_buf_addr == '1)
            return 0;

        if (rx_buf_len == 0) begin
            result = new[0];
        end else begin
            prepared_mem.read_mem(prepared_rx_buf_addr, rx_buf_len,
                                  copied_result, `__FILE__, `__LINE__);
            if (copied_result.size() != rx_buf_len)
                return 0;
            result = new[copied_result.size()];
            foreach (copied_result[i])
                result[i] = copied_result[i];
        end

        completion_event.trigger();
        return 1;
    endfunction
endclass

`endif
