`ifndef MAILBOX_ENV_SV
`define MAILBOX_ENV_SV

class mailbox_env_cfg extends gq_env_cfg;
    `uvm_object_utils(mailbox_env_cfg)

    gq_ptr_codec ptr_codec;

    function new(string name = "mailbox_env_cfg");
        super.new(name);
        ptr_codec = null;
    endfunction

    virtual function bit validate(output string reason);
        string key;
        mailbox_completion installed_source;

        if (queues.first(key)) begin
            do begin
                if (queues[key] == null) begin
                    reason = $sformatf("mailbox queue %s configuration must not be null", key);
                    return 0;
                end
                if (queues[key].queue_id > 4095) begin
                    reason = $sformatf("mailbox queue %s ID %0d is outside 0..4095",
                                       key, queues[key].queue_id);
                    return 0;
                end
                if (queues[key].depth < 32 || queues[key].depth > 65536 ||
                    !gq_is_pow2(queues[key].depth)) begin
                    reason = $sformatf(
                        "mailbox queue %s depth %0d must be a power of two in 32..65536",
                        key, queues[key].depth);
                    return 0;
                end
                if (queues[key].role == GQ_TX && queues[key].desc_size != 64) begin
                    reason = $sformatf("mailbox TX queue %s descriptor size must be 64", key);
                    return 0;
                end
                if (queues[key].role == GQ_RX && queues[key].desc_size != 16) begin
                    reason = $sformatf("mailbox RX queue %s descriptor size must be 16", key);
                    return 0;
                end
            end while (queues.next(key));
        end

        if (ptr_codec == null) begin
            reason = "mailbox pointer codec must not be null";
            return 0;
        end
        if (queues.first(key)) begin
            do begin
                queues[key].ptr_codec = ptr_codec;
                if (queues[key].completion_source == null ||
                    !$cast(installed_source,
                           queues[key].completion_source))
                    queues[key].completion_source =
                        mailbox_completion::type_id::create(
                            {key, "_completion"});
            end while (queues.next(key));
        end
        return super.validate(reason);
    endfunction

    protected function bit add_mailbox_queue(
        gq_role_e role,
        int unsigned queue_id,
        int unsigned depth,
        int unsigned desc_size,
        output string reason);
        gq_queue_cfg queue_cfg;

        if (queue_id > 4095) begin
            reason = $sformatf("mailbox queue ID %0d is outside 0..4095", queue_id);
            return 0;
        end
        if (depth < 32 || depth > 65536 || !gq_is_pow2(depth)) begin
            reason = $sformatf("mailbox depth %0d must be a power of two in 32..65536",
                               depth);
            return 0;
        end

        queue_cfg = gq_queue_cfg::type_id::create(
            $sformatf("%s_cfg", gq_queue_key(role, queue_id)));
        queue_cfg.queue_id           = queue_id;
        queue_cfg.role               = role;
        queue_cfg.depth              = depth;
        queue_cfg.desc_size          = desc_size;
        queue_cfg.alignment          = 64;
        queue_cfg.status_area_size   = 0;
        queue_cfg.wait_mode          = GQ_POLL;
        queue_cfg.poll_interval      = 10ns;
        queue_cfg.completion_timeout = 1us;
        queue_cfg.ptr_codec          = ptr_codec;
        queue_cfg.completion_source  = mailbox_completion::type_id::create(
            $sformatf("%s_completion", gq_queue_key(role, queue_id)));
        return add_queue(queue_cfg, reason);
    endfunction

    function bit add_tx(int unsigned queue_id, int unsigned depth,
                        output string reason);
        return add_mailbox_queue(GQ_TX, queue_id, depth, 64, reason);
    endfunction

    function bit add_rx(int unsigned queue_id, int unsigned depth,
                        output string reason);
        return add_mailbox_queue(GQ_RX, queue_id, depth, 16, reason);
    endfunction
endclass

class mailbox_env extends gq_env;
    `uvm_component_utils(mailbox_env)

    function new(string name = "mailbox_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction
endclass

`endif
