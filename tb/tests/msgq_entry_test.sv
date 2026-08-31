`ifndef MSGQ_ENTRY_TEST_SV
`define MSGQ_ENTRY_TEST_SV

class msgq_entry_test extends uvm_test;
    `uvm_component_utils(msgq_entry_test)

    function new(string name = "msgq_entry_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void check_mac_age();
        msgq_mac_age_entry entry;
        byte valid[] = '{8'hef, 8'hcd, 8'hab, 8'h89,
                         8'h67, 8'h45, 8'h23, 8'h01,
                         8'h55, 8'h01, 8'h00, 8'h00,
                         8'h00, 8'h00, 8'h00, 8'h00};
        byte dword1_reserved[] = '{8'hef, 8'hcd, 8'hab, 8'h89,
                                   8'h67, 8'h45, 8'h23, 8'he1,
                                   8'h55, 8'h01, 8'h00, 8'h00,
                                   8'h00, 8'h00, 8'h00, 8'h00};
        byte dword2_reserved[] = '{8'hef, 8'hcd, 8'hab, 8'h89,
                                   8'h67, 8'h45, 8'h23, 8'h01,
                                   8'h55, 8'h03, 8'h00, 8'h00,
                                   8'h00, 8'h00, 8'h00, 8'h00};
        byte dword3_reserved[] = '{8'hef, 8'hcd, 8'hab, 8'h89,
                                   8'h67, 8'h45, 8'h23, 8'h01,
                                   8'h55, 8'h01, 8'h00, 8'h00,
                                   8'h01, 8'h00, 8'h00, 8'h00};

        entry = new("mac_age_entry");
        if (!entry.unpack(valid))
            `uvm_fatal("MSGQ_MAC_UNPACK", "MAC-age vector was rejected")
        if (entry.raw_bytes != valid)
            `uvm_fatal("MSGQ_MAC_RAW", "unpack changed MAC-age bytes")
        if (!entry.parse_completion())
            `uvm_fatal("MSGQ_MAC_PARSE", "valid MAC-age vector was rejected")
        if (entry.hash_key_l != 32'h89ab_cdef ||
            entry.hash_key_h != 29'h0123_4567 ||
            entry.mac_act_idx != 9'h155)
            `uvm_fatal("MSGQ_MAC_FIELDS", "MAC-age fields decoded incorrectly")

        if (!entry.unpack(dword1_reserved))
            `uvm_fatal("MSGQ_MAC_RSV1_RAW", "reserved MAC-age bytes were not captured")
        if (entry.parse_completion())
            `uvm_fatal("MSGQ_MAC_RSV1", "DWORD1 reserved bits were accepted")
        if (entry.raw_bytes != dword1_reserved)
            `uvm_fatal("MSGQ_MAC_RSV1_RAW", "strict rejection discarded raw bytes")
        entry.strict_reserved = 0;
        if (!entry.parse_completion())
            `uvm_fatal("MSGQ_MAC_LOOSE", "non-strict MAC-age parse was rejected")
        if (entry.raw_bytes != dword1_reserved ||
            entry.hash_key_l != 32'h89ab_cdef ||
            entry.hash_key_h != 29'h0123_4567 ||
            entry.mac_act_idx != 9'h155)
            `uvm_fatal("MSGQ_MAC_LOOSE", "non-strict parse lost raw or decoded fields")

        entry.strict_reserved = 1;
        if (!entry.unpack(dword2_reserved) || entry.parse_completion())
            `uvm_fatal("MSGQ_MAC_RSV2", "DWORD2 reserved bits were accepted")
        if (entry.raw_bytes != dword2_reserved)
            `uvm_fatal("MSGQ_MAC_RSV2_RAW", "DWORD2 rejection discarded raw bytes")
        if (!entry.unpack(dword3_reserved) || entry.parse_completion())
            `uvm_fatal("MSGQ_MAC_RSV3", "DWORD3 reserved bits were accepted")
        if (entry.raw_bytes != dword3_reserved)
            `uvm_fatal("MSGQ_MAC_RSV3_RAW", "DWORD3 rejection discarded raw bytes")
    endfunction

    function void check_1588();
        msgq_1588_entry emp_entry;
        msgq_1588_entry linux_entry;
        byte emp_valid[] = '{8'h78, 8'h56, 8'h34, 8'h12,
                             8'h5a, 8'hef, 8'hbe, 8'h2a};
        byte linux_valid[] = '{8'h78, 8'h56, 8'h34, 8'h12,
                               8'h5a, 8'hef, 8'hbe, 8'h0a};
        byte final_reserved[] = '{8'h78, 8'h56, 8'h34, 8'h12,
                                  8'h5a, 8'hef, 8'hbe, 8'hca};

        emp_entry = new("emp_entry", MSGQ_PROFILE_EMP_ACTIVE);
        if (!emp_entry.unpack(emp_valid))
            `uvm_fatal("MSGQ_1588_UNPACK", "EMP vector was rejected")
        if (emp_entry.raw_bytes != emp_valid)
            `uvm_fatal("MSGQ_1588_RAW", "unpack changed EMP bytes")
        if (!emp_entry.parse_completion())
            `uvm_fatal("MSGQ_1588_PARSE", "valid EMP vector was rejected")
        if (emp_entry.timestamp != {8'h5a, 32'h1234_5678} ||
            emp_entry.timestamp_tag != 16'hbeef ||
            emp_entry.timestamp_type != 2'b10 ||
            emp_entry.source_port != 4'ha)
            `uvm_fatal("MSGQ_1588_FIELDS", "EMP fields decoded incorrectly")

        linux_entry = new("linux_entry", MSGQ_PROFILE_LINUX_HEADER);
        if (!linux_entry.unpack(emp_valid))
            `uvm_fatal("MSGQ_1588_LINUX_RAW", "Linux profile did not capture bytes")
        if (linux_entry.parse_completion())
            `uvm_fatal("MSGQ_1588_LINUX_PORT", "Linux profile accepted a four-bit port")
        if (linux_entry.raw_bytes != emp_valid)
            `uvm_fatal("MSGQ_1588_LINUX_RAW", "Linux rejection discarded raw bytes")
        if (!linux_entry.unpack(linux_valid) || !linux_entry.parse_completion())
            `uvm_fatal("MSGQ_1588_LINUX", "valid Linux-profile vector was rejected")
        if (linux_entry.timestamp != {8'h5a, 32'h1234_5678} ||
            linux_entry.timestamp_tag != 16'hbeef ||
            linux_entry.timestamp_type != 2'b10 ||
            linux_entry.source_port != 4'h2)
            `uvm_fatal("MSGQ_1588_LINUX_FIELDS", "Linux fields decoded incorrectly")

        if (!emp_entry.unpack(final_reserved) || emp_entry.parse_completion())
            `uvm_fatal("MSGQ_1588_EMP_RSV", "EMP final reserved bits were accepted")
        if (emp_entry.raw_bytes != final_reserved)
            `uvm_fatal("MSGQ_1588_EMP_RAW", "EMP rejection discarded raw bytes")
        emp_entry.strict_reserved = 0;
        if (!emp_entry.parse_completion() ||
            emp_entry.raw_bytes != final_reserved ||
            emp_entry.timestamp != {8'h5a, 32'h1234_5678} ||
            emp_entry.timestamp_tag != 16'hbeef ||
            emp_entry.timestamp_type != 2'b10 ||
            emp_entry.source_port != 4'h2)
            `uvm_fatal("MSGQ_1588_EMP_LOOSE", "non-strict parse lost raw or decoded fields")
        if (!linux_entry.unpack(final_reserved) || linux_entry.parse_completion())
            `uvm_fatal("MSGQ_1588_LINUX_RSV", "Linux final reserved bits were accepted")
        if (linux_entry.raw_bytes != final_reserved)
            `uvm_fatal("MSGQ_1588_LINUX_RAW", "Linux rejection discarded raw bytes")
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        check_mac_age();
        check_1588();
    endfunction
endclass

`endif
