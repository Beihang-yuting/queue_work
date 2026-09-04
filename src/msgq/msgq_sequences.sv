// src/msgq/msgq_sequences.sv: 投递初始条目窗口的 MSGQ 接收启动序列。
`ifndef MSGQ_SEQUENCES_SV
`define MSGQ_SEQUENCES_SV

class msgq_rx_start_sequence extends uvm_sequence #(gq_request, gq_response);
    `uvm_object_utils(msgq_rx_start_sequence)

    protected msgq_refill_profile refill_profile;
    gq_response response;

    function new(string name = "msgq_rx_start_sequence");
        super.new(name);
        refill_profile = null;
        response       = null;
    endfunction

    function void set_refill_profile(msgq_refill_profile profile);
        refill_profile = profile;
    endfunction

    function msgq_refill_profile get_refill_profile();
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
