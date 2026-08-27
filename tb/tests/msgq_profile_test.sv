`ifndef MSGQ_PROFILE_TEST_SV
`define MSGQ_PROFILE_TEST_SV

class msgq_profile_test extends uvm_test;
    `uvm_component_utils(msgq_profile_test)

    function new(string name = "msgq_profile_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        msgq_kind_e kinds[$] = '{MSGQ_MAC_AGE, MSGQ_1588, MSGQ_FSE,
                                 MSGQ_IACL, MSGQ_EACL, MSGQ_VDPA,
                                 MSGQ_NOTIFY};
        msgq_format_profile_e profile = MSGQ_PROFILE_EMP_ACTIVE;
        msgq_raw_entry entry;
        byte packed_data[];
        byte expected[] = '{8'h12, 8'h34, 8'h56, 8'h78};
        byte wrong_size[] = '{8'haa, 8'hbb, 8'hcc};

        super.build_phase(phase);

        if (kinds.size() != 7 ||
            kinds[0] != MSGQ_MAC_AGE || kinds[1] != MSGQ_1588 ||
            kinds[2] != MSGQ_FSE || kinds[3] != MSGQ_IACL ||
            kinds[4] != MSGQ_EACL || kinds[5] != MSGQ_VDPA ||
            kinds[6] != MSGQ_NOTIFY)
            `uvm_fatal("MSGQ_KIND", "MSGQ kind enumeration is incomplete")
        if (profile != MSGQ_PROFILE_EMP_ACTIVE ||
            MSGQ_PROFILE_EMP_ACTIVE == MSGQ_PROFILE_LINUX_HEADER)
            `uvm_fatal("MSGQ_PROFILE", "MSGQ format profiles are not distinct")
        if (MSGQ_MAC_AGE_DEPTH != 128 || MSGQ_MAC_AGE_ENTRY_BYTES != 16 ||
            MSGQ_1588_EMP_DEPTH != 32 || MSGQ_1588_LINUX_DEPTH != 128 ||
            MSGQ_1588_ENTRY_BYTES != 8)
            `uvm_fatal("MSGQ_CONSTANT", "MSGQ geometry constants changed")

        entry = msgq_raw_entry::type_id::create("entry");
        entry.set_entry_size(4);
        entry.pack(packed_data);
        if (packed_data.size() != 4)
            `uvm_fatal("MSGQ_PACK", "pack returned the wrong entry size")
        foreach (packed_data[i]) begin
            if (packed_data[i] !== 8'h00)
                `uvm_fatal("MSGQ_PACK", "pack did not clear the entry slot")
        end

        if (!entry.unpack(expected))
            `uvm_fatal("MSGQ_RAW", "unpack rejected exact-size entry")
        if (entry.raw_bytes != expected)
            `uvm_fatal("MSGQ_RAW", "raw entry bytes changed")
        if (entry.unpack(wrong_size))
            `uvm_fatal("MSGQ_SIZE", "wrong-size raw entry accepted")
        if (entry.raw_bytes != expected)
            `uvm_fatal("MSGQ_SIZE", "rejected unpack changed raw entry bytes")
        if (!entry.is_complete(1'b0) || !entry.is_complete(1'b1))
            `uvm_fatal("MSGQ_COMPLETE", "selected raw entry is not complete")
        if (!entry.parse_completion())
            `uvm_fatal("MSGQ_PARSE", "raw entry completion parse failed")
        if (entry.owned_allocation_count() != 0)
            `uvm_fatal("MSGQ_OWNERSHIP", "raw entry unexpectedly owns memory")
    endfunction
endclass

`endif
