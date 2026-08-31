`ifndef MSGQ_ENV_SV
`define MSGQ_ENV_SV

class msgq_env_cfg extends gq_env_cfg;
    `uvm_object_utils(msgq_env_cfg)

    msgq_ptr_codec ptr_codec;
    protected msgq_refill_profile refill_profiles[int unsigned];

    function new(string name = "msgq_env_cfg");
        super.new(name);
        ptr_codec = msgq_ptr_codec::type_id::create({name, "_ptr_codec"});
    endfunction

    function msgq_refill_profile get_refill_profile(int unsigned queue_id);
        if (!refill_profiles.exists(queue_id))
            return null;
        return refill_profiles[queue_id];
    endfunction

    function bit add_msgq(
        int unsigned queue_id, msgq_kind_e kind,
        msgq_format_profile_e format_profile,
        int unsigned raw_depth, int unsigned raw_entry_size,
        msgq_entry_factory factory, output string reason);
        gq_queue_cfg queue_cfg;
        msgq_refill_profile profile;
        msgq_completion completion;
        int unsigned depth;
        int unsigned entry_size;

        case (kind)
            MSGQ_MAC_AGE: begin
                depth      = MSGQ_MAC_AGE_DEPTH;
                entry_size = MSGQ_MAC_AGE_ENTRY_BYTES;
            end
            MSGQ_1588: begin
                depth = format_profile == MSGQ_PROFILE_EMP_ACTIVE ?
                        MSGQ_1588_EMP_DEPTH : MSGQ_1588_LINUX_DEPTH;
                entry_size = MSGQ_1588_ENTRY_BYTES;
            end
            MSGQ_FSE, MSGQ_IACL, MSGQ_EACL, MSGQ_VDPA, MSGQ_NOTIFY: begin
                if (!gq_is_pow2(raw_depth)) begin
                    reason = $sformatf(
                        "raw depth must be a non-zero power of two (got %0d)",
                        raw_depth);
                    return 0;
                end
                if (raw_entry_size == 0) begin
                    reason = "raw entry size must be non-zero";
                    return 0;
                end
                if (factory == null) begin
                    reason = "raw entry factory must not be null";
                    return 0;
                end
                depth      = raw_depth;
                entry_size = raw_entry_size;
            end
            default: begin
                reason = $sformatf("unsupported MSGQ kind %0d", kind);
                return 0;
            end
        endcase

        queue_cfg = gq_queue_cfg::type_id::create(
            $sformatf("rx_%0d_cfg", queue_id));
        completion = new($sformatf("rx_%0d_completion", queue_id), queue_id);
        queue_cfg.queue_id             = queue_id;
        queue_cfg.role                 = GQ_RX;
        queue_cfg.depth                = depth;
        queue_cfg.desc_size            = entry_size;
        queue_cfg.alignment            = 64;
        queue_cfg.status_area_size     = 0;
        queue_cfg.wait_mode            = GQ_IRQ;
        queue_cfg.poll_policy          = GQ_POLL_ADAPTIVE;
        queue_cfg.poll_min_interval    = 50ns;
        queue_cfg.poll_max_interval    = 500ns;
        queue_cfg.poll_backoff_factor  = 2;
        queue_cfg.irq_watchdog_interval = 1us;
        queue_cfg.completion_timeout   = 0;
        queue_cfg.rx_slot_mode         = GQ_RX_AUTO_RECYCLE;
        queue_cfg.ptr_codec            = ptr_codec;
        queue_cfg.completion_source    = completion;

        profile = msgq_refill_profile::type_id::create(
            $sformatf("rx_%0d_refill", queue_id));
        profile.kind               = kind;
        profile.format_profile     = format_profile;
        profile.entry_size         = entry_size;
        profile.strict_reserved    = 1;
        profile.factory            = factory;
        profile.initial_post_count = depth - 1;
        profile.high_watermark     = depth - 1;
        profile.low_watermark      = depth - 2;
        profile.max_refill_batch   = 0;

        if (!profile.validate(depth, reason))
            return 0;
        if (!add_queue(queue_cfg, reason))
            return 0;

        refill_profiles[queue_id] = profile;
        reason = "";
        return 1;
    endfunction

    virtual function bit validate(output string reason);
        string key;
        msgq_reg_adapter installed_adapter;
        msgq_ptr_codec installed_codec;
        msgq_completion installed_completion;
        string profile_reason;

        if (adapter == null || !$cast(installed_adapter, adapter)) begin
            reason = "MSGQ adapter must derive from msgq_reg_adapter";
            return 0;
        end
        if (ptr_codec == null) begin
            reason = "MSGQ pointer codec must not be null";
            return 0;
        end

        if (queues.first(key)) begin
            do begin
                if (queues[key] == null) begin
                    reason = $sformatf(
                        "MSGQ queue %s configuration must not be null", key);
                    return 0;
                end
                if (queues[key].role != GQ_RX) begin
                    reason = $sformatf("MSGQ queue %s must be RX", key);
                    return 0;
                end
                if (!$cast(installed_codec, queues[key].ptr_codec) ||
                    queues[key].ptr_codec != ptr_codec ||
                    !$cast(installed_completion,
                           queues[key].completion_source) ||
                    installed_completion.queue_id != queues[key].queue_id) begin
                    reason = $sformatf(
                        "MSGQ queue %s has non-MSGQ codec or completion types",
                        key);
                    return 0;
                end
                if (!refill_profiles.exists(queues[key].queue_id) ||
                    refill_profiles[queues[key].queue_id] == null ||
                    refill_profiles[queues[key].queue_id].entry_size !=
                        queues[key].desc_size ||
                    refill_profiles[queues[key].queue_id].initial_post_count !=
                        queues[key].depth - 1 ||
                    refill_profiles[queues[key].queue_id].high_watermark !=
                        queues[key].depth - 1 ||
                    refill_profiles[queues[key].queue_id].low_watermark !=
                        queues[key].depth - 2 ||
                    refill_profiles[queues[key].queue_id].max_refill_batch != 0 ||
                    queues[key].rx_slot_mode != GQ_RX_AUTO_RECYCLE ||
                    !refill_profiles[queues[key].queue_id].validate(
                        queues[key].depth, profile_reason)) begin
                    reason = $sformatf("MSGQ queue %s refill profile: %s",
                                       key, profile_reason);
                    return 0;
                end
            end while (queues.next(key));
        end

        return super.validate(reason);
    endfunction
endclass

class msgq_env extends gq_env;
    `uvm_component_utils(msgq_env)

    function new(string name = "msgq_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction
endclass

`endif
