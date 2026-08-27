`ifndef MSGQ_ENTRY_BASE_SV
`define MSGQ_ENTRY_BASE_SV

class msgq_entry_base extends gq_desc_base;
    `uvm_object_utils(msgq_entry_base)

    int unsigned entry_size;
    gq_logical_seq_t logical_seq;
    byte raw_bytes[];

    function new(string name = "msgq_entry_base");
        super.new(name);
        entry_size  = 0;
        logical_seq = 0;
        raw_bytes   = new[0];
    endfunction

    function void set_entry_size(int unsigned size);
        entry_size = size;
    endfunction

    virtual function void pack(ref byte packed_data[]);
        packed_data = new[entry_size];
        foreach (packed_data[i])
            packed_data[i] = 0;
    endfunction

    virtual function bit unpack(input byte packed_data[]);
        if (packed_data.size() != entry_size)
            return 0;

        raw_bytes = new[entry_size];
        foreach (packed_data[i])
            raw_bytes[i] = packed_data[i];
        return 1;
    endfunction

    virtual function bit is_complete(bit phase);
        return 1;
    endfunction
endclass

`endif
