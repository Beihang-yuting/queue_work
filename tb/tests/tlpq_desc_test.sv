`ifndef TLPQ_DESC_TEST_SV
`define TLPQ_DESC_TEST_SV

class tlpq_alloc_error_catcher extends uvm_report_catcher;
    `uvm_object_utils(tlpq_alloc_error_catcher)

    int unsigned caught_errors;

    function new(string name = "tlpq_alloc_error_catcher");
        super.new(name);
        caught_errors = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR && get_id() == "HOST_MEM") begin
            caught_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class tlpq_desc_test extends uvm_test;
    `uvm_component_utils(tlpq_desc_test)

    function new(string name = "tlpq_desc_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void expect_byte(string field_name, byte actual, byte expected);
        if (actual !== expected)
            `uvm_fatal("TLPQ_LAYOUT", $sformatf(
                "%s: got 0x%02h expected 0x%02h",
                field_name, actual, expected))
    endfunction

    function void copy_bytes(input byte source[], ref byte destination[]);
        destination = new[source.size()];
        foreach (source[i])
            destination[i] = source[i];
    endfunction

    function void expect_bytes_equal(string check_name, input byte actual[],
                                     input byte expected[]);
        if (actual.size() != expected.size())
            `uvm_fatal("TLPQ_STATE", $sformatf(
                "%s: got size %0d expected %0d", check_name,
                actual.size(), expected.size()))
        foreach (expected[i]) begin
            if (actual[i] !== expected[i])
                `uvm_fatal("TLPQ_STATE", $sformatf(
                    "%s: byte %0d got 0x%02h expected 0x%02h",
                    check_name, i, actual[i], expected[i]))
        end
    endfunction

    function void expect_dpu_bytes_equal(string check_name,
                                         input bit [7:0] actual[],
                                         input byte expected[]);
        if (actual.size() != expected.size())
            `uvm_fatal("TLPQ_PARSE_RAW", $sformatf(
                "%s: got size %0d expected %0d", check_name,
                actual.size(), expected.size()))
        foreach (expected[i]) begin
            if (actual[i] !== expected[i])
                `uvm_fatal("TLPQ_PARSE_RAW", $sformatf(
                    "%s: byte %0d got 0x%02h expected 0x%02h",
                    check_name, i, actual[i], expected[i]))
        end
    endfunction

    function tlpq_rx_desc make_desc(string name, host_mem_manager mem);
        tlpq_rx_desc desc;

        desc = tlpq_rx_desc::type_id::create(name);
        desc.attach_mem(mem);
        if (!desc.prepare())
            `uvm_fatal("TLPQ_PREP", {name, " preparation failed"})
        if (desc.owned_allocation_count() != 1)
            `uvm_fatal("TLPQ_OWNER", $sformatf(
                "%s owns %0d allocations expected 1", name,
                desc.owned_allocation_count()))
        return desc;
    endfunction

    function void check_public_types();
        tlpq_channel_e channel;
        tlpq_route_metadata_t metadata;

        channel = TLPQ_HOST;
        metadata = '0;
        if (TLPQ_DEPTH != 32 || TLPQ_DESC_BYTES != 16 ||
            TLPQ_BUFFER_BYTES != 128 || TLPQ_DESC_AVAIL != 16'h0001 ||
            TLPQ_DESC_USED != 16'h0002 || TLPQ_HOST_QUEUE_ID != 0 ||
            TLPQ_SWITCH_QUEUE_ID != 1 || channel != TLPQ_HOST ||
            $bits(metadata) != 32)
            `uvm_fatal("TLPQ_TYPES", "public TLPQ constants/types changed")
    endfunction

    function void check_layout_ownership_and_stability();
        host_mem_manager mem;
        tlpq_rx_desc first;
        tlpq_rx_desc second;
        gq_addr_t first_addr;
        gq_addr_t second_addr;
        byte first_buffer[];
        byte second_buffer[];
        byte submitted[];
        byte completion[];
        byte incomplete[];
        byte before_reject[];
        byte corrupted[];
        byte after_reject[];

        mem = new("layout_mem");
        mem.init_region(64'h0000_0000_1000_0000,
                        64'h0000_0000_1000_ffff, MODE_LINEAR, 16);
        first = make_desc("first", mem);
        second = make_desc("second", mem);
        first_addr = first.buf_addr;
        second_addr = second.buf_addr;

        if (first_addr != 64'h0000_0000_1000_0000 ||
            second_addr != 64'h0000_0000_1000_0080 ||
            first_addr == second_addr || first.buf_len != 16'd128 ||
            second.buf_len != 16'd128)
            `uvm_fatal("TLPQ_ALLOC",
                "descriptors do not own distinct exact 128-byte buffers")

        mem.read_mem(first_addr, 128, first_buffer, `__FILE__, `__LINE__);
        mem.read_mem(second_addr, 128, second_buffer, `__FILE__, `__LINE__);
        if (first_buffer.size() != 128 || second_buffer.size() != 128)
            `uvm_fatal("TLPQ_BUFFER", "owned buffer size is not exactly 128")
        foreach (first_buffer[i]) begin
            if (first_buffer[i] !== 8'h00 || second_buffer[i] !== 8'h00)
                `uvm_fatal("TLPQ_BUFFER", $sformatf(
                    "owned buffer byte %0d was not cleared", i))
        end

        first.metadata.host_id = 4'h5;
        first.metadata.tlp_type = 4'ha;
        first.metadata.primary_bus = 8'hb2;
        first.metadata.secondary_bus = 8'hc3;
        first.metadata.subordinate_bus = 8'hd4;
        first.mark_available(1'b1);
        first.pack(submitted);
        if (submitted.size() != 16)
            `uvm_fatal("TLPQ_LAYOUT", $sformatf(
                "packed %0d bytes expected 16", submitted.size()))

        expect_byte("flags[7:0]", submitted[0], 8'h01);
        expect_byte("flags[15:8]", submitted[1], 8'h00);
        expect_byte("buf_len[7:0]", submitted[2], 8'h80);
        expect_byte("buf_len[15:8]", submitted[3], 8'h00);
        expect_byte("buf_addr[7:0]", submitted[4], 8'h00);
        expect_byte("buf_addr[15:8]", submitted[5], 8'h00);
        expect_byte("buf_addr[23:16]", submitted[6], 8'h00);
        expect_byte("buf_addr[31:24]", submitted[7], 8'h10);
        expect_byte("buf_addr[39:32]", submitted[8], 8'h00);
        expect_byte("buf_addr[47:40]", submitted[9], 8'h00);
        expect_byte("buf_addr[55:48]", submitted[10], 8'h00);
        expect_byte("buf_addr[63:56]", submitted[11], 8'h00);
        expect_byte("host/type", submitted[12], 8'ha5);
        expect_byte("primary_bus", submitted[13], 8'hb2);
        expect_byte("secondary_bus", submitted[14], 8'hc3);
        expect_byte("subordinate_bus", submitted[15], 8'hd4);
        if (first.dpu_bytes.size() != 0 || first.decoded_tlp != null)
            `uvm_fatal("TLPQ_RESULT", "fresh descriptor result slots are dirty")

        copy_bytes(submitted, completion);
        completion[0] = 8'h03;
        completion[1] = 8'h00;
        completion[2] = 8'h2c;
        completion[3] = 8'h00;
        completion[12] = 8'he7;
        completion[13] = 8'h45;
        completion[14] = 8'h67;
        completion[15] = 8'h89;
        if (!first.unpack(completion))
            `uvm_fatal("TLPQ_MUTABLE",
                "hardware length/routing writeback was rejected")
        if (!first.is_complete(1'b0) || first.buf_len != 16'h002c ||
            first.metadata.host_id != 4'h7 ||
            first.metadata.tlp_type != 4'he ||
            first.metadata.primary_bus != 8'h45 ||
            first.metadata.secondary_bus != 8'h67 ||
            first.metadata.subordinate_bus != 8'h89 ||
            first.buf_addr != first_addr)
            `uvm_fatal("TLPQ_MUTABLE",
                "writeback fields or stable address decoded incorrectly")

        copy_bytes(completion, incomplete);
        incomplete[0] = 8'h01;
        incomplete[2] = 8'h11;
        incomplete[12] = 8'h34;
        incomplete[13] = 8'h56;
        incomplete[14] = 8'h78;
        incomplete[15] = 8'h9a;
        if (!first.unpack(incomplete))
            `uvm_fatal("TLPQ_INCOMPLETE", "mutable incomplete writeback rejected")
        if (first.is_complete(1'b1))
            `uvm_fatal("TLPQ_INCOMPLETE", "missing USED completed descriptor")

        first.pack(before_reject);
        copy_bytes(completion, corrupted);
        corrupted[4] = corrupted[4] ^ 8'h01;
        if (first.unpack(corrupted))
            `uvm_fatal("TLPQ_STABLE", "changed buffer address was accepted")
        first.pack(after_reject);
        expect_bytes_equal("rejected address writeback state",
                           after_reject, before_reject);

        corrupted = new[15];
        if (first.unpack(corrupted))
            `uvm_fatal("TLPQ_SIZE", "wrong-size descriptor was accepted")
        first.pack(after_reject);
        expect_bytes_equal("rejected wrong-size state",
                           after_reject, before_reject);

        first.release_owned();
        first.release_owned();
        second.release_owned();
        second.release_owned();
        if (first.owned_allocation_count() != 0 ||
            second.owned_allocation_count() != 0)
            `uvm_fatal("TLPQ_RELEASE", "release retained owned allocations")
        mem.leak_check(`__FILE__, `__LINE__);
    endfunction

    function void check_prepare_failures_are_one_shot();
        host_mem_manager prepared_mem;
        host_mem_manager no_mem_rescue;
        host_mem_manager small_mem;
        host_mem_manager alloc_rescue;
        tlpq_rx_desc prepared_desc;
        tlpq_rx_desc no_mem_desc;
        tlpq_rx_desc alloc_failed_desc;
        tlpq_alloc_error_catcher catcher;
        gq_addr_t prepared_addr;
        byte prepared_state[];
        byte prepared_after[];
        byte prepared_buffer[];
        byte prepared_buffer_after[];
        byte no_mem_state[];
        byte no_mem_after[];
        byte alloc_failed_state[];
        byte alloc_failed_after[];

        prepared_mem = new("reprepare_mem");
        prepared_mem.init_region(64'h0000_0000_3000_0000,
                                 64'h0000_0000_3000_0fff,
                                 MODE_LINEAR, 16);
        prepared_desc = make_desc("reprepare_desc", prepared_mem);
        prepared_desc.metadata.host_id = 4'h6;
        prepared_desc.metadata.tlp_type = 4'h9;
        prepared_desc.metadata.primary_bus = 8'h12;
        prepared_desc.metadata.secondary_bus = 8'h34;
        prepared_desc.metadata.subordinate_bus = 8'h56;
        prepared_desc.mark_available(1'b0);
        prepared_addr = prepared_desc.buf_addr;
        prepared_desc.pack(prepared_state);
        prepared_mem.read_mem(prepared_addr, 128, prepared_buffer,
                              `__FILE__, `__LINE__);
        if (prepared_desc.prepare())
            `uvm_fatal("TLPQ_REPEAT", "second preparation was accepted")
        prepared_desc.pack(prepared_after);
        prepared_mem.read_mem(prepared_addr, 128, prepared_buffer_after,
                              `__FILE__, `__LINE__);
        if (prepared_desc.owned_allocation_count() != 1 ||
            prepared_desc.buf_addr != prepared_addr)
            `uvm_fatal("TLPQ_REPEAT",
                "second preparation changed address or ownership")
        expect_bytes_equal("second prepare descriptor state",
                           prepared_after, prepared_state);
        expect_bytes_equal("second prepare buffer state",
                           prepared_buffer_after, prepared_buffer);
        prepared_desc.release_owned();
        prepared_mem.leak_check(`__FILE__, `__LINE__);

        no_mem_rescue = new("no_mem_rescue");
        no_mem_rescue.init_region(64'h0000_0000_3100_0000,
                                  64'h0000_0000_3100_0fff,
                                  MODE_LINEAR, 16);
        no_mem_desc = tlpq_rx_desc::type_id::create("no_mem_desc");
        no_mem_desc.pack(no_mem_state);
        if (no_mem_desc.prepare())
            `uvm_fatal("TLPQ_NO_MEM",
                "preparation without attached memory succeeded")
        no_mem_desc.attach_mem(no_mem_rescue);
        if (no_mem_desc.prepare())
            `uvm_fatal("TLPQ_NO_MEM",
                "memory-less failure was retried after attaching memory")
        no_mem_desc.pack(no_mem_after);
        if (no_mem_desc.owned_allocation_count() != 0 ||
            no_mem_desc.buf_addr != 0 || no_mem_desc.buf_len != 0 ||
            no_mem_desc.flags != 0 || no_mem_desc.metadata != '0 ||
            no_mem_desc.dpu_bytes.size() != 0 ||
            no_mem_desc.decoded_tlp != null)
            `uvm_fatal("TLPQ_NO_MEM",
                "rejected memory-less preparation changed descriptor state")
        expect_bytes_equal("memory-less prepare state",
                           no_mem_after, no_mem_state);
        no_mem_desc.release_owned();
        no_mem_rescue.leak_check(`__FILE__, `__LINE__);

        small_mem = new("small_mem");
        small_mem.init_region(64'h0000_0000_3200_0000,
                              64'h0000_0000_3200_003f,
                              MODE_LINEAR, 16);
        alloc_rescue = new("alloc_rescue");
        alloc_rescue.init_region(64'h0000_0000_3300_0000,
                                 64'h0000_0000_3300_0fff,
                                 MODE_LINEAR, 16);
        alloc_failed_desc = tlpq_rx_desc::type_id::create(
            "alloc_failed_desc");
        alloc_failed_desc.attach_mem(small_mem);
        alloc_failed_desc.pack(alloc_failed_state);
        catcher = tlpq_alloc_error_catcher::type_id::create(
            "alloc_error_catcher");
        uvm_report_cb::add(null, catcher);
        if (alloc_failed_desc.prepare())
            `uvm_fatal("TLPQ_ALLOC_FAIL",
                "preparation succeeded without 128 bytes")
        uvm_report_cb::delete(null, catcher);
        if (catcher.caught_errors != 1)
            `uvm_fatal("TLPQ_ALLOC_FAIL", $sformatf(
                "caught %0d allocation errors expected 1",
                catcher.caught_errors))
        alloc_failed_desc.attach_mem(alloc_rescue);
        if (alloc_failed_desc.prepare())
            `uvm_fatal("TLPQ_ALLOC_FAIL",
                "allocation failure was retried with a larger allocator")
        alloc_failed_desc.pack(alloc_failed_after);
        if (alloc_failed_desc.owned_allocation_count() != 0 ||
            alloc_failed_desc.buf_addr != 0 ||
            alloc_failed_desc.buf_len != 0 ||
            alloc_failed_desc.flags != 0 ||
            alloc_failed_desc.metadata != '0 ||
            alloc_failed_desc.dpu_bytes.size() != 0 ||
            alloc_failed_desc.decoded_tlp != null)
            `uvm_fatal("TLPQ_ALLOC_FAIL",
                "allocation failure changed descriptor state or ownership")
        expect_bytes_equal("allocation-failed prepare state",
                           alloc_failed_after, alloc_failed_state);
        alloc_failed_desc.release_owned();
        small_mem.leak_check(`__FILE__, `__LINE__);
        alloc_rescue.leak_check(`__FILE__, `__LINE__);
    endfunction

    // Mutations caught: skipping the packet bridge, reading the advertised
    // capacity instead of completed buf_len, retaining a decoded object after
    // a bad length/layout, or parsing a rejected stable-address writeback.
    function void check_descriptor_completion_parsing();
        host_mem_manager mem;
        tlpq_rx_desc desc;
        tlpq_rx_desc stable_desc;
        pcie_tl_mem_tlp decoded_mem;
        gq_addr_t desc_addr;
        byte submitted[];
        byte completion[];
        byte malformed[];
        byte short_layout[];
        byte stable_submitted[];
        byte stable_completion[];
        byte golden[] = '{8'h80, 8'h77, 8'h66, 8'h55,
                          8'h44, 8'h33, 8'h22, 8'h11,
                          8'hc3, 8'h9a, 8'h78, 8'h56,
                          8'h02, 8'h00, 8'h00, 8'h20};

        mem = new("parse_mem");
        mem.init_region(64'h0000_0000_4000_0000,
                        64'h0000_0000_4000_ffff, MODE_LINEAR, 16);
        desc = make_desc("parse_desc", mem);
        desc_addr = desc.buf_addr;
        mem.write_mem(desc_addr, golden, `__FILE__, `__LINE__);

        desc.metadata.host_id = 4'h1;
        desc.metadata.tlp_type = 4'h2;
        desc.metadata.primary_bus = 8'h03;
        desc.metadata.secondary_bus = 8'h04;
        desc.metadata.subordinate_bus = 8'h05;
        desc.mark_available(1'b0);
        desc.pack(submitted);
        copy_bytes(submitted, completion);
        completion[0] = 8'h03;
        completion[2] = 8'h10;
        completion[3] = 8'h00;
        completion[12] = 8'he7;
        completion[13] = 8'h45;
        completion[14] = 8'h67;
        completion[15] = 8'h89;
        if (!desc.unpack(completion) || !desc.parse_completion())
            `uvm_fatal("TLPQ_PARSE_VALID",
                "valid completed descriptor did not parse")
        expect_dpu_bytes_equal("valid completion raw bytes",
                               desc.dpu_bytes, golden);
        if (!$cast(decoded_mem, desc.decoded_tlp) || decoded_mem == null ||
            decoded_mem.kind != TLP_MEM_RD ||
            decoded_mem.fmt != FMT_4DW_NO_DATA ||
            decoded_mem.type_f != TLP_TYPE_MEM_RD ||
            decoded_mem.length != 10'd2 ||
            decoded_mem.requester_id != 16'h5678 ||
            decoded_mem.tag[7:0] != 8'h9a ||
            decoded_mem.addr != 64'h1122_3344_5566_7780 ||
            !decoded_mem.is_64bit || decoded_mem.first_be != 4'h3 ||
            decoded_mem.last_be != 4'hc ||
            desc.metadata.host_id != 4'h7 ||
            desc.metadata.tlp_type != 4'he ||
            desc.metadata.primary_bus != 8'h45 ||
            desc.metadata.secondary_bus != 8'h67 ||
            desc.metadata.subordinate_bus != 8'h89)
            `uvm_fatal("TLPQ_PARSE_VALID",
                "raw completion, decoded TLP, or routing metadata changed")

        copy_bytes(golden, malformed);
        malformed[15] = 8'he0;
        mem.write_mem(desc_addr, malformed, `__FILE__, `__LINE__);
        if (desc.parse_completion())
            `uvm_fatal("TLPQ_PARSE_CODEC",
                "unsupported PCIe Fmt decoded successfully")
        expect_dpu_bytes_equal("malformed completion raw bytes",
                               desc.dpu_bytes, malformed);
        if (desc.decoded_tlp != null)
            `uvm_fatal("TLPQ_PARSE_CODEC",
                "codec failure retained a decoded object")

        short_layout = new[15];
        for (int unsigned i = 0; i < short_layout.size(); i++)
            short_layout[i] = golden[i];
        mem.write_mem(desc_addr, short_layout, `__FILE__, `__LINE__);
        completion[2] = 8'h0f;
        completion[3] = 8'h00;
        if (!desc.unpack(completion) || desc.parse_completion())
            `uvm_fatal("TLPQ_PARSE_LAYOUT",
                "short DPU layout parsed successfully")
        expect_dpu_bytes_equal("short completion raw bytes",
                               desc.dpu_bytes, short_layout);
        if (desc.decoded_tlp != null)
            `uvm_fatal("TLPQ_PARSE_LAYOUT",
                "layout failure retained a decoded object")

        completion[2] = 8'h81;
        completion[3] = 8'h00;
        if (!desc.unpack(completion) || desc.parse_completion())
            `uvm_fatal("TLPQ_PARSE_LENGTH",
                "completion length beyond the owned buffer was accepted")
        expect_dpu_bytes_equal("length failure preserves prior raw bytes",
                               desc.dpu_bytes, short_layout);
        if (desc.decoded_tlp != null)
            `uvm_fatal("TLPQ_PARSE_LENGTH",
                "length failure retained a decoded object")

        stable_desc = make_desc("stable_parse_desc", mem);
        mem.write_mem(stable_desc.buf_addr, golden, `__FILE__, `__LINE__);
        stable_desc.mark_available(1'b0);
        stable_desc.pack(stable_submitted);
        copy_bytes(stable_submitted, stable_completion);
        stable_completion[0] = 8'h03;
        stable_completion[2] = 8'h10;
        stable_completion[4] = stable_completion[4] ^ 8'h01;
        if (stable_desc.unpack(stable_completion))
            `uvm_fatal("TLPQ_PARSE_STABLE",
                "changed owned-buffer address was accepted")
        if (stable_desc.parse_completion() ||
            stable_desc.dpu_bytes.size() != 0 ||
            stable_desc.decoded_tlp != null)
            `uvm_fatal("TLPQ_PARSE_STABLE",
                "rejected stable address produced raw or decoded output")

        desc.release_owned();
        stable_desc.release_owned();
        mem.leak_check(`__FILE__, `__LINE__);
    endfunction

    // Mutations caught: any non-31/30/31/1/restart default, descriptor reuse,
    // buffer reuse after normal GQ preparation, or selecting auto-recycle.
    function void check_refill_profile();
        uvm_object profile_object;
        gq_refill_profile profile;
        gq_desc_base first_base;
        gq_desc_base second_base;
        tlpq_rx_desc first;
        tlpq_rx_desc second;
        host_mem_manager mem;
        gq_queue_cfg queue_cfg;
        string reason;

        profile_object = uvm_factory::get().create_object_by_name(
            "tlpq_refill_profile", get_full_name(), "profile");
        if (!$cast(profile, profile_object) || profile == null)
            `uvm_fatal("TLPQ_REFILL_TYPE",
                "tlpq_refill_profile is missing or not a GQ refill profile")
        if (profile.initial_post_count != 31 ||
            profile.low_watermark != 30 ||
            profile.high_watermark != 31 ||
            profile.max_refill_batch != 1 ||
            !profile.restart_after_reset ||
            !profile.validate(TLPQ_DEPTH, reason))
            `uvm_fatal("TLPQ_REFILL_DEFAULT", $sformatf(
                "31-entry batch-one defaults are invalid: %s", reason))

        first_base = profile.create_desc(9, 64'h0000_0001_0000_0002);
        second_base = profile.create_desc(9, 64'h0000_0001_0000_0002);
        if (!$cast(first, first_base) || !$cast(second, second_base) ||
            first == null || second == null || first == second)
            `uvm_fatal("TLPQ_REFILL_CREATE",
                "create_desc did not return fresh TLPQ RX descriptors")
        if (first.owned_allocation_count() != 0 ||
            second.owned_allocation_count() != 0)
            `uvm_fatal("TLPQ_REFILL_PREP",
                "profile allocated buffers before normal GQ preparation")

        mem = new("refill_mem");
        mem.init_region(64'h0000_0000_5000_0000,
                        64'h0000_0000_5000_ffff, MODE_LINEAR, 16);
        first.attach_mem(mem);
        second.attach_mem(mem);
        if (!first.prepare() || !second.prepare() ||
            first.owned_allocation_count() != 1 ||
            second.owned_allocation_count() != 1 ||
            first.buf_addr == second.buf_addr)
            `uvm_fatal("TLPQ_REFILL_OWNER",
                "prepared refill descriptors do not own distinct buffers")

        queue_cfg = gq_queue_cfg::type_id::create("queue_cfg");
        if (queue_cfg.rx_slot_mode != GQ_RX_EXPLICIT_REFILL)
            `uvm_fatal("TLPQ_REFILL_MODE",
                "TLPQ refill requires explicit-refill queue ownership")

        first.release_owned();
        second.release_owned();
        mem.leak_check(`__FILE__, `__LINE__);
    endfunction

    task check_generic_completion();
        host_mem_manager mem;
        tlpq_rx_desc first;
        tlpq_rx_desc second;
        tlpq_completion completion_source;
        gq_desc_base pending[$];
        gq_addr_t ring_base;
        gq_addr_t first_addr;
        gq_addr_t second_addr;
        byte first_bytes[];
        byte second_bytes[];
        bit valid;
        int unsigned completed_count;

        mem = new("completion_mem");
        mem.init_region(64'h0000_0000_2000_0000,
                        64'h0000_0000_2000_ffff, MODE_LINEAR, 16);
        ring_base = mem.alloc(2 * 16, 16, `__FILE__, `__LINE__);
        if (ring_base == '1)
            `uvm_fatal("TLPQ_COMPLETION", "ring allocation failed")
        first = make_desc("completion_first", mem);
        second = make_desc("completion_second", mem);
        first_addr = first.buf_addr;
        second_addr = second.buf_addr;
        first.mark_available(1'b0);
        second.mark_available(1'b0);
        first.pack(first_bytes);
        second.pack(second_bytes);

        first_bytes[0] = 8'h03;
        first_bytes[2] = 8'h21;
        first_bytes[12] = 8'hba;
        first_bytes[13] = 8'h12;
        first_bytes[14] = 8'h34;
        first_bytes[15] = 8'h56;
        second_bytes[2] = 8'h43;
        second_bytes[12] = 8'hdc;
        second_bytes[13] = 8'h78;
        second_bytes[14] = 8'h9a;
        second_bytes[15] = 8'hbc;
        mem.write_mem(ring_base, first_bytes, `__FILE__, `__LINE__);
        mem.write_mem(ring_base + 16, second_bytes, `__FILE__, `__LINE__);

        pending.push_back(first);
        pending.push_back(second);
        completion_source = tlpq_completion::type_id::create(
            "completion_source");
        completion_source.query_completed(mem, null, ring_base, 0, 2, 16,
                                          0, pending, valid,
                                          completed_count);
        if (!valid || completed_count != 1)
            `uvm_fatal("TLPQ_COMPLETION", $sformatf(
                "got valid=%0b count=%0d expected valid=1 count=1",
                valid, completed_count))
        if (first.buf_addr != first_addr || second.buf_addr != second_addr ||
            first.buf_len != 16'h0021 || second.buf_len != 16'h0043 ||
            first.metadata.host_id != 4'ha ||
            first.metadata.tlp_type != 4'hb ||
            first.metadata.primary_bus != 8'h12 ||
            first.metadata.secondary_bus != 8'h34 ||
            first.metadata.subordinate_bus != 8'h56 ||
            second.metadata.host_id != 4'hc ||
            second.metadata.tlp_type != 4'hd ||
            second.metadata.primary_bus != 8'h78 ||
            second.metadata.secondary_bus != 8'h9a ||
            second.metadata.subordinate_bus != 8'hbc)
            `uvm_fatal("TLPQ_COMPLETION",
                "generic writeback did not preserve ownership/decode metadata")

        first.release_owned();
        second.release_owned();
        mem.free(ring_base, `__FILE__, `__LINE__);
        mem.leak_check(`__FILE__, `__LINE__);
    endtask

    function void check_pointer_vectors();
        tlpq_ptr_codec codec;
        string reason;

        codec = tlpq_ptr_codec::type_id::create("codec");
        if (codec.encode_publish(0, 31, 32) != 32'h0000_001f ||
            codec.encode_publish(31, 32, 32) != 32'h0000_8000 ||
            codec.encode_publish(32, 64, 32) != 32'h0000_0000)
            `uvm_fatal("TLPQ_PTR", "bit-15 pointer vectors did not match")
        if (codec.validate_depth(0, reason) || reason == "")
            `uvm_fatal("TLPQ_PTR_VALIDATE",
                "zero depth was accepted or lacked a rejection reason")
        if (!codec.validate_depth(32, reason) || reason != "")
            `uvm_fatal("TLPQ_PTR_VALIDATE", $sformatf(
                "TLPQ depth 32 was rejected: %s", reason))
        if (!codec.validate_depth(32768, reason) || reason != "")
            `uvm_fatal("TLPQ_PTR_VALIDATE", $sformatf(
                "15-bit maximum depth was rejected: %s", reason))
        if (codec.validate_depth(32769, reason) || reason == "")
            `uvm_fatal("TLPQ_PTR_VALIDATE",
                "depth above 15-bit maximum was accepted or lacked a reason")
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        check_public_types();
        check_layout_ownership_and_stability();
        check_prepare_failures_are_one_shot();
        check_refill_profile();
        check_descriptor_completion_parsing();
        check_pointer_vectors();
        check_generic_completion();
        phase.drop_objection(this);
    endtask
endclass

`endif
