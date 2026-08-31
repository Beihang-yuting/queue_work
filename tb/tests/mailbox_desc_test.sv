`ifndef MAILBOX_DESC_TEST_SV
`define MAILBOX_DESC_TEST_SV

class mailbox_desc_test extends uvm_test;
    `uvm_component_utils(mailbox_desc_test)

    function new(string name = "mailbox_desc_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void expect_byte(string field_name, byte actual, byte expected);
        if (actual !== expected)
            `uvm_fatal("DESC_BYTE", $sformatf("%s: got 0x%02h expected 0x%02h",
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
            `uvm_fatal("DESC_STATE", $sformatf("%s size changed", check_name))
        foreach (expected[i]) begin
            if (actual[i] !== expected[i])
                `uvm_fatal("DESC_STATE", $sformatf("%s byte %0d changed", check_name, i))
        end
    endfunction

    function void build_phase(uvm_phase phase);
        host_mem_manager mem;
        host_mem_manager owner_mem;
        host_mem_manager other_mem;
        mailbox_tx_desc tx;
        mailbox_tx_desc tx_copy;
        mailbox_tx_desc tx_zero;
        mailbox_tx_desc tx_invalid;
        mailbox_tx_desc tx_rebind;
        mailbox_rx_desc rx;
        mailbox_rx_desc rx_copy;
        mailbox_rx_desc rx_zero;
        mailbox_rx_desc rx_null_rebind;
        byte tx_bytes[];
        byte rx_bytes[];
        byte wrong_tx_bytes[];
        byte wrong_rx_bytes[];
        byte malformed_tx_bytes[];
        byte malformed_rx_bytes[];
        byte state_before[];
        byte state_after[];
        byte external_read[];
        byte rx_expected[];
        gq_addr_t prepared_addr;

        super.build_phase(phase);

        mem = new("mem");
        mem.init_region(64'h1000_0000, 64'h10ff_ffff, MODE_LINEAR, 16);

        tx = mailbox_tx_desc::type_id::create("tx");
        tx.flags       = 16'h0000;
        tx.srcid       = 16'h1122;
        tx.dstid       = 16'h3344;
        tx.msg_type    = 16'h5566;
        tx.buf_len     = 16'h0004;
        tx.data_len    = 16'h0003;
        tx.data[0]     = 8'haa;
        tx.data[1]     = 8'hbb;
        tx.data[2]     = 8'hcc;
        tx.attach_mem(mem);
        if (!tx.prepare())
            `uvm_fatal("TX_PREP", "TX descriptor preparation failed")
        if (tx.external_data.size() != 4)
            `uvm_fatal("TX_EXT", "TX external data length is not exactly buf_len")

        tx.mark_available(1'b1);
        tx.pack(tx_bytes);
        if (tx_bytes.size() != 64)
            `uvm_fatal("TX_SIZE", $sformatf("got %0d expected 64", tx_bytes.size()))

        expect_byte("tx.flags[7:0]",  tx_bytes[0], 8'h01);
        expect_byte("tx.flags[15:8]", tx_bytes[1], 8'h00);
        expect_byte("tx.srcid[7:0]",  tx_bytes[2], 8'h22);
        expect_byte("tx.srcid[15:8]", tx_bytes[3], 8'h11);
        expect_byte("tx.dstid[7:0]",  tx_bytes[4], 8'h44);
        expect_byte("tx.dstid[15:8]", tx_bytes[5], 8'h33);
        expect_byte("tx.type[7:0]",   tx_bytes[6], 8'h66);
        expect_byte("tx.type[15:8]",  tx_bytes[7], 8'h55);
        for (int unsigned i = 0; i < 8; i++)
            expect_byte($sformatf("tx.buf_addr[%0d]", i), tx_bytes[8+i],
                        byte'(tx.buf_addr >> (8*i)));
        expect_byte("tx.buf_len[7:0]",   tx_bytes[16], 8'h04);
        expect_byte("tx.buf_len[15:8]",  tx_bytes[17], 8'h00);
        expect_byte("tx.data_len[7:0]",  tx_bytes[18], 8'h03);
        expect_byte("tx.data_len[15:8]", tx_bytes[19], 8'h00);
        expect_byte("tx.data[0]", tx_bytes[20], 8'haa);
        expect_byte("tx.data[1]", tx_bytes[21], 8'hbb);
        expect_byte("tx.data[2]", tx_bytes[22], 8'hcc);

        mem.read_mem(tx.buf_addr, tx.buf_len, external_read, `__FILE__, `__LINE__);
        if (external_read.size() != 4)
            `uvm_fatal("TX_EXT", "external buffer read length mismatch")
        foreach (external_read[i]) begin
            if (external_read[i] !== tx.external_data[i])
                `uvm_fatal("TX_EXT", $sformatf("external byte %0d mismatch", i))
        end

        tx_copy = mailbox_tx_desc::type_id::create("tx_copy");
        if (!tx_copy.unpack(tx_bytes))
            `uvm_fatal("TX_UNPACK", "valid TX descriptor rejected")
        if (tx_copy.flags != tx.flags || tx_copy.srcid != tx.srcid ||
            tx_copy.dstid != tx.dstid || tx_copy.msg_type != tx.msg_type ||
            tx_copy.buf_addr != tx.buf_addr || tx_copy.buf_len != tx.buf_len ||
            tx_copy.data_len != tx.data_len)
            `uvm_fatal("TX_ROUNDTRIP", "TX scalar round trip mismatch")
        for (int unsigned i = 0; i < 44; i++) begin
            if (tx_copy.data[i] !== tx.data[i])
                `uvm_fatal("TX_ROUNDTRIP", $sformatf("TX inline byte %0d mismatch", i))
        end

        tx_copy.pack(state_before);
        copy_bytes(tx_bytes, malformed_tx_bytes);
        malformed_tx_bytes[18] = 8'd45;
        malformed_tx_bytes[19] = 8'd0;
        if (tx_copy.unpack(malformed_tx_bytes))
            `uvm_fatal("TX_TRANSACTION", "same-size TX with data_len above 44 accepted")
        tx_copy.pack(state_after);
        expect_bytes_equal("semantic TX rejection", state_after, state_before);

        tx.pack(state_before);
        copy_bytes(tx_bytes, malformed_tx_bytes);
        malformed_tx_bytes[0]  = 8'h03;
        malformed_tx_bytes[16] = 8'h00;
        malformed_tx_bytes[17] = 8'h00;
        if (tx.unpack(malformed_tx_bytes))
            `uvm_fatal("TX_OWNERSHIP", "TX writeback with changed length accepted")
        tx.pack(state_after);
        expect_bytes_equal("owned TX length rejection", state_after, state_before);

        copy_bytes(tx_bytes, malformed_tx_bytes);
        malformed_tx_bytes[0] = 8'h03;
        malformed_tx_bytes[8] = malformed_tx_bytes[8] ^ 8'h10;
        if (tx.unpack(malformed_tx_bytes))
            `uvm_fatal("TX_OWNERSHIP", "TX writeback with changed address accepted")
        tx.pack(state_after);
        expect_bytes_equal("owned TX address rejection", state_after, state_before);

        copy_bytes(tx_bytes, malformed_tx_bytes);
        malformed_tx_bytes[0] = 8'h03;
        if (!tx.unpack(malformed_tx_bytes))
            `uvm_fatal("TX_WRITEBACK", "legitimate TX flag writeback rejected")
        if (tx.flags != 16'h0003 || tx.buf_addr != 64'h1000_0000 || tx.buf_len != 4)
            `uvm_fatal("TX_WRITEBACK", "legitimate TX writeback corrupted prepared state")

        prepared_addr = tx.buf_addr;
        if (tx.prepare())
            `uvm_fatal("TX_REPEAT", "repeated TX prepare unexpectedly succeeded")
        if (tx.buf_addr != prepared_addr || tx.external_data.size() != 4)
            `uvm_fatal("TX_REPEAT", "repeated TX prepare changed owned-buffer state")

        if (tx_copy.is_complete(1'b1))
            `uvm_fatal("TX_PHASE", "phase-one descriptor completed before used writeback")
        tx_copy.flags[1] = 1'b1;
        if (!tx_copy.is_complete(1'b1))
            `uvm_fatal("TX_PHASE", "phase-one completion not detected")
        tx_copy.mark_available(1'b0);
        if (tx_copy.flags != 16'h0001 || tx_copy.is_complete(1'b0))
            `uvm_fatal("TX_OWNERSHIP",
                       "second-lap TX must publish with AVAIL=1 and USED=0")
        tx_copy.flags[1] = 1'b1;
        if (!tx_copy.is_complete(1'b0))
            `uvm_fatal("TX_OWNERSHIP",
                       "second-lap TX completion must use fixed USED=1")

        wrong_tx_bytes = new[63];
        tx_copy.srcid = 16'hbeef;
        if (tx_copy.unpack(wrong_tx_bytes))
            `uvm_fatal("TX_LENGTH", "wrong-length TX descriptor accepted")
        if (tx_copy.srcid != 16'hbeef)
            `uvm_fatal("TX_LENGTH", "wrong-length TX unpack modified the object")

        tx_invalid = mailbox_tx_desc::type_id::create("tx_invalid");
        tx_invalid.data_len = 16'd45;
        tx_invalid.attach_mem(mem);
        if (tx_invalid.prepare())
            `uvm_fatal("TX_DATA_LEN", "data_len above 44 accepted")

        tx_zero = mailbox_tx_desc::type_id::create("tx_zero");
        tx_zero.buf_len = 0;
        tx_zero.attach_mem(mem);
        if (!tx_zero.prepare() || tx_zero.buf_addr != 0 ||
            tx_zero.external_data.size() != 0)
            `uvm_fatal("TX_ZERO", "zero-length TX buffer behavior is incorrect")

        rx = mailbox_rx_desc::type_id::create("rx");
        rx.flags   = 16'h0000;
        rx.buf_len = 32'h0000_0100;
        rx.attach_mem(mem);
        if (!rx.prepare())
            `uvm_fatal("RX_PREP", "RX descriptor preparation failed")
        rx.mark_available(1'b1);
        rx.pack(rx_bytes);
        if (rx_bytes.size() != 16)
            `uvm_fatal("RX_SIZE", $sformatf("got %0d expected 16", rx_bytes.size()))

        expect_byte("rx.flags[7:0]",  rx_bytes[0], 8'h01);
        expect_byte("rx.flags[15:8]", rx_bytes[1], 8'h00);
        expect_byte("rx.reserved[7:0]",  rx_bytes[2], 8'h00);
        expect_byte("rx.reserved[15:8]", rx_bytes[3], 8'h00);
        expect_byte("rx.buf_len[7:0]",   rx_bytes[4], 8'h00);
        expect_byte("rx.buf_len[15:8]",  rx_bytes[5], 8'h01);
        expect_byte("rx.buf_len[23:16]", rx_bytes[6], 8'h00);
        expect_byte("rx.buf_len[31:24]", rx_bytes[7], 8'h00);
        for (int unsigned i = 0; i < 8; i++)
            expect_byte($sformatf("rx.buf_addr[%0d]", i), rx_bytes[8+i],
                        byte'(rx.buf_addr >> (8*i)));

        rx.pack(state_before);
        copy_bytes(rx_bytes, malformed_rx_bytes);
        malformed_rx_bytes[0] = 8'h03;
        malformed_rx_bytes[4] = 8'h00;
        malformed_rx_bytes[5] = 8'h00;
        if (rx.unpack(malformed_rx_bytes))
            `uvm_fatal("RX_OWNERSHIP", "RX writeback with zero length accepted")
        rx.pack(state_after);
        expect_bytes_equal("owned RX zero-length rejection", state_after, state_before);

        copy_bytes(rx_bytes, malformed_rx_bytes);
        malformed_rx_bytes[0] = 8'h03;
        malformed_rx_bytes[4] = 8'h80;
        malformed_rx_bytes[5] = 8'h00;
        if (rx.unpack(malformed_rx_bytes))
            `uvm_fatal("RX_OWNERSHIP", "RX writeback with changed length accepted")
        rx.pack(state_after);
        expect_bytes_equal("owned RX changed-length rejection", state_after, state_before);

        copy_bytes(rx_bytes, malformed_rx_bytes);
        malformed_rx_bytes[0] = 8'h03;
        malformed_rx_bytes[8] = malformed_rx_bytes[8] ^ 8'h10;
        if (rx.unpack(malformed_rx_bytes))
            `uvm_fatal("RX_OWNERSHIP", "RX writeback with changed address accepted")
        rx.pack(state_after);
        expect_bytes_equal("owned RX address rejection", state_after, state_before);

        copy_bytes(rx_bytes, malformed_rx_bytes);
        malformed_rx_bytes[0] = 8'h03;
        if (!rx.unpack(malformed_rx_bytes))
            `uvm_fatal("RX_WRITEBACK", "legitimate RX flag writeback rejected")
        if (rx.flags != 16'h0003 || rx.buf_addr != 64'h1000_0010 ||
            rx.buf_len != 32'h100)
            `uvm_fatal("RX_WRITEBACK", "legitimate RX writeback corrupted prepared state")

        prepared_addr = rx.buf_addr;
        if (rx.prepare())
            `uvm_fatal("RX_REPEAT", "repeated RX prepare unexpectedly succeeded")
        if (rx.buf_addr != prepared_addr)
            `uvm_fatal("RX_REPEAT", "repeated RX prepare changed owned-buffer state")

        rx_copy = mailbox_rx_desc::type_id::create("rx_copy");
        if (!rx_copy.unpack(rx_bytes))
            `uvm_fatal("RX_UNPACK", "valid RX descriptor rejected")
        if (rx_copy.flags != 16'h0001 || rx_copy.buf_len != rx.buf_len ||
            rx_copy.buf_addr != rx.buf_addr)
            `uvm_fatal("RX_ROUNDTRIP", "RX round trip mismatch")

        if (rx_copy.is_complete(1'b1))
            `uvm_fatal("RX_PHASE", "phase-one descriptor completed before used writeback")
        rx_copy.flags[1] = 1'b1;
        if (!rx_copy.is_complete(1'b1))
            `uvm_fatal("RX_PHASE", "phase-one completion not detected")
        rx_copy.mark_available(1'b0);
        if (rx_copy.flags != 16'h0001 || rx_copy.is_complete(1'b0))
            `uvm_fatal("RX_OWNERSHIP",
                       "second-lap RX must publish with AVAIL=1 and USED=0")
        rx_copy.flags[1] = 1'b1;
        if (!rx_copy.is_complete(1'b0))
            `uvm_fatal("RX_OWNERSHIP",
                       "second-lap RX completion must use fixed USED=1")

        rx_expected = new[rx.buf_len];
        foreach (rx_expected[i])
            rx_expected[i] = byte'(i ^ 8'h5a);
        mem.write_mem(rx.buf_addr, rx_expected, `__FILE__, `__LINE__);
        rx.set_mem(null);
        if (!rx.parse_completion())
            `uvm_fatal("RX_PARSE", "RX completion parse failed")
        if (rx.rx_data.size() != rx_expected.size())
            `uvm_fatal("RX_PARSE", "RX completion data length mismatch")
        foreach (rx_expected[i]) begin
            if (rx.rx_data[i] !== rx_expected[i])
                `uvm_fatal("RX_PARSE", $sformatf("RX byte %0d mismatch", i))
        end

        wrong_rx_bytes = new[15];
        rx_copy.buf_len = 32'hdead_beef;
        if (rx_copy.unpack(wrong_rx_bytes))
            `uvm_fatal("RX_LENGTH", "wrong-length RX descriptor accepted")
        if (rx_copy.buf_len != 32'hdead_beef)
            `uvm_fatal("RX_LENGTH", "wrong-length RX unpack modified the object")

        rx_zero = mailbox_rx_desc::type_id::create("rx_zero");
        rx_zero.buf_len = 0;
        rx_zero.attach_mem(mem);
        if (!rx_zero.prepare() || rx_zero.buf_addr != 0)
            `uvm_fatal("RX_ZERO", "zero-length RX buffer behavior is incorrect")
        if (!rx_zero.parse_completion() || rx_zero.rx_data.size() != 0)
            `uvm_fatal("RX_ZERO", "zero-length RX completion behavior is incorrect")

        owner_mem = new("owner_mem");
        owner_mem.init_region(64'h3000_0000, 64'h3000_ffff, MODE_LINEAR, 16);
        other_mem = new("other_mem");
        other_mem.init_region(64'h4000_0000, 64'h4000_ffff, MODE_LINEAR, 16);

        tx_rebind = mailbox_tx_desc::type_id::create("tx_rebind");
        tx_rebind.buf_len = 16;
        tx_rebind.attach_mem(owner_mem);
        if (!tx_rebind.prepare())
            `uvm_fatal("OWNER_REBIND", "rebind TX prepare failed")
        tx_rebind.attach_mem(other_mem);
        tx_rebind.release_owned();
        tx_rebind.release_owned();
        owner_mem.leak_check(`__FILE__, `__LINE__);
        other_mem.leak_check(`__FILE__, `__LINE__);

        rx_null_rebind = mailbox_rx_desc::type_id::create("rx_null_rebind");
        rx_null_rebind.buf_len = 16;
        rx_null_rebind.attach_mem(owner_mem);
        if (!rx_null_rebind.prepare())
            `uvm_fatal("OWNER_NULL", "null-rebind RX prepare failed")
        rx_null_rebind.set_mem(null);
        if (rx_null_rebind.alloc_owned(16) != '1)
            `uvm_fatal("OWNER_NULL", "allocation with a null memory handle succeeded")
        rx_null_rebind.release_owned();
        rx_null_rebind.release_owned();
        owner_mem.leak_check(`__FILE__, `__LINE__);
        other_mem.leak_check(`__FILE__, `__LINE__);

        tx.release_owned();
        tx.release_owned();
        tx_zero.release_owned();
        tx_zero.release_owned();
        rx.release_owned();
        rx.release_owned();
        rx_zero.release_owned();
        rx_zero.release_owned();
        mem.leak_check(`__FILE__, `__LINE__);
    endfunction
endclass

`endif
