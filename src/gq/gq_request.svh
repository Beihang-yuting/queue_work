`ifndef GQ_REQUEST_SVH
`define GQ_REQUEST_SVH

typedef enum bit { GQ_SUBMIT, GQ_START_RX } gq_request_kind_e;

class gq_request extends uvm_sequence_item;
    `uvm_object_utils(gq_request)

    gq_request_kind_e kind;
    gq_desc_base descs[$];

    function new(string name = "gq_request");
        super.new(name);
        kind = GQ_SUBMIT;
    endfunction

    function void add_desc(gq_desc_base desc);
        descs.push_back(desc);
    endfunction

    function int unsigned size();
        return descs.size();
    endfunction
endclass

class gq_response extends uvm_sequence_item;
    `uvm_object_utils_begin(gq_response)
        `uvm_field_enum(gq_status_e, status, UVM_DEFAULT)
        `uvm_field_int(committed_count, UVM_DEFAULT)
        `uvm_field_int(reset_epoch, UVM_DEFAULT)
    `uvm_object_utils_end

    gq_status_e status;
    int committed_count;
    longint unsigned reset_epoch;

    function new(string name = "gq_response");
        super.new(name);
        status          = GQ_RESOURCE_ERROR;
        committed_count = 0;
        reset_epoch     = 0;
    endfunction
endclass

`endif
