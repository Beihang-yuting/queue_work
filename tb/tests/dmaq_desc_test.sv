`ifndef DMAQ_DESC_TEST_SV
`define DMAQ_DESC_TEST_SV

class dmaq_desc_test extends uvm_test;
    `uvm_component_utils(dmaq_desc_test)

    function new(string name = "dmaq_desc_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function dmaq_endpoint_t endpoint(dmaq_endpoint_role_e role,
                                      gq_addr_t address,
                                      bit [15:0] host_id,
                                      bit [15:0] bdf_raw);
        dmaq_endpoint_t value;

        value.role = role;
        value.address = address;
        value.host_id = host_id;
        value.bdf_raw = bdf_raw;
        return value;
    endfunction

    function void copy_bytes(input byte source[], ref byte destination[]);
        destination = new[source.size()];
        foreach (source[i])
            destination[i] = source[i];
    endfunction

    function void expect_bytes(string check_name, input byte actual[],
                               input byte expected[]);
        if (actual.size() != expected.size())
            `uvm_fatal("DMAQ_BYTES", $sformatf(
                "%s: got size %0d expected %0d", check_name,
                actual.size(), expected.size()))
        foreach (expected[i]) begin
            if (actual[i] !== expected[i])
                `uvm_fatal("DMAQ_BYTES", $sformatf(
                    "%s: byte %0d got 0x%02h expected 0x%02h",
                    check_name, i, actual[i], expected[i]))
        end
    endfunction

    function dmaq_tx_desc make_desc(string name, dmaq_operation_e operation,
                                     dmaq_endpoint_t source,
                                     dmaq_endpoint_t destination,
                                     int unsigned transfer_length);
        dmaq_tx_desc desc;

        desc = dmaq_tx_desc::type_id::create(name);
        desc.operation = operation;
        desc.source = source;
        desc.destination = destination;
        desc.transfer_length = transfer_length;
        return desc;
    endfunction

    function void check_defaults_and_bdf();
        if (DMAQ_DEFAULT_DEPTH != 32 ||
            DMAQ_DEFAULT_INITIAL_LOGICAL_SEQ != 31 ||
            DMAQ_DESC_BYTES != 32 ||
            DMAQ_DEFAULT_POLL_INTERVAL != 10ns ||
            DMAQ_DEFAULT_COMPLETION_TIMEOUT != 500ns)
            `uvm_fatal("DMAQ_CONSTANTS", "DMAQ public defaults diverged")

        if (dmaq_ep_bdf(4'ha, 8'hbc, 1'b1) != 16'h1bca ||
            dmaq_ep_bdf(4'h3, 8'h25, 1'b0) != 16'h0253 ||
            dmaq_switch_bdf(16'hd4e5) != 16'hd4e5)
            `uvm_fatal("DMAQ_BDF", "BDF helper encoding diverged")
    endfunction

    function void check_vector(string check_name, dmaq_operation_e operation,
                               dmaq_endpoint_t source,
                               dmaq_endpoint_t destination,
                               int unsigned transfer_length,
                               input byte expected[]);
        dmaq_tx_desc desc;
        byte packed_data[];

        desc = make_desc({check_name, "_desc"}, operation, source,
                         destination, transfer_length);
        if (!desc.prepare())
            `uvm_fatal("DMAQ_PREP", {check_name, " preparation failed"})
        desc.mark_available(1'b1);
        desc.pack(packed_data);
        if (packed_data.size() != DMAQ_DESC_BYTES)
            `uvm_fatal("DMAQ_SIZE", $sformatf(
                "%s: got %0d descriptor bytes expected 32", check_name,
                packed_data.size()))
        expect_bytes(check_name, packed_data, expected);
        if (desc.owned_allocation_count() != 0)
            `uvm_fatal("DMAQ_OWNER", {check_name,
                " descriptor allocated a business buffer"})
    endfunction

    function void check_vectors();
        byte expected_af_to_host[] = '{
            8'h01,8'h00, 8'hee,8'hdd, 8'hcc,8'hbb, 8'h34,8'h12,
            8'h11,8'h22,8'h33,8'h44,8'h55,8'h66,8'h77,8'h88,
            8'h88,8'h77,8'h66,8'h55,8'h44,8'h33,8'h22,8'h11,
            8'hca,8'h1b, 8'haa,8'h99, 8'h34,8'h12, 8'h00,8'h00};
        byte expected_host_to_af[] = '{
            8'h01,8'h00, 8'h55,8'h66, 8'h77,8'h88, 8'h01,8'h00,
            8'h80,8'h70,8'h60,8'h50,8'h40,8'h30,8'h20,8'h10,
            8'h08,8'h07,8'h06,8'h05,8'h04,8'h03,8'h02,8'h01,
            8'h11,8'h22, 8'h33,8'h44, 8'h01,8'h00, 8'h00,8'h00};
        byte expected_host_to_host[] = '{
            8'h01,8'h00, 8'h68,8'h24, 8'hef,8'hbe, 8'hff,8'hff,
            8'h78,8'h69,8'h5a,8'h4b,8'h3c,8'h2d,8'h1e,8'h0f,
            8'h80,8'h90,8'ha0,8'hb0,8'hc0,8'hd0,8'he0,8'hf0,
            8'hcd,8'hab, 8'h57,8'h13, 8'hff,8'hff, 8'h00,8'h00};

        check_vector("AF-to-Host", DMAQ_AF_TO_HOST,
            endpoint(DMAQ_ENDPOINT_AF, 64'h1122334455667788, 16'h99aa,
                     16'h1bca),
            endpoint(DMAQ_ENDPOINT_HOST, 64'h8877665544332211, 16'hbbcc,
                     16'hddee), 16'h1234, expected_af_to_host);
        check_vector("Host-to-AF", DMAQ_HOST_TO_AF,
            endpoint(DMAQ_ENDPOINT_HOST, 64'h0102030405060708, 16'h4433,
                     16'h2211),
            endpoint(DMAQ_ENDPOINT_AF, 64'h1020304050607080, 16'h8877,
                     16'h6655), 1, expected_host_to_af);
        check_vector("Host-to-Host", DMAQ_HOST_TO_HOST,
            endpoint(DMAQ_ENDPOINT_HOST, 64'hf0e0d0c0b0a09080, 16'h1357,
                     16'habcd),
            endpoint(DMAQ_ENDPOINT_HOST, 64'h0f1e2d3c4b5a6978, 16'hbeef,
                     16'h2468), 65535, expected_host_to_host);
    endfunction

    function void check_prepare_rejections();
        dmaq_tx_desc desc;
        dmaq_endpoint_t af;
        dmaq_endpoint_t host;

        af = endpoint(DMAQ_ENDPOINT_AF, 64'h1, 16'h2, 16'h3);
        host = endpoint(DMAQ_ENDPOINT_HOST, 64'h4, 16'h5, 16'h6);
        desc = make_desc("wrong_roles", DMAQ_AF_TO_HOST, host, af, 1);
        if (desc.prepare())
            `uvm_fatal("DMAQ_ROLE", "AF-to-Host accepted reversed roles")
        desc = make_desc("host_to_af_roles", DMAQ_HOST_TO_AF, af, host, 1);
        if (desc.prepare())
            `uvm_fatal("DMAQ_ROLE", "Host-to-AF accepted AF-to-Host roles")
        desc = make_desc("host_to_host_roles", DMAQ_HOST_TO_HOST, af, host,
                         1);
        if (desc.prepare())
            `uvm_fatal("DMAQ_ROLE", "Host-to-Host accepted an AF endpoint")
        desc = make_desc("zero_length", DMAQ_AF_TO_HOST, af, host, 0);
        if (desc.prepare())
            `uvm_fatal("DMAQ_LENGTH", "zero transfer length was accepted")
        desc = make_desc("large_length", DMAQ_AF_TO_HOST, af, host, 65536);
        if (desc.prepare())
            `uvm_fatal("DMAQ_LENGTH", "65536-byte transfer length was accepted")
        desc = make_desc("one_shot", DMAQ_AF_TO_HOST, af, host, 1);
        if (!desc.prepare())
            `uvm_fatal("DMAQ_PREP", "initial one-byte preparation failed")
        if (desc.prepare())
            `uvm_fatal("DMAQ_ONE_SHOT", "second prepare was accepted")
    endfunction

    function void expect_stable_rejection(dmaq_tx_desc desc, byte submitted[],
                                          int unsigned offset,
                                          string field_name);
        byte corrupted[];
        byte after[];

        copy_bytes(submitted, corrupted);
        corrupted[offset] = corrupted[offset] ^ 8'h01;
        if (desc.unpack(corrupted))
            `uvm_fatal("DMAQ_STABLE", {field_name, " corruption was accepted"})
        desc.pack(after);
        expect_bytes({field_name, " rejection preserves descriptor"}, after,
                     submitted);
    endfunction

    function void check_writeback();
        dmaq_tx_desc desc;
        dmaq_endpoint_t source;
        dmaq_endpoint_t destination;
        byte submitted[];
        byte after_mutation[];
        byte completion[];

        source = endpoint(DMAQ_ENDPOINT_AF, 64'h1122334455667788, 16'h99aa,
                          16'h1bca);
        destination = endpoint(DMAQ_ENDPOINT_HOST, 64'h8877665544332211,
                               16'hbbcc, 16'hddee);
        desc = make_desc("writeback", DMAQ_AF_TO_HOST, source, destination,
                         16'h1234);
        if (!desc.prepare())
            `uvm_fatal("DMAQ_PREP", "writeback preparation failed")
        desc.mark_available(1'b0);
        desc.pack(submitted);
        desc.destination.bdf_raw = 16'h0000;
        desc.destination.host_id = 16'h0000;
        desc.destination.address = 64'h0;
        desc.source.bdf_raw = 16'h0000;
        desc.source.host_id = 16'h0000;
        desc.source.address = 64'h0;
        desc.transfer_length = 1;
        desc.pack(after_mutation);
        expect_bytes("caller metadata mutation preserves snapshot",
                     after_mutation, submitted);

        expect_stable_rejection(desc, submitted, 2, "destination BDF");
        expect_stable_rejection(desc, submitted, 4, "destination host ID");
        expect_stable_rejection(desc, submitted, 6, "destination length");
        expect_stable_rejection(desc, submitted, 8, "destination address");
        expect_stable_rejection(desc, submitted, 16, "source address");
        expect_stable_rejection(desc, submitted, 24, "source BDF");
        expect_stable_rejection(desc, submitted, 26, "source host ID");
        expect_stable_rejection(desc, submitted, 28, "source length");
        expect_stable_rejection(desc, submitted, 30, "reserved");

        copy_bytes(submitted, completion);
        completion[0] = byte'(DMAQ_DESC_AVAIL | DMAQ_DESC_USED);
        completion[1] = 8'h00;
        if (!desc.unpack(completion))
            `uvm_fatal("DMAQ_FLAGS", "flags-only completion was rejected")
        if (!desc.is_complete(1'b0))
            `uvm_fatal("DMAQ_USED", "USED completion was not detected")
        if (!desc.parse_completion())
            `uvm_fatal("DMAQ_COMPLETE", "valid USED completion was not parsed")
        if (!desc.completion_event.is_on())
            `uvm_fatal("DMAQ_EVENT", "completion event was not persistent")
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        check_defaults_and_bdf();
        check_vectors();
        check_prepare_rejections();
        check_writeback();
    endfunction
endclass

`endif
