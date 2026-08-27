`ifndef MSGQ_1588_ENTRY_SV
`define MSGQ_1588_ENTRY_SV

class msgq_1588_entry extends msgq_entry_base;
    `uvm_object_utils(msgq_1588_entry)

    bit [39:0] timestamp;
    bit [15:0] timestamp_tag;
    bit [1:0]  timestamp_type;
    bit [3:0]  source_port;
    msgq_format_profile_e format_profile;
    bit strict_reserved;

    function new(string name = "msgq_1588_entry",
                 msgq_format_profile_e profile = MSGQ_PROFILE_EMP_ACTIVE);
        super.new(name);
        entry_size       = MSGQ_1588_ENTRY_BYTES;
        timestamp        = 0;
        timestamp_tag    = 0;
        timestamp_type   = 0;
        source_port      = 0;
        format_profile   = profile;
        strict_reserved  = 1;
    endfunction

    function void set_format_profile(msgq_format_profile_e profile);
        format_profile = profile;
    endfunction

    virtual function bit parse_completion();
        bit [63:0] packed_entry;

        if (raw_bytes.size() != MSGQ_1588_ENTRY_BYTES)
            return 0;

        packed_entry = {raw_bytes[7], raw_bytes[6], raw_bytes[5], raw_bytes[4],
                        raw_bytes[3], raw_bytes[2], raw_bytes[1], raw_bytes[0]};

        timestamp      = packed_entry[39:0];
        timestamp_tag  = packed_entry[55:40];
        timestamp_type = packed_entry[57:56];
        source_port    = packed_entry[61:58];

        if (strict_reserved && packed_entry[63:62] != 0)
            return 0;
        if (strict_reserved && format_profile == MSGQ_PROFILE_LINUX_HEADER &&
            source_port[3:2] != 0)
            return 0;
        return 1;
    endfunction
endclass

`endif
