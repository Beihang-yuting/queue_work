`ifndef TLPQ_BRIDGE_TEST_SV
`define TLPQ_BRIDGE_TEST_SV

class tlpq_fault_injection_bridge extends tlpq_packet_bridge;
    `uvm_object_utils(tlpq_fault_injection_bridge)

    bit inject_bad_encode;
    bit inject_null_decode;

    function new(string name = "tlpq_fault_injection_bridge");
        super.new(name);
    endfunction

    protected virtual function void codec_encode(
        input pcie_tl_tlp tlp, output bit [7:0] bytes[]);
        if (inject_bad_encode) begin
            // A canonical 3DW no-data header plus an impossible extra DWORD.
            bytes = new[16];
            bytes[0] = 8'h04;
            bytes[1] = 8'h00;
            bytes[2] = 8'h00;
            bytes[3] = 8'h01;
            bytes[4] = 8'h12;
            bytes[5] = 8'h34;
            bytes[6] = 8'h56;
            bytes[7] = 8'h0f;
            bytes[8] = 8'hab;
            bytes[9] = 8'hcd;
            bytes[10] = 8'h00;
            bytes[11] = 8'h48;
            bytes[12] = 8'hde;
            bytes[13] = 8'had;
            bytes[14] = 8'hbe;
            bytes[15] = 8'hef;
        end else begin
            super.codec_encode(tlp, bytes);
        end
    endfunction

    protected virtual function pcie_tl_tlp codec_decode(
        input bit [7:0] bytes[]);
        if (inject_null_decode)
            return null;
        return super.codec_decode(bytes);
    endfunction
endclass

class tlpq_bridge_test extends uvm_test;
    `uvm_component_utils(tlpq_bridge_test)

    tlpq_packet_bridge bridge;

    function new(string name = "tlpq_bridge_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void expect_success(string vector_name, bit ok, string reason);
        if (!ok)
            `uvm_fatal("TLPQ_BRIDGE", $sformatf(
                "%s: bridge rejected valid packet: %s", vector_name, reason))
        if (reason != "")
            `uvm_fatal("TLPQ_BRIDGE", $sformatf(
                "%s: successful conversion retained reason '%s'",
                vector_name, reason))
    endfunction

    function void expect_words(string vector_name,
                               input bit [31:0] actual[],
                               input bit [31:0] expected[]);
        if (actual.size() != expected.size())
            `uvm_fatal("TLPQ_VECTOR", $sformatf(
                "%s: got %0d DWORDs expected %0d", vector_name,
                actual.size(), expected.size()))
        foreach (expected[i]) begin
            if (actual[i] !== expected[i])
                `uvm_fatal("TLPQ_VECTOR", $sformatf(
                    "%s: DWORD[%0d] got 0x%08h expected 0x%08h",
                    vector_name, i, actual[i], expected[i]))
        end
    endfunction

    function void expect_bytes(string check_name,
                               input bit [7:0] actual[],
                               input bit [7:0] expected[]);
        if (actual.size() != expected.size())
            `uvm_fatal("TLPQ_BYTES", $sformatf(
                "%s: got %0d bytes expected %0d", check_name,
                actual.size(), expected.size()))
        foreach (expected[i]) begin
            if (actual[i] !== expected[i])
                `uvm_fatal("TLPQ_BYTES", $sformatf(
                    "%s: byte[%0d] got 0x%02h expected 0x%02h",
                    check_name, i, actual[i], expected[i]))
        end
    endfunction

    function void words_to_dpu_bytes(input bit [31:0] words[],
                                     output bit [7:0] bytes[]);
        bytes = new[words.size() * 4];
        foreach (words[i]) begin
            bytes[i*4+0] = words[i][7:0];
            bytes[i*4+1] = words[i][15:8];
            bytes[i*4+2] = words[i][23:16];
            bytes[i*4+3] = words[i][31:24];
        end
    endfunction

    function void expect_common(string vector_name, pcie_tl_tlp actual,
                                tlp_kind_e expected_kind,
                                tlp_fmt_e expected_fmt,
                                tlp_type_e expected_type,
                                bit [9:0] expected_length,
                                bit [15:0] expected_requester,
                                bit [7:0] expected_tag,
                                int expected_payload_size);
        if (actual == null)
            `uvm_fatal("TLPQ_DECODE", {vector_name, ": decoded null TLP"})
        if (actual.kind != expected_kind || actual.fmt != expected_fmt ||
            actual.type_f != expected_type ||
            actual.length != expected_length ||
            actual.requester_id != expected_requester ||
            actual.tag[7:0] != expected_tag ||
            actual.payload.size() != expected_payload_size)
            `uvm_fatal("TLPQ_DECODE", $sformatf(
                {"%s: common decode mismatch kind=%s fmt=%s type=0x%02h ",
                 "len=%0d requester=0x%04h tag=0x%02h payload=%0d"},
                vector_name, actual.kind.name(), actual.fmt.name(),
                actual.type_f, actual.length, actual.requester_id,
                actual.tag[7:0], actual.payload.size()))
    endfunction

    function pcie_tl_tlp run_literal_vector(
        string vector_name, pcie_tl_tlp request,
        input bit [31:0] expected_dpu[]);
        pcie_tl_codec codec;
        pcie_tl_tlp decoded;
        bit [7:0] canonical[];
        bit [7:0] rebuilt_canonical[];
        bit [7:0] dpu_bytes[];
        bit [31:0] actual_dpu[];
        string reason;

        codec = pcie_tl_codec::type_id::create({vector_name, "_codec"});
        // Exactly one explicit pinned-codec encode supplies canonical bytes.
        codec.encode(request, canonical);

        expect_success(vector_name,
            bridge.codec_bytes_to_dpu(canonical, actual_dpu, reason), reason);
        expect_words(vector_name, actual_dpu, expected_dpu);

        words_to_dpu_bytes(expected_dpu, dpu_bytes);
        expect_success({vector_name, " dpu_bytes_to_codec"},
            bridge.dpu_bytes_to_codec(dpu_bytes, rebuilt_canonical, reason),
            reason);
        expect_bytes({vector_name, " canonical bytes"},
                     rebuilt_canonical, canonical);

        expect_success({vector_name, " decode_tlp"},
            bridge.decode_tlp(dpu_bytes, decoded, reason), reason);
        return decoded;
    endfunction

    // Mutation caught: omitting the zero pad or failing to reverse a 3DW header.
    function void check_cfg_read_type0();
        pcie_tl_cfg_tlp request;
        pcie_tl_cfg_tlp decoded;
        pcie_tl_tlp decoded_base;
        bit [31:0] expected[];

        request = pcie_tl_cfg_tlp::type_id::create("cfg_read_type0");
        request.kind = TLP_CFG_RD0;
        request.fmt = FMT_3DW_NO_DATA;
        request.type_f = TLP_TYPE_CFG_RD0;
        request.length = 10'd1;
        request.requester_id = 16'h1234;
        request.tag = 10'h056;
        request.completer_id = 16'habcd;
        request.reg_num = 10'h012;
        request.first_be = 4'hf;

        // Independently hand-derived DPU DWORDs: pad, DW2, DW1, DW0.
        expected = new[4];
        expected[0] = 32'h0000_0000;
        expected[1] = 32'habcd_0048;
        expected[2] = 32'h1234_560f;
        expected[3] = 32'h0400_0001;

        decoded_base = run_literal_vector("cfg_read_type0", request, expected);
        if (!$cast(decoded, decoded_base))
            `uvm_fatal("TLPQ_CLASS", "cfg_read_type0 did not decode as pcie_tl_cfg_tlp")
        expect_common("cfg_read_type0", decoded, TLP_CFG_RD0,
                      FMT_3DW_NO_DATA, TLP_TYPE_CFG_RD0, 10'd1,
                      16'h1234, 8'h56, 0);
        if (decoded.completer_id != 16'habcd ||
            decoded.reg_num != 10'h012 || decoded.first_be != 4'hf)
            `uvm_fatal("TLPQ_FIELDS", "cfg_read_type0 fields changed")
    endfunction

    // Mutation caught: placing a 3DW payload before the padded four-DWORD header.
    function void check_cfg_write_type0();
        pcie_tl_cfg_tlp request;
        pcie_tl_cfg_tlp decoded;
        pcie_tl_tlp decoded_base;
        bit [31:0] expected[];

        request = pcie_tl_cfg_tlp::type_id::create("cfg_write_type0");
        request.kind = TLP_CFG_WR0;
        request.fmt = FMT_3DW_WITH_DATA;
        request.type_f = TLP_TYPE_CFG_WR0;
        request.length = 10'd1;
        request.requester_id = 16'h2345;
        request.tag = 10'h067;
        request.completer_id = 16'hbcde;
        request.reg_num = 10'h1ab;
        request.first_be = 4'ha;
        request.payload = new[4];
        request.payload[0] = 8'h11;
        request.payload[1] = 8'h22;
        request.payload[2] = 8'h33;
        request.payload[3] = 8'h44;

        expected = new[5];
        expected[0] = 32'h0000_0000;
        expected[1] = 32'hbcde_06ac;
        expected[2] = 32'h2345_670a;
        expected[3] = 32'h4400_0001;
        expected[4] = 32'h1122_3344;

        decoded_base = run_literal_vector("cfg_write_type0", request, expected);
        if (!$cast(decoded, decoded_base))
            `uvm_fatal("TLPQ_CLASS", "cfg_write_type0 did not decode as pcie_tl_cfg_tlp")
        expect_common("cfg_write_type0", decoded, TLP_CFG_WR0,
                      FMT_3DW_WITH_DATA, TLP_TYPE_CFG_WR0, 10'd1,
                      16'h2345, 8'h67, 4);
        if (decoded.completer_id != 16'hbcde ||
            decoded.reg_num != 10'h1ab || decoded.first_be != 4'ha ||
            decoded.payload[0] != 8'h11 || decoded.payload[1] != 8'h22 ||
            decoded.payload[2] != 8'h33 || decoded.payload[3] != 8'h44)
            `uvm_fatal("TLPQ_FIELDS", "cfg_write_type0 fields/payload changed")
    endfunction

    // Mutation caught: collapsing Configuration Type 1 header words into Type 0.
    function void check_cfg_read_type1();
        pcie_tl_cfg_tlp request;
        pcie_tl_cfg_tlp decoded;
        pcie_tl_tlp decoded_base;
        bit [31:0] expected[];

        request = pcie_tl_cfg_tlp::type_id::create("cfg_read_type1");
        request.kind = TLP_CFG_RD1;
        request.fmt = FMT_3DW_NO_DATA;
        request.type_f = TLP_TYPE_CFG_RD1;
        request.length = 10'd1;
        request.requester_id = 16'h3456;
        request.tag = 10'h078;
        request.completer_id = 16'hcdef;
        request.reg_num = 10'h02a;
        request.first_be = 4'h3;

        expected = new[4];
        expected[0] = 32'h0000_0000;
        expected[1] = 32'hcdef_00a8;
        expected[2] = 32'h3456_7803;
        expected[3] = 32'h0500_0001;

        decoded_base = run_literal_vector("cfg_read_type1", request, expected);
        if (!$cast(decoded, decoded_base))
            `uvm_fatal("TLPQ_CLASS", "cfg_read_type1 did not decode as pcie_tl_cfg_tlp")
        expect_common("cfg_read_type1", decoded, TLP_CFG_RD1,
                      FMT_3DW_NO_DATA, TLP_TYPE_CFG_RD1, 10'd1,
                      16'h3456, 8'h78, 0);
        if (decoded.completer_id != 16'hcdef ||
            decoded.reg_num != 10'h02a || decoded.first_be != 4'h3)
            `uvm_fatal("TLPQ_FIELDS", "cfg_read_type1 fields changed")
    endfunction

    // Mutation caught: byte-swapping the Type 1 payload or its final header word.
    function void check_cfg_write_type1();
        pcie_tl_cfg_tlp request;
        pcie_tl_cfg_tlp decoded;
        pcie_tl_tlp decoded_base;
        bit [31:0] expected[];

        request = pcie_tl_cfg_tlp::type_id::create("cfg_write_type1");
        request.kind = TLP_CFG_WR1;
        request.fmt = FMT_3DW_WITH_DATA;
        request.type_f = TLP_TYPE_CFG_WR1;
        request.length = 10'd1;
        request.requester_id = 16'h4567;
        request.tag = 10'h089;
        request.completer_id = 16'hd0e1;
        request.reg_num = 10'h155;
        request.first_be = 4'h5;
        request.payload = new[4];
        request.payload[0] = 8'ha1;
        request.payload[1] = 8'hb2;
        request.payload[2] = 8'hc3;
        request.payload[3] = 8'hd4;

        expected = new[5];
        expected[0] = 32'h0000_0000;
        expected[1] = 32'hd0e1_0554;
        expected[2] = 32'h4567_8905;
        expected[3] = 32'h4500_0001;
        expected[4] = 32'ha1b2_c3d4;

        decoded_base = run_literal_vector("cfg_write_type1", request, expected);
        if (!$cast(decoded, decoded_base))
            `uvm_fatal("TLPQ_CLASS", "cfg_write_type1 did not decode as pcie_tl_cfg_tlp")
        expect_common("cfg_write_type1", decoded, TLP_CFG_WR1,
                      FMT_3DW_WITH_DATA, TLP_TYPE_CFG_WR1, 10'd1,
                      16'h4567, 8'h89, 4);
        if (decoded.completer_id != 16'hd0e1 ||
            decoded.reg_num != 10'h155 || decoded.first_be != 4'h5 ||
            decoded.payload[0] != 8'ha1 || decoded.payload[1] != 8'hb2 ||
            decoded.payload[2] != 8'hc3 || decoded.payload[3] != 8'hd4)
            `uvm_fatal("TLPQ_FIELDS", "cfg_write_type1 fields/payload changed")
    endfunction

    // Mutation caught: padding a 4DW header or failing to place canonical DW3 first.
    function void check_memory_read();
        pcie_tl_mem_tlp request;
        pcie_tl_mem_tlp decoded;
        pcie_tl_tlp decoded_base;
        bit [31:0] expected[];

        request = pcie_tl_mem_tlp::type_id::create("memory_read");
        request.kind = TLP_MEM_RD;
        request.fmt = FMT_4DW_NO_DATA;
        request.type_f = TLP_TYPE_MEM_RD;
        request.length = 10'd2;
        request.requester_id = 16'h5678;
        request.tag = 10'h09a;
        request.addr = 64'h1122_3344_5566_7780;
        request.first_be = 4'h3;
        request.last_be = 4'hc;
        request.is_64bit = 1'b1;

        // Independently hand-derived DPU DWORDs: DW3, DW2, DW1, DW0.
        expected = new[4];
        expected[0] = 32'h5566_7780;
        expected[1] = 32'h1122_3344;
        expected[2] = 32'h5678_9ac3;
        expected[3] = 32'h2000_0002;

        decoded_base = run_literal_vector("memory_read", request, expected);
        if (!$cast(decoded, decoded_base))
            `uvm_fatal("TLPQ_CLASS", "memory_read did not decode as pcie_tl_mem_tlp")
        expect_common("memory_read", decoded, TLP_MEM_RD,
                      FMT_4DW_NO_DATA, TLP_TYPE_MEM_RD, 10'd2,
                      16'h5678, 8'h9a, 0);
        if (decoded.addr != 64'h1122_3344_5566_7780 || !decoded.is_64bit ||
            decoded.first_be != 4'h3 || decoded.last_be != 4'hc)
            `uvm_fatal("TLPQ_FIELDS", "memory_read fields changed")
    endfunction

    // Mutation caught: reversing payload DWORD order or leaving a gap after header.
    function void check_memory_write();
        pcie_tl_mem_tlp request;
        pcie_tl_mem_tlp decoded;
        pcie_tl_tlp decoded_base;
        bit [31:0] expected[];
        bit [31:0] encoded_dpu[];
        string reason;

        request = pcie_tl_mem_tlp::type_id::create("memory_write");
        request.kind = TLP_MEM_WR;
        request.fmt = FMT_3DW_WITH_DATA;
        request.type_f = TLP_TYPE_MEM_WR;
        request.length = 10'd2;
        request.requester_id = 16'h6789;
        request.tag = 10'h0ab;
        request.addr = 64'h0000_0000_89ab_cdf0;
        request.first_be = 4'h7;
        request.last_be = 4'he;
        request.is_64bit = 1'b0;
        request.payload = new[8];
        request.payload[0] = 8'hde;
        request.payload[1] = 8'had;
        request.payload[2] = 8'hbe;
        request.payload[3] = 8'hef;
        request.payload[4] = 8'h01;
        request.payload[5] = 8'h23;
        request.payload[6] = 8'h45;
        request.payload[7] = 8'h67;

        expected = new[6];
        expected[0] = 32'h0000_0000;
        expected[1] = 32'h89ab_cdf0;
        expected[2] = 32'h6789_abe7;
        expected[3] = 32'h4000_0002;
        expected[4] = 32'hdead_beef;
        expected[5] = 32'h0123_4567;

        decoded_base = run_literal_vector("memory_write", request, expected);
        if (!$cast(decoded, decoded_base))
            `uvm_fatal("TLPQ_CLASS", "memory_write did not decode as pcie_tl_mem_tlp")
        expect_common("memory_write", decoded, TLP_MEM_WR,
                      FMT_3DW_WITH_DATA, TLP_TYPE_MEM_WR, 10'd2,
                      16'h6789, 8'hab, 8);
        if (decoded.addr != 64'h0000_0000_89ab_cdf0 || decoded.is_64bit ||
            decoded.first_be != 4'h7 || decoded.last_be != 4'he ||
            decoded.payload[0] != 8'hde || decoded.payload[1] != 8'had ||
            decoded.payload[2] != 8'hbe || decoded.payload[3] != 8'hef ||
            decoded.payload[4] != 8'h01 || decoded.payload[5] != 8'h23 ||
            decoded.payload[6] != 8'h45 || decoded.payload[7] != 8'h67)
            `uvm_fatal("TLPQ_FIELDS", "memory_write fields/payload changed")

        // Exercise the object-level encoder separately from the byte bridge.
        expect_success("memory_write encode_tlp",
            bridge.encode_tlp(request, encoded_dpu, reason), reason);
        expect_words("memory_write encode_tlp", encoded_dpu, expected);
    endfunction

    // Mutation caught: treating a 4DW message like a padded 3DW header.
    function void check_message_with_data();
        pcie_tl_msg_tlp request;
        pcie_tl_msg_tlp decoded;
        pcie_tl_tlp decoded_base;
        bit [31:0] expected[];

        request = pcie_tl_msg_tlp::type_id::create("message_with_data");
        request.kind = TLP_MSGD;
        request.fmt = FMT_4DW_WITH_DATA;
        request.type_f = TLP_TYPE_MSG_ID;
        request.length = 10'd2;
        request.requester_id = 16'h789a;
        request.tag = 10'h0bc;
        request.msg_code = MSG_VENDOR_TYPE0;
        request.msg_addr = 64'hcafe_babe_0bad_f00d;
        request.payload = new[8];
        request.payload[0] = 8'h10;
        request.payload[1] = 8'h32;
        request.payload[2] = 8'h54;
        request.payload[3] = 8'h76;
        request.payload[4] = 8'h98;
        request.payload[5] = 8'hba;
        request.payload[6] = 8'hdc;
        request.payload[7] = 8'hfe;

        expected = new[6];
        expected[0] = 32'h0bad_f00d;
        expected[1] = 32'hcafe_babe;
        expected[2] = 32'h789a_bc7e;
        expected[3] = 32'h7200_0002;
        expected[4] = 32'h1032_5476;
        expected[5] = 32'h98ba_dcfe;

        decoded_base = run_literal_vector("message_with_data", request, expected);
        if (!$cast(decoded, decoded_base))
            `uvm_fatal("TLPQ_CLASS", "message_with_data did not decode as pcie_tl_msg_tlp")
        expect_common("message_with_data", decoded, TLP_MSGD,
                      FMT_4DW_WITH_DATA, TLP_TYPE_MSG_ID, 10'd2,
                      16'h789a, 8'hbc, 8);
        if (decoded.msg_code != MSG_VENDOR_TYPE0 ||
            decoded.msg_addr != 64'hcafe_babe_0bad_f00d ||
            decoded.payload[0] != 8'h10 || decoded.payload[1] != 8'h32 ||
            decoded.payload[2] != 8'h54 || decoded.payload[3] != 8'h76 ||
            decoded.payload[4] != 8'h98 || decoded.payload[5] != 8'hba ||
            decoded.payload[6] != 8'hdc || decoded.payload[7] != 8'hfe)
            `uvm_fatal("TLPQ_FIELDS", "message_with_data fields/payload changed")
    endfunction

    // Mutation caught: mapping Completion DW1/DW2 in canonical instead of DPU order.
    function void check_completion();
        pcie_tl_cpl_tlp request;
        pcie_tl_cpl_tlp decoded;
        pcie_tl_tlp decoded_base;
        bit [31:0] expected[];

        request = pcie_tl_cpl_tlp::type_id::create("completion");
        request.kind = TLP_CPL;
        request.fmt = FMT_3DW_NO_DATA;
        request.type_f = TLP_TYPE_CPL;
        request.length = 10'd0;
        // Pinned decode reads common requester/tag from DW1 for every kind.
        // Harmonize Completion values so public-codec round trip remains exact.
        request.requester_id = 16'h89ab;
        request.tag = 10'h032;
        request.completer_id = 16'h89ab;
        request.cpl_status = CPL_STATUS_UR;
        request.bcm = 1'b1;
        request.byte_count = 12'h234;
        request.lower_addr = 7'h5a;

        expected = new[4];
        expected[0] = 32'h0000_0000;
        expected[1] = 32'h89ab_325a;
        expected[2] = 32'h89ab_3234;
        expected[3] = 32'h0a00_0000;

        decoded_base = run_literal_vector("completion", request, expected);
        if (!$cast(decoded, decoded_base))
            `uvm_fatal("TLPQ_CLASS", "completion did not decode as pcie_tl_cpl_tlp")
        expect_common("completion", decoded, TLP_CPL,
                      FMT_3DW_NO_DATA, TLP_TYPE_CPL, 10'd0,
                      16'h89ab, 8'h32, 0);
        if (decoded.completer_id != 16'h89ab ||
            decoded.cpl_status != CPL_STATUS_UR || !decoded.bcm ||
            decoded.byte_count != 12'h234 || decoded.lower_addr != 7'h5a)
            `uvm_fatal("TLPQ_FIELDS", "completion fields changed")
    endfunction

    // Mutation caught: failing to preserve the first Completion payload DWORD.
    function void check_completion_with_data();
        pcie_tl_cpl_tlp request;
        pcie_tl_cpl_tlp decoded;
        pcie_tl_tlp decoded_base;
        bit [31:0] expected[];

        request = pcie_tl_cpl_tlp::type_id::create("completion_with_data");
        request.kind = TLP_CPLD;
        request.fmt = FMT_3DW_WITH_DATA;
        request.type_f = TLP_TYPE_CPL;
        request.length = 10'd1;
        // DW1[15:8] is zero for this completion, matching the pinned common
        // decode only when the explicit Tag is zero.
        request.requester_id = 16'h9abc;
        request.tag = 10'h000;
        request.completer_id = 16'h9abc;
        request.cpl_status = CPL_STATUS_SC;
        request.bcm = 1'b0;
        request.byte_count = 12'h004;
        request.lower_addr = 7'h3c;
        request.payload = new[4];
        request.payload[0] = 8'hfe;
        request.payload[1] = 8'hdc;
        request.payload[2] = 8'hba;
        request.payload[3] = 8'h98;

        expected = new[5];
        expected[0] = 32'h0000_0000;
        expected[1] = 32'h9abc_003c;
        expected[2] = 32'h9abc_0004;
        expected[3] = 32'h4a00_0001;
        expected[4] = 32'hfedc_ba98;

        decoded_base = run_literal_vector("completion_with_data", request, expected);
        if (!$cast(decoded, decoded_base))
            `uvm_fatal("TLPQ_CLASS", "completion_with_data did not decode as pcie_tl_cpl_tlp")
        expect_common("completion_with_data", decoded, TLP_CPLD,
                      FMT_3DW_WITH_DATA, TLP_TYPE_CPL, 10'd1,
                      16'h9abc, 8'h00, 4);
        if (decoded.completer_id != 16'h9abc ||
            decoded.cpl_status != CPL_STATUS_SC || decoded.bcm ||
            decoded.byte_count != 12'h004 || decoded.lower_addr != 7'h3c ||
            decoded.payload[0] != 8'hfe || decoded.payload[1] != 8'hdc ||
            decoded.payload[2] != 8'hba || decoded.payload[3] != 8'h98)
            `uvm_fatal("TLPQ_FIELDS", "completion_with_data fields/payload changed")
    endfunction

    // Mutation caught: interpreting a data Length of zero as anything but 1024 DW.
    function void check_max_length_data();
        bit [7:0] canonical[];
        bit [7:0] rebuilt_canonical[];
        bit [7:0] dpu_bytes[];
        bit [31:0] actual_dpu[];
        bit [31:0] expected_dpu[];
        string reason;

        // Literal 3DW Memory Write header with encoded Length=0, followed by
        // exactly 4096 payload bytes. New two-state array elements are zero.
        canonical = new[12 + 4096];
        canonical[0] = 8'h40;
        canonical[4] = 8'h12;
        canonical[5] = 8'h34;
        canonical[6] = 8'h56;
        canonical[7] = 8'hff;
        canonical[8] = 8'h89;
        canonical[9] = 8'hab;
        canonical[10] = 8'hcd;
        canonical[11] = 8'hef;
        canonical[12] = 8'h11;
        canonical[13] = 8'h22;
        canonical[14] = 8'h33;
        canonical[15] = 8'h44;
        canonical[4104] = 8'haa;
        canonical[4105] = 8'hbb;
        canonical[4106] = 8'hcc;
        canonical[4107] = 8'hdd;

        expected_dpu = new[4 + 1024];
        expected_dpu[0] = 32'h0000_0000;
        expected_dpu[1] = 32'h89ab_cdef;
        expected_dpu[2] = 32'h1234_56ff;
        expected_dpu[3] = 32'h4000_0000;
        expected_dpu[4] = 32'h1122_3344;
        expected_dpu[1027] = 32'haabb_ccdd;

        expect_success("length_zero_codec_bytes_to_dpu",
            bridge.codec_bytes_to_dpu(canonical, actual_dpu, reason), reason);
        expect_words("length_zero_exact_1024_dwords",
                     actual_dpu, expected_dpu);

        words_to_dpu_bytes(expected_dpu, dpu_bytes);
        expect_success("length_zero_dpu_bytes_to_codec",
            bridge.dpu_bytes_to_codec(dpu_bytes, rebuilt_canonical, reason),
            reason);
        expect_bytes("length_zero_exact_4096_payload_bytes",
                     rebuilt_canonical, canonical);
    endfunction

    function void expect_dpu_reject(string case_name,
                                    input bit [7:0] malformed[]);
        pcie_tl_tlp decoded;
        bit [7:0] codec_bytes[];
        string reason;

        codec_bytes = new[1];
        codec_bytes[0] = 8'haa;
        if (bridge.dpu_bytes_to_codec(malformed, codec_bytes, reason))
            `uvm_fatal("TLPQ_MALFORMED", {case_name, ": accepted by byte bridge"})
        if (reason == "" || codec_bytes.size() != 0)
            `uvm_fatal("TLPQ_MALFORMED", $sformatf(
                "%s: unsafe byte-bridge rejection reason='%s' output=%0d",
                case_name, reason, codec_bytes.size()))

        decoded = pcie_tl_tlp::type_id::create({case_name, "_dirty"});
        if (bridge.decode_tlp(malformed, decoded, reason))
            `uvm_fatal("TLPQ_MALFORMED", {case_name, ": accepted by decoder"})
        if (reason == "" || decoded != null)
            `uvm_fatal("TLPQ_MALFORMED", $sformatf(
                "%s: unsafe decode rejection reason='%s' decoded_null=%0b",
                case_name, reason, decoded == null))
    endfunction

    function void expect_codec_reject(string case_name,
                                      input bit [7:0] malformed[]);
        bit [31:0] dpu_dwords[];
        string reason;

        dpu_dwords = new[1];
        dpu_dwords[0] = 32'hdead_beef;
        if (bridge.codec_bytes_to_dpu(malformed, dpu_dwords, reason))
            `uvm_fatal("TLPQ_MALFORMED", {case_name, ": accepted codec bytes"})
        if (reason == "" || dpu_dwords.size() != 0)
            `uvm_fatal("TLPQ_MALFORMED", $sformatf(
                "%s: unsafe codec rejection reason='%s' output=%0d",
                case_name, reason, dpu_dwords.size()))
    endfunction

    // Mutations caught: missing size/padding/Fmt/Length validation and dirty outputs.
    function void check_malformed_layouts();
        pcie_tl_tlp null_tlp;
        bit [31:0] words[];
        bit [31:0] dpu_dwords[];
        bit [7:0] short_dpu[];
        bit [7:0] valid_dpu[];
        bit [7:0] misaligned_dpu[];
        bit [7:0] declared_too_large[];
        bit [7:0] nonzero_padding[];
        bit [7:0] zero_length_data[];
        bit [7:0] invalid_fmt_dpu[];
        bit [7:0] codec_extra[];
        bit [7:0] codec_short_data[];
        bit [7:0] codec_misaligned[];
        string reason;

        short_dpu = new[12];
        foreach (short_dpu[i]) short_dpu[i] = 8'h00;
        expect_dpu_reject("below_16_bytes", short_dpu);

        words = new[4];
        words[0] = 32'h0000_0000;
        words[1] = 32'habcd_0048;
        words[2] = 32'h1234_560f;
        words[3] = 32'h0400_0001;
        words_to_dpu_bytes(words, valid_dpu);
        misaligned_dpu = new[17];
        for (int i = 0; i < 16; i++) misaligned_dpu[i] = valid_dpu[i];
        misaligned_dpu[16] = 8'h00;
        expect_dpu_reject("non_dword_aligned", misaligned_dpu);

        words[0] = 32'h0000_0000;
        words[1] = 32'hbcde_06ac;
        words[2] = 32'h2345_670a;
        words[3] = 32'h4400_0002;
        words_to_dpu_bytes(words, declared_too_large);
        expect_dpu_reject("declared_data_exceeds_dpu", declared_too_large);

        words[0] = 32'h0000_0001;
        words[1] = 32'habcd_0048;
        words[2] = 32'h1234_560f;
        words[3] = 32'h0400_0001;
        words_to_dpu_bytes(words, nonzero_padding);
        expect_dpu_reject("nonzero_3dw_padding", nonzero_padding);

        words[0] = 32'h0000_0000;
        words[1] = 32'hbcde_06ac;
        words[2] = 32'h2345_670a;
        words[3] = 32'h4400_0000;
        words_to_dpu_bytes(words, zero_length_data);
        expect_dpu_reject("zero_length_means_1024_dwords", zero_length_data);

        words[0] = 32'h0000_0000;
        words[1] = 32'h0000_0000;
        words[2] = 32'h0000_0000;
        words[3] = 32'h8000_0000;
        words_to_dpu_bytes(words, invalid_fmt_dpu);
        expect_dpu_reject("unsupported_fmt", invalid_fmt_dpu);

        // Canonical 3DW no-data header with one impossible trailing DWORD.
        codec_extra = new[16];
        codec_extra[0] = 8'h04;
        codec_extra[1] = 8'h00;
        codec_extra[2] = 8'h00;
        codec_extra[3] = 8'h01;
        codec_extra[4] = 8'h12;
        codec_extra[5] = 8'h34;
        codec_extra[6] = 8'h56;
        codec_extra[7] = 8'h0f;
        codec_extra[8] = 8'hab;
        codec_extra[9] = 8'hcd;
        codec_extra[10] = 8'h00;
        codec_extra[11] = 8'h48;
        codec_extra[12] = 8'hde;
        codec_extra[13] = 8'had;
        codec_extra[14] = 8'hbe;
        codec_extra[15] = 8'hef;
        expect_codec_reject("codec_output_extra_data", codec_extra);

        // Canonical write declares two DWORDs but contains only one.
        codec_short_data = new[16];
        codec_short_data[0] = 8'h44;
        codec_short_data[1] = 8'h00;
        codec_short_data[2] = 8'h00;
        codec_short_data[3] = 8'h02;
        codec_short_data[4] = 8'h23;
        codec_short_data[5] = 8'h45;
        codec_short_data[6] = 8'h67;
        codec_short_data[7] = 8'h0a;
        codec_short_data[8] = 8'hbc;
        codec_short_data[9] = 8'hde;
        codec_short_data[10] = 8'h06;
        codec_short_data[11] = 8'hac;
        codec_short_data[12] = 8'h11;
        codec_short_data[13] = 8'h22;
        codec_short_data[14] = 8'h33;
        codec_short_data[15] = 8'h44;
        expect_codec_reject("codec_output_declared_data_missing",
                            codec_short_data);

        codec_misaligned = new[13];
        for (int i = 0; i < 12; i++) codec_misaligned[i] = codec_extra[i];
        codec_misaligned[12] = 8'h00;
        expect_codec_reject("codec_non_dword_aligned", codec_misaligned);

        null_tlp = null;
        dpu_dwords = new[1];
        dpu_dwords[0] = 32'hffff_ffff;
        if (bridge.encode_tlp(null_tlp, dpu_dwords, reason))
            `uvm_fatal("TLPQ_MALFORMED", "null TLP was accepted")
        if (reason == "" || dpu_dwords.size() != 0)
            `uvm_fatal("TLPQ_MALFORMED", $sformatf(
                "null TLP rejection unsafe reason='%s' output=%0d",
                reason, dpu_dwords.size()))
    endfunction

    // Mutations caught: trusting malformed codec output or returning null success.
    function void check_codec_contract_inconsistencies();
        tlpq_fault_injection_bridge fault_bridge;
        pcie_tl_cfg_tlp request;
        pcie_tl_tlp decoded;
        bit [31:0] dpu_dwords[];
        bit [31:0] valid_words[];
        bit [7:0] valid_dpu[];
        string reason;

        fault_bridge = tlpq_fault_injection_bridge::type_id::create(
            "fault_bridge");
        request = pcie_tl_cfg_tlp::type_id::create("fault_request");
        request.kind = TLP_CFG_RD0;
        request.fmt = FMT_3DW_NO_DATA;
        request.type_f = TLP_TYPE_CFG_RD0;
        request.length = 10'd1;
        request.requester_id = 16'h1234;
        request.tag = 10'h056;
        request.completer_id = 16'habcd;
        request.reg_num = 10'h012;
        request.first_be = 4'hf;

        fault_bridge.inject_bad_encode = 1'b1;
        dpu_dwords = new[1];
        dpu_dwords[0] = 32'hffff_ffff;
        if (fault_bridge.encode_tlp(request, dpu_dwords, reason))
            `uvm_fatal("TLPQ_CODEC", "inconsistent codec output was accepted")
        if (reason == "" || dpu_dwords.size() != 0)
            `uvm_fatal("TLPQ_CODEC", $sformatf(
                "codec-output rejection unsafe reason='%s' output=%0d",
                reason, dpu_dwords.size()))

        valid_words = new[4];
        valid_words[0] = 32'h0000_0000;
        valid_words[1] = 32'habcd_0048;
        valid_words[2] = 32'h1234_560f;
        valid_words[3] = 32'h0400_0001;
        words_to_dpu_bytes(valid_words, valid_dpu);
        fault_bridge.inject_bad_encode = 1'b0;
        fault_bridge.inject_null_decode = 1'b1;
        decoded = request;
        if (fault_bridge.decode_tlp(valid_dpu, decoded, reason))
            `uvm_fatal("TLPQ_CODEC", "null codec decode was reported successful")
        if (reason == "" || decoded != null)
            `uvm_fatal("TLPQ_CODEC", $sformatf(
                "null-decode rejection unsafe reason='%s' decoded_null=%0b",
                reason, decoded == null))
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        bridge = tlpq_packet_bridge::type_id::create("bridge");
        if (bridge == null)
            `uvm_fatal("TLPQ_BRIDGE", "bridge factory creation returned null")

        check_cfg_read_type0();
        check_cfg_write_type0();
        check_cfg_read_type1();
        check_cfg_write_type1();
        check_memory_read();
        check_memory_write();
        check_message_with_data();
        check_completion();
        check_completion_with_data();
        check_max_length_data();
        check_malformed_layouts();
        check_codec_contract_inconsistencies();
        phase.drop_objection(this);
    endtask
endclass

`endif
