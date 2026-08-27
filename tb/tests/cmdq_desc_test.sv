`ifndef CMDQ_DESC_TEST_SV
`define CMDQ_DESC_TEST_SV

class cmdq_alloc_error_catcher extends uvm_report_catcher;
    `uvm_object_utils(cmdq_alloc_error_catcher)

    int unsigned caught_errors;

    function new(string name = "cmdq_alloc_error_catcher");
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

class cmdq_desc_test extends uvm_test;
    `uvm_component_utils(cmdq_desc_test)

    function new(string name = "cmdq_desc_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void expect_byte(string field_name, byte actual, byte expected);
        if (actual !== expected)
            `uvm_fatal("CMDQ_LAYOUT", $sformatf(
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
            `uvm_fatal("CMDQ_STATE", $sformatf(
                "%s: got size %0d expected %0d", check_name,
                actual.size(), expected.size()))
        foreach (expected[i]) begin
            if (actual[i] !== expected[i])
                `uvm_fatal("CMDQ_STATE", $sformatf(
                    "%s: byte %0d got 0x%02h expected 0x%02h",
                    check_name, i, actual[i], expected[i]))
        end
    endfunction

    function void expect_stable_state(cmdq_tx_desc desc,
                                      byte expected_packed[],
                                      string check_name);
        byte actual_packed[];

        desc.pack(actual_packed);
        expect_bytes_equal(check_name, actual_packed, expected_packed);
        if (desc.tx_buf_len != 16'd3 ||
            desc.tx_buf_addr != 64'h0000_0000_1000_0000 ||
            desc.dst_id != CMDQ_DST_FSE ||
            desc.rx_buf_addr != 64'h0000_0000_1000_0100 ||
            desc.reserved != 64'h0)
            `uvm_fatal("CMDQ_STATE", {check_name,
                ": rejected unpack changed a trusted stable field"})
    endfunction

    function void check_layout_and_buffers(host_mem_manager mem,
                                           output cmdq_tx_desc desc,
                                           output byte submitted[]);
        byte tx_contents[];
        byte rx_contents[];

        desc = cmdq_tx_desc::type_id::create("desc");
        desc.request = new[3];
        desc.request[0] = 8'haa;
        desc.request[1] = 8'h55;
        desc.request[2] = 8'hc3;
        desc.dst_id = CMDQ_DST_FSE;
        desc.attach_mem(mem);

        if (!desc.prepare())
            `uvm_fatal("CMDQ_PREP", "three-byte request preparation failed")
        if (desc.owned_allocation_count() != 2)
            `uvm_fatal("CMDQ_OWNER", $sformatf(
                "got %0d owned allocations expected 2",
                desc.owned_allocation_count()))
        if (desc.tx_buf_addr != 64'h0000_0000_1000_0000 ||
            desc.rx_buf_addr != 64'h0000_0000_1000_0100 ||
            desc.tx_buf_addr == desc.rx_buf_addr)
            `uvm_fatal("CMDQ_ADDR",
                "TX and RX are not the expected distinct 256-byte allocations")
        if (desc.tx_buf_len != 16'd3 ||
            desc.rx_buf_len != CMDQ_BUFFER_BYTES)
            `uvm_fatal("CMDQ_LENGTH",
                "prepared descriptor lengths do not advertise request and RX capacity")

        mem.read_mem(desc.tx_buf_addr, CMDQ_BUFFER_BYTES, tx_contents,
                     `__FILE__, `__LINE__);
        mem.read_mem(desc.rx_buf_addr, CMDQ_BUFFER_BYTES, rx_contents,
                     `__FILE__, `__LINE__);
        if (tx_contents.size() != CMDQ_BUFFER_BYTES ||
            rx_contents.size() != CMDQ_BUFFER_BYTES)
            `uvm_fatal("CMDQ_BUFFER", "owned buffer size is not exactly 256")
        foreach (tx_contents[i]) begin
            if (i < 3) begin
                if (tx_contents[i] !== desc.request[i])
                    `uvm_fatal("CMDQ_TX_DATA", $sformatf(
                        "request byte %0d was not copied", i))
            end else if (tx_contents[i] !== 8'h00) begin
                `uvm_fatal("CMDQ_TX_ZERO", $sformatf(
                    "TX padding byte %0d is not zero", i))
            end
        end
        foreach (rx_contents[i]) begin
            if (rx_contents[i] !== 8'h00)
                `uvm_fatal("CMDQ_RX_ZERO", $sformatf(
                    "RX byte %0d is not zero", i))
        end

        desc.mark_available(1'b1);
        if (desc.flags != CMDQ_DESC_AVAIL ||
            (desc.flags & CMDQ_DESC_USED) != 0)
            `uvm_fatal("CMDQ_FLAGS",
                "submission did not set AVAIL=1 and USED=0")
        desc.pack(submitted);
        if (submitted.size() != CMDQ_DESC_BYTES)
            `uvm_fatal("CMDQ_SIZE", $sformatf(
                "got %0d descriptor bytes expected 32", submitted.size()))

        expect_byte("flags[7:0]",       submitted[0],  8'h01);
        expect_byte("flags[15:8]",      submitted[1],  8'h00);
        expect_byte("tx_buf_len[7:0]",  submitted[2],  8'h03);
        expect_byte("tx_buf_len[15:8]", submitted[3],  8'h00);
        for (int unsigned i = 0; i < 8; i++)
            expect_byte($sformatf("tx_buf_addr[%0d]", i), submitted[4+i],
                        byte'(64'h0000_0000_1000_0000 >> (8*i)));
        expect_byte("dst_id[7:0]",       submitted[12], 8'h02);
        expect_byte("dst_id[15:8]",      submitted[13], 8'h00);
        expect_byte("rx_buf_len[7:0]",   submitted[14], 8'h00);
        expect_byte("rx_buf_len[15:8]",  submitted[15], 8'h01);
        for (int unsigned i = 0; i < 8; i++)
            expect_byte($sformatf("rx_buf_addr[%0d]", i), submitted[16+i],
                        byte'(64'h0000_0000_1000_0100 >> (8*i)));
        for (int unsigned i = 24; i < 32; i++)
            expect_byte($sformatf("reserved[%0d]", i-24), submitted[i], 8'h00);
    endfunction

    function void check_prepare_rejections(host_mem_manager mem);
        cmdq_tx_desc oversized;
        cmdq_tx_desc repeated;
        byte before_tx[];
        byte before_rx[];
        byte after_tx[];
        byte after_rx[];
        gq_addr_t tx_addr;
        gq_addr_t rx_addr;

        oversized = cmdq_tx_desc::type_id::create("oversized");
        oversized.request = new[CMDQ_BUFFER_BYTES + 1];
        foreach (oversized.request[i])
            oversized.request[i] = byte'(i);
        oversized.attach_mem(mem);
        if (oversized.prepare())
            `uvm_fatal("CMDQ_OVERSIZE", "257-byte request was accepted")
        if (oversized.owned_allocation_count() != 0 ||
            oversized.tx_buf_addr != 0 || oversized.rx_buf_addr != 0 ||
            oversized.tx_buf_len != 0 || oversized.rx_buf_len != 0)
            `uvm_fatal("CMDQ_OVERSIZE",
                "oversized request caused allocation or descriptor side effects")

        repeated = cmdq_tx_desc::type_id::create("repeated");
        repeated.request = new[1];
        repeated.request[0] = 8'h7e;
        repeated.dst_id = CMDQ_DST_PSTAT;
        repeated.attach_mem(mem);
        if (!repeated.prepare())
            `uvm_fatal("CMDQ_REPEAT", "initial preparation failed")
        tx_addr = repeated.tx_buf_addr;
        rx_addr = repeated.rx_buf_addr;
        mem.read_mem(tx_addr, CMDQ_BUFFER_BYTES, before_tx,
                     `__FILE__, `__LINE__);
        mem.read_mem(rx_addr, CMDQ_BUFFER_BYTES, before_rx,
                     `__FILE__, `__LINE__);
        repeated.request[0] = 8'h99;
        if (repeated.prepare())
            `uvm_fatal("CMDQ_REPEAT", "second preparation was accepted")
        if (repeated.owned_allocation_count() != 2 ||
            repeated.tx_buf_addr != tx_addr || repeated.rx_buf_addr != rx_addr)
            `uvm_fatal("CMDQ_REPEAT",
                "second preparation changed allocation ownership")
        mem.read_mem(tx_addr, CMDQ_BUFFER_BYTES, after_tx,
                     `__FILE__, `__LINE__);
        mem.read_mem(rx_addr, CMDQ_BUFFER_BYTES, after_rx,
                     `__FILE__, `__LINE__);
        expect_bytes_equal("second prepare TX", after_tx, before_tx);
        expect_bytes_equal("second prepare RX", after_rx, before_rx);

        oversized.release_owned();
        oversized.release_owned();
        repeated.release_owned();
        repeated.release_owned();
    endfunction

    function void check_allocation_rollback();
        host_mem_manager small_mem;
        cmdq_tx_desc desc;
        cmdq_alloc_error_catcher catcher;

        small_mem = new("small_mem");
        small_mem.init_region(64'h2000_0000, 64'h2000_00ff,
                              MODE_LINEAR, 16);
        desc = cmdq_tx_desc::type_id::create("rollback_desc");
        desc.request = new[1];
        desc.request[0] = 8'h5a;
        desc.attach_mem(small_mem);
        catcher = new("catcher");
        uvm_report_cb::add(null, catcher);
        if (desc.prepare())
            `uvm_fatal("CMDQ_ROLLBACK",
                "preparation succeeded without space for the RX buffer")
        uvm_report_cb::delete(null, catcher);
        if (catcher.caught_errors != 1)
            `uvm_fatal("CMDQ_ROLLBACK", $sformatf(
                "caught %0d allocation errors expected 1", catcher.caught_errors))
        if (desc.owned_allocation_count() != 0 ||
            desc.tx_buf_addr != 0 || desc.rx_buf_addr != 0 ||
            desc.tx_buf_len != 0 || desc.rx_buf_len != 0)
            `uvm_fatal("CMDQ_ROLLBACK",
                "failed preparation retained ownership or descriptor state")
        uvm_report_cb::add(null, catcher);
        if (desc.prepare())
            `uvm_fatal("CMDQ_ROLLBACK",
                "allocation-failed descriptor was prepared a second time")
        uvm_report_cb::delete(null, catcher);
        if (catcher.caught_errors != 1)
            `uvm_fatal("CMDQ_ROLLBACK",
                "second prepare retried allocation after a failed attempt")
        desc.release_owned();
        desc.release_owned();
        small_mem.leak_check(`__FILE__, `__LINE__);
    endfunction

    function void expect_corruption_rejected(cmdq_tx_desc desc,
                                             byte submitted[],
                                             int unsigned offset,
                                             string field_name);
        byte corrupted[];

        copy_bytes(submitted, corrupted);
        corrupted[offset] = corrupted[offset] ^ 8'h01;
        if (desc.unpack(corrupted))
            `uvm_fatal("CMDQ_CORRUPT", {field_name, " corruption was accepted"})
        expect_stable_state(desc, submitted, {field_name, " rejection"});
    endfunction

    function void check_stable_fields(cmdq_tx_desc desc, byte submitted[]);
        byte wrong_size[];

        expect_corruption_rejected(desc, submitted, 2,  "TX length");
        expect_corruption_rejected(desc, submitted, 4,  "TX address");
        expect_corruption_rejected(desc, submitted, 12, "destination");
        expect_corruption_rejected(desc, submitted, 16, "RX address");
        expect_corruption_rejected(desc, submitted, 24, "reserved");

        wrong_size = new[CMDQ_DESC_BYTES - 1];
        if (desc.unpack(wrong_size))
            `uvm_fatal("CMDQ_CORRUPT", "wrong-size descriptor was accepted")
        expect_stable_state(desc, submitted, "wrong-size rejection");
    endfunction

    function void check_completion(host_mem_manager mem,
                                   cmdq_tx_desc desc,
                                   byte submitted[]);
        byte completion[];
        byte result_bytes[];

        if (desc.parse_completion())
            `uvm_fatal("CMDQ_USED", "completion without USED was accepted")
        if (desc.completion_event.is_on() || desc.result.size() != 0)
            `uvm_fatal("CMDQ_USED",
                "incomplete descriptor changed result or completion event")

        copy_bytes(submitted, completion);
        completion[0]  = byte'(CMDQ_DESC_AVAIL | CMDQ_DESC_USED);
        completion[1]  = 8'h00;
        completion[14] = 8'h01;
        completion[15] = 8'h01;
        if (!desc.unpack(completion))
            `uvm_fatal("CMDQ_RX_LEN",
                "permitted oversized RX completion length was rejected by unpack")
        if (!desc.is_complete(1'b1))
            `uvm_fatal("CMDQ_USED", "USED completion was not detected")
        if (desc.parse_completion())
            `uvm_fatal("CMDQ_RX_LEN", "257-byte completion result was accepted")
        if (desc.completion_event.is_on())
            `uvm_fatal("CMDQ_EVENT",
                "invalid completion triggered the persistent event")
        if (desc.result.size() != 0)
            `uvm_fatal("CMDQ_RESULT",
                "invalid completion produced result bytes")

        copy_bytes(submitted, completion);
        completion[0]  = byte'(CMDQ_DESC_AVAIL | CMDQ_DESC_USED);
        completion[1]  = 8'h00;
        completion[14] = 8'h05;
        completion[15] = 8'h00;
        result_bytes = new[5];
        result_bytes[0] = 8'h10;
        result_bytes[1] = 8'h20;
        result_bytes[2] = 8'h30;
        result_bytes[3] = 8'h40;
        result_bytes[4] = 8'h50;
        mem.write_mem(desc.rx_buf_addr, result_bytes, `__FILE__, `__LINE__);
        if (!desc.unpack(completion))
            `uvm_fatal("CMDQ_COMPLETION", "valid completion was rejected")
        if (!desc.is_complete(1'b0))
            `uvm_fatal("CMDQ_COMPLETION", "valid USED completion was not detected")
        if (!desc.parse_completion())
            `uvm_fatal("CMDQ_COMPLETION", "valid result parse failed")
        expect_bytes_equal("copied completion result", desc.result, result_bytes);
        if (!desc.completion_event.is_on())
            `uvm_fatal("CMDQ_EVENT", "completion event was not persistent")

        desc.release_owned();
        desc.release_owned();
        expect_bytes_equal("released completion result", desc.result, result_bytes);
        if (!desc.completion_event.is_on())
            `uvm_fatal("CMDQ_EVENT",
                "completion event did not survive buffer release")
    endfunction

    function void build_phase(uvm_phase phase);
        host_mem_manager mem;
        cmdq_tx_desc desc;
        byte submitted[];

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h1000_0000, 64'h1000_ffff,
                        MODE_LINEAR, 16);

        check_layout_and_buffers(mem, desc, submitted);
        check_prepare_rejections(mem);
        check_allocation_rollback();
        check_stable_fields(desc, submitted);
        check_completion(mem, desc, submitted);
        mem.leak_check(`__FILE__, `__LINE__);
    endfunction
endclass

`endif
