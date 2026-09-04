// src/dmaq/dmaq_sequences.sv: 带独立完成截止时间处理的同步 DMAQ 传输序列。
`ifndef DMAQ_SEQUENCES_SV
`define DMAQ_SEQUENCES_SV

class dmaq_transfer_sequence extends uvm_sequence #(gq_request, gq_response);
    `uvm_object_utils(dmaq_transfer_sequence)

    dmaq_operation_e operation;
    dmaq_endpoint_t source;
    dmaq_endpoint_t destination;
    int unsigned transfer_length;
    time completion_timeout;
    dmaq_result_status_e result_status;

    // 序列超时独立于引擎诊断超时，因此调用者停止等待时不会放弃描述符所有权。
    function new(string name = "dmaq_transfer_sequence");
        super.new(name);
        operation = DMAQ_AF_TO_HOST;
        source = '0;
        destination = '0;
        transfer_length = 0;
        completion_timeout = 500ns;
        result_status = DMAQ_RESULT_SUBMIT_ERROR;
    endfunction

    task body();
        dmaq_tx_desc desc;
        gq_request request;
        gq_response response;
        semaphore outcome_lock;
        bit outcome_owned;
        bit completion_seen;
        realtime completion_at;
        realtime deadline_at;

        result_status = DMAQ_RESULT_SUBMIT_ERROR;
        if (completion_timeout == 0)
            return;

        desc = dmaq_tx_desc::type_id::create("desc");
        desc.operation = operation;
        desc.source = source;
        desc.destination = destination;
        desc.transfer_length = transfer_length;

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
        completion_seen = 0;
        completion_at = 0.0;
        deadline_at = $realtime + completion_timeout;
        fork
            begin : completion_timeout_race
                fork
                    begin : completion_branch
                        desc.completion_event.wait_on();
                        outcome_lock.get(1);
                        completion_at = $realtime;
                        completion_seen = 1;
                        if (!outcome_owned) begin
                            outcome_owned = 1;
                            if (completion_at <= deadline_at)
                                result_status = DMAQ_RESULT_OK;
                            else
                                result_status = DMAQ_RESULT_TIMEOUT;
                        end
                        outcome_lock.put(1);
                    end
                    begin : timeout_branch
                        #(completion_timeout);
                        #1step;
                        outcome_lock.get(1);
                        if (!outcome_owned) begin
                            outcome_owned = 1;
                            if (completion_seen &&
                                completion_at <= deadline_at)
                                result_status = DMAQ_RESULT_OK;
                            else
                                result_status = DMAQ_RESULT_TIMEOUT;
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
