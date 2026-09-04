// src/gq/gq_ptr_codec.sv: 发布尾指针并解码完成进度的抽象指针编码器契约。
`ifndef GQ_PTR_CODEC_SV
`define GQ_PTR_CODEC_SV

virtual class gq_ptr_codec extends uvm_object;
    function new(string name = "gq_ptr_codec");
        super.new(name);
    endfunction

    // 队列安装前由具体实现校验硬件指针宽度，防止无效几何参数发布出有歧义的
    // 尾指针。
    virtual function bit validate(int unsigned depth, output string reason);
        reason = "";
        return 1;
    endfunction

    // 在提交成功后编码逻辑尾指针；old_tail 为依赖前后状态变化的编码器保留。
    pure virtual function gq_raw_ptr_t encode_publish(
        gq_logical_seq_t old_tail,
        gq_logical_seq_t new_tail,
        int unsigned depth);

    // 相对于 logical_head 解码硬件进度；返回 0 会阻止引擎在状态值无效时退休
    // 描述符。
    virtual function bit decode_completion(
        gq_raw_ptr_t raw,
        gq_logical_seq_t logical_head,
        int unsigned depth,
        output gq_logical_seq_t completed_tail);
        completed_tail = logical_head;
        return 0;
    endfunction
endclass

`endif
