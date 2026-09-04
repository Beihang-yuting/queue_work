// src/msgq/msgq_raw_entry.sv: 业务格式尚未解码时使用的 MSGQ 原始条目。
`ifndef MSGQ_RAW_ENTRY_SV
`define MSGQ_RAW_ENTRY_SV

class msgq_raw_entry extends msgq_entry_base;
    `uvm_object_utils(msgq_raw_entry)

    function new(string name = "msgq_raw_entry");
        super.new(name);
    endfunction
endclass

`endif
