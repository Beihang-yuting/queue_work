`ifndef MAILBOX_SEQUENCES_SVH
`define MAILBOX_SEQUENCES_SVH

class mailbox_tx_sequence extends uvm_sequence #(gq_request, gq_response);
    `uvm_object_utils(mailbox_tx_sequence)

    mailbox_tx_desc descs[$];
    gq_response response;

    function new(string name = "mailbox_tx_sequence");
        super.new(name);
    endfunction

    function void add_desc(mailbox_tx_desc desc);
        descs.push_back(desc);
    endfunction

    task body();
        gq_request request;

        request = gq_request::type_id::create("request");
        request.kind = GQ_SUBMIT;
        foreach (descs[i])
            request.add_desc(descs[i]);
        start_item(request);
        finish_item(request);
        get_response(response);
    endtask
endclass

class mailbox_rx_start_sequence extends uvm_sequence #(gq_request, gq_response);
    `uvm_object_utils(mailbox_rx_start_sequence)

    protected gq_refill_profile refill_profile;
    gq_response response;

    function new(string name = "mailbox_rx_start_sequence");
        super.new(name);
        refill_profile = null;
    endfunction

    function void set_refill_profile(gq_refill_profile profile);
        refill_profile = profile;
    endfunction

    function gq_refill_profile get_refill_profile();
        return refill_profile;
    endfunction

    task body();
        gq_request request;

        request = gq_request::type_id::create("request");
        request.kind = GQ_START_RX;
        request.set_refill_profile(refill_profile);
        start_item(request);
        finish_item(request);
        get_response(response);
    endtask
endclass

`endif
