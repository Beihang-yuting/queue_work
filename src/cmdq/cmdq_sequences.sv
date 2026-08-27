`ifndef CMDQ_SEQUENCES_SV
`define CMDQ_SEQUENCES_SV

class cmdq_command_sequence extends uvm_sequence #(gq_request, gq_response);
    `uvm_object_utils(cmdq_command_sequence)

    byte request_payload[];
    bit [15:0] dst_id;
    time completion_timeout = 10us;
    byte result[];
    cmdq_result_status_e result_status;

    function new(string name = "cmdq_command_sequence");
        super.new(name);
        request_payload = new[0];
        dst_id = 0;
        result = new[0];
        result_status = CMDQ_RESULT_SUBMIT_ERROR;
    endfunction

    protected function void accept_completion(cmdq_tx_desc desc);
        result = new[desc.result.size()];
        foreach (desc.result[i])
            result[i] = desc.result[i];
        result_status = CMDQ_RESULT_OK;
    endfunction

    task body();
        cmdq_tx_desc desc;
        gq_request request;
        gq_response response;
        semaphore outcome_lock;
        bit outcome_owned;

        result = new[0];
        result_status = CMDQ_RESULT_SUBMIT_ERROR;
        desc = cmdq_tx_desc::type_id::create("desc");
        desc.request = new[request_payload.size()];
        foreach (request_payload[i])
            desc.request[i] = request_payload[i];
        desc.dst_id = dst_id;

        request = gq_request::type_id::create("request");
        request.kind = GQ_SUBMIT;
        request.add_desc(desc);
        start_item(request);
        finish_item(request);
        get_response(response);
        if (response == null || response.status != GQ_OK ||
            response.committed_count != 1)
            return;

        outcome_lock = new(1);
        outcome_owned = 0;
        fork
            begin : completion_timeout_race
                fork
                    begin : completion_branch
                        desc.completion_event.wait_on();
                        outcome_lock.get(1);
                        if (!outcome_owned) begin
                            outcome_owned = 1;
                            accept_completion(desc);
                        end
                        outcome_lock.put(1);
                    end
                    begin : timeout_branch
                        #(completion_timeout);
                        // Let every active completion in this deadline time
                        // slot trigger its persistent event before arbitration.
                        #0;
                        outcome_lock.get(1);
                        if (!outcome_owned) begin
                            outcome_owned = 1;
                            if (desc.completion_event.is_on())
                                accept_completion(desc);
                            else begin
                                result = new[0];
                                result_status = CMDQ_RESULT_TIMEOUT;
                            end
                        end
                        outcome_lock.put(1);
                    end
                join_any
                disable fork;
            end
        join
    endtask
endclass

`endif
