// src/msgq/msgq_mac_age_entry.sv: MSGQ MAC-age 条目解析器及严格保留位校验。
`ifndef MSGQ_MAC_AGE_ENTRY_SV
`define MSGQ_MAC_AGE_ENTRY_SV

class msgq_mac_age_entry extends msgq_entry_base;
    `uvm_object_utils(msgq_mac_age_entry)

    bit [31:0] hash_key_l;
    bit [28:0] hash_key_h;
    bit [8:0]  mac_act_idx;
    bit        strict_reserved;

    // 解析器重建小端 DWORD；启用严格校验时，任何保留字段非零都会被拒绝。
    function new(string name = "msgq_mac_age_entry");
        super.new(name);
        entry_size      = MSGQ_MAC_AGE_ENTRY_BYTES;
        hash_key_l      = 0;
        hash_key_h      = 0;
        mac_act_idx     = 0;
        strict_reserved = 1;
    endfunction

    virtual function bit parse_completion();
        bit [31:0] dword0;
        bit [31:0] dword1;
        bit [31:0] dword2;
        bit [31:0] dword3;

        if (raw_bytes.size() != MSGQ_MAC_AGE_ENTRY_BYTES)
            return 0;

        dword0 = {raw_bytes[3], raw_bytes[2], raw_bytes[1], raw_bytes[0]};
        dword1 = {raw_bytes[7], raw_bytes[6], raw_bytes[5], raw_bytes[4]};
        dword2 = {raw_bytes[11], raw_bytes[10], raw_bytes[9], raw_bytes[8]};
        dword3 = {raw_bytes[15], raw_bytes[14], raw_bytes[13], raw_bytes[12]};

        hash_key_l  = dword0;
        hash_key_h  = dword1[28:0];
        mac_act_idx = dword2[8:0];

        if (strict_reserved &&
            (dword1[31:29] != 0 || dword2[31:9] != 0 || dword3 != 0))
            return 0;
        return 1;
    endfunction
endclass

`endif
