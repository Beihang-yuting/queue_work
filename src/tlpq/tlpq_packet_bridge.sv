// src/tlpq/tlpq_packet_bridge.sv: 带校验和失败关闭解码的 PCIe canonical TLP 到 DPU DWORD 桥接器。
`ifndef TLPQ_PACKET_BRIDGE_SV
`define TLPQ_PACKET_BRIDGE_SV

class tlpq_packet_bridge extends uvm_object;
    `uvm_object_utils(tlpq_packet_bridge)

    protected pcie_tl_codec codec;

    // PCIe 编解码对象封装在桥接器后面，使 TLPQ 只负责 canonical 到 DPU 的布局
    // 转换以及失败关闭校验。
    function new(string name = "tlpq_packet_bridge");
        super.new(name);
        codec = pcie_tl_codec::type_id::create({name, "_codec"});
    endfunction

    protected function bit [31:0] canonical_word(
        input bit [7:0] bytes[], int unsigned byte_index);
        return {bytes[byte_index+0], bytes[byte_index+1],
                bytes[byte_index+2], bytes[byte_index+3]};
    endfunction

    protected function bit [31:0] dpu_word(
        input bit [7:0] bytes[], int unsigned byte_index);
        return {bytes[byte_index+3], bytes[byte_index+2],
                bytes[byte_index+1], bytes[byte_index+0]};
    endfunction

    protected function void store_canonical_word(
        ref bit [7:0] bytes[], input int unsigned byte_index,
        input bit [31:0] word);
        bytes[byte_index+0] = word[31:24];
        bytes[byte_index+1] = word[23:16];
        bytes[byte_index+2] = word[15:8];
        bytes[byte_index+3] = word[7:0];
    endfunction

    protected function bit classify_fmt(
        bit [2:0] fmt_bits, output bit is_4dw,
        output bit has_data, output int unsigned header_bytes,
        output string reason);
        reason = "";
        case (fmt_bits)
            3'b000: begin
                is_4dw = 1'b0;
                has_data = 1'b0;
                header_bytes = 12;
            end
            3'b010: begin
                is_4dw = 1'b0;
                has_data = 1'b1;
                header_bytes = 12;
            end
            3'b001: begin
                is_4dw = 1'b1;
                has_data = 1'b0;
                header_bytes = 16;
            end
            3'b011: begin
                is_4dw = 1'b1;
                has_data = 1'b1;
                header_bytes = 16;
            end
            default: begin
                is_4dw = 1'b0;
                has_data = 1'b0;
                header_bytes = 0;
                reason = $sformatf("unsupported canonical PCIe Fmt 0b%03b",
                                   fmt_bits);
                return 1'b0;
            end
        endcase
        return 1'b1;
    endfunction

    protected virtual function void codec_encode(
        input pcie_tl_tlp tlp, output bit [7:0] bytes[]);
        codec.encode(tlp, bytes);
    endfunction

    protected virtual function pcie_tl_tlp codec_decode(
        input bit [7:0] bytes[]);
        return codec.decode(bytes);
    endfunction

    function bit codec_bytes_to_dpu(
        input bit [7:0] codec_bytes[],
        output bit [31:0] dpu_dwords[], output string reason);
        bit [31:0] canonical_dw0;
        bit [2:0] fmt_bits;
        bit is_4dw;
        bit has_data;
        bit [9:0] encoded_length;
        int unsigned header_bytes;
        int unsigned payload_dwords;
        int unsigned expected_bytes;

        dpu_dwords = new[0];
        reason = "";

        if (codec_bytes.size() < 4) begin
            reason = $sformatf(
                "canonical PCIe byte array has %0d bytes; first DWORD required",
                codec_bytes.size());
            return 1'b0;
        end
        if ((codec_bytes.size() % 4) != 0) begin
            reason = $sformatf(
                "canonical PCIe byte count %0d is not DWORD aligned",
                codec_bytes.size());
            return 1'b0;
        end

        canonical_dw0 = canonical_word(codec_bytes, 0);
        fmt_bits = canonical_dw0[31:29];
        if (!classify_fmt(fmt_bits, is_4dw, has_data,
                          header_bytes, reason))
            return 1'b0;
        if (canonical_dw0[15]) begin
            reason = "ECRC/Digest (TD=1) is unsupported by the TLPQ DPU bridge";
            return 1'b0;
        end
        if (codec_bytes.size() < header_bytes) begin
            reason = $sformatf(
                "canonical %0dDW header requires %0d bytes; received %0d",
                is_4dw ? 4 : 3, header_bytes, codec_bytes.size());
            return 1'b0;
        end

        encoded_length = {codec_bytes[2][1:0], codec_bytes[3]};
        payload_dwords = has_data ?
            ((encoded_length == 0) ? 1024 : encoded_length) : 0;
        expected_bytes = header_bytes + payload_dwords * 4;
        if (codec_bytes.size() != expected_bytes) begin
            reason = $sformatf(
                {"canonical codec output has %0d bytes; Fmt/Length require ",
                 "exactly %0d"}, codec_bytes.size(), expected_bytes);
            return 1'b0;
        end

        dpu_dwords = new[4 + payload_dwords];
        dpu_dwords[0] = is_4dw ? canonical_word(codec_bytes, 12) : 32'h0;
        dpu_dwords[1] = canonical_word(codec_bytes, 8);
        dpu_dwords[2] = canonical_word(codec_bytes, 4);
        dpu_dwords[3] = canonical_word(codec_bytes, 0);
        for (int unsigned i = 0; i < payload_dwords; i++)
            dpu_dwords[4+i] = canonical_word(
                codec_bytes, header_bytes + i*4);
        return 1'b1;
    endfunction

    function bit dpu_bytes_to_codec(
        input bit [7:0] dpu_bytes[],
        output bit [7:0] codec_bytes[], output string reason);
        bit [31:0] canonical_dw0;
        bit [2:0] fmt_bits;
        bit is_4dw;
        bit has_data;
        bit [9:0] encoded_length;
        int unsigned header_bytes;
        int unsigned payload_dwords;
        int unsigned expected_dpu_bytes;

        codec_bytes = new[0];
        reason = "";

        if (dpu_bytes.size() < 16) begin
            reason = $sformatf(
                "DPU TLP layout has %0d bytes; four-DWORD header required",
                dpu_bytes.size());
            return 1'b0;
        end
        if ((dpu_bytes.size() % 4) != 0) begin
            reason = $sformatf("DPU byte count %0d is not DWORD aligned",
                               dpu_bytes.size());
            return 1'b0;
        end

        canonical_dw0 = dpu_word(dpu_bytes, 12);
        fmt_bits = canonical_dw0[31:29];
        if (!classify_fmt(fmt_bits, is_4dw, has_data,
                          header_bytes, reason))
            return 1'b0;
        if (canonical_dw0[15]) begin
            reason = "ECRC/Digest (TD=1) is unsupported by the TLPQ DPU bridge";
            return 1'b0;
        end

        encoded_length = canonical_dw0[9:0];
        payload_dwords = has_data ?
            ((encoded_length == 0) ? 1024 : encoded_length) : 0;
        expected_dpu_bytes = 16 + payload_dwords * 4;
        if (dpu_bytes.size() != expected_dpu_bytes) begin
            reason = $sformatf(
                {"DPU layout has %0d bytes; Fmt/Length require exactly %0d"},
                dpu_bytes.size(), expected_dpu_bytes);
            return 1'b0;
        end
        if (!is_4dw && dpu_word(dpu_bytes, 0) != 32'h0) begin
            reason = $sformatf(
                "3DW DPU padding must be zero; received 0x%08h",
                dpu_word(dpu_bytes, 0));
            return 1'b0;
        end

        codec_bytes = new[header_bytes + payload_dwords * 4];
        store_canonical_word(codec_bytes, 0, dpu_word(dpu_bytes, 12));
        store_canonical_word(codec_bytes, 4, dpu_word(dpu_bytes, 8));
        store_canonical_word(codec_bytes, 8, dpu_word(dpu_bytes, 4));
        if (is_4dw)
            store_canonical_word(codec_bytes, 12, dpu_word(dpu_bytes, 0));
        for (int unsigned i = 0; i < payload_dwords; i++)
            store_canonical_word(codec_bytes, header_bytes + i*4,
                                 dpu_word(dpu_bytes, 16 + i*4));
        return 1'b1;
    endfunction

    function bit encode_tlp(
        input pcie_tl_tlp tlp,
        output bit [31:0] dpu_dwords[], output string reason);
        bit [7:0] codec_bytes[];

        dpu_dwords = new[0];
        reason = "";
        if (tlp == null) begin
            reason = "cannot encode a null PCIe TLP";
            return 1'b0;
        end
        if (codec == null) begin
            reason = "PCIe codec factory returned null";
            return 1'b0;
        end

        codec_encode(tlp, codec_bytes);
        if (!codec_bytes_to_dpu(codec_bytes, dpu_dwords, reason)) begin
            reason = {"PCIe codec output is inconsistent: ", reason};
            return 1'b0;
        end
        return 1'b1;
    endfunction

    function bit decode_tlp(
        input bit [7:0] dpu_bytes[],
        output pcie_tl_tlp tlp, output string reason);
        bit [7:0] codec_bytes[];

        tlp = null;
        reason = "";
        if (!dpu_bytes_to_codec(dpu_bytes, codec_bytes, reason))
            return 1'b0;
        if (codec == null) begin
            reason = "PCIe codec factory returned null";
            return 1'b0;
        end

        tlp = codec_decode(codec_bytes);
        if (tlp == null) begin
            reason = "PCIe codec returned a null decoded TLP";
            return 1'b0;
        end
        return 1'b1;
    endfunction
endclass

`endif
