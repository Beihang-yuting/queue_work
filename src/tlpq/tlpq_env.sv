`ifndef TLPQ_ENV_SV
`define TLPQ_ENV_SV

class tlpq_env_cfg extends gq_env_cfg;
    `uvm_object_utils(tlpq_env_cfg)

    protected bit channel_added[int];
    protected int unsigned channel_queue_ids[int];
    protected tlpq_rx_hw_cfg_t channel_hw_cfgs[int];
    protected tlpq_refill_profile refill_profiles[int];

    function new(string name = "tlpq_env_cfg");
        super.new(name);
    endfunction

    function gq_queue_cfg get_tlpq_rx_cfg(tlpq_channel_e channel);
        int channel_key;
        string key;

        channel_key = int'(channel);
        if (!channel_added.exists(channel_key) ||
            !channel_added[channel_key])
            return null;
        key = gq_queue_key(GQ_RX, channel_queue_ids[channel_key]);
        if (!queues.exists(key))
            return null;
        return queues[key];
    endfunction

    function tlpq_refill_profile get_refill_profile(
        tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        if (!refill_profiles.exists(channel_key))
            return null;
        return refill_profiles[channel_key];
    endfunction

    function bit get_tlpq_rx_queue_id(
        tlpq_channel_e channel, output int unsigned queue_id);
        int channel_key;

        channel_key = int'(channel);
        if (!channel_added.exists(channel_key) ||
            !channel_added[channel_key]) begin
            queue_id = 0;
            return 0;
        end
        queue_id = channel_queue_ids[channel_key];
        return 1;
    endfunction

    function bit add_tlpq_rx(
        tlpq_channel_e channel, int unsigned queue_id,
        tlpq_rx_hw_cfg_t hw_cfg, output string reason);
        int channel_key;
        string key;
        string existing_key;
        string queue_reason;
        tlpq_reg_adapter installed_adapter;
        gq_queue_cfg queue_cfg;
        tlpq_refill_profile profile;

        if (adapter == null || !$cast(installed_adapter, adapter)) begin
            reason = "TLPQ adapter must derive from tlpq_reg_adapter";
            return 0;
        end

        channel_key = int'(channel);
        if (channel_added.exists(channel_key) &&
            channel_added[channel_key]) begin
            reason = $sformatf("duplicate TLPQ channel %0d", channel_key);
            return 0;
        end

        if (queues.first(existing_key)) begin
            do begin
                if (queues[existing_key] != null &&
                    queues[existing_key].queue_id == queue_id) begin
                    reason = $sformatf("duplicate TLPQ queue ID %0d",
                                       queue_id);
                    return 0;
                end
            end while (queues.next(existing_key));
        end

        queue_cfg = gq_queue_cfg::type_id::create(
            $sformatf("rx_%0d_cfg", queue_id));
        queue_cfg.queue_id              = queue_id;
        queue_cfg.role                  = GQ_RX;
        queue_cfg.depth                 = TLPQ_DEPTH;
        queue_cfg.desc_size             = TLPQ_DESC_BYTES;
        queue_cfg.alignment             = 64;
        queue_cfg.status_area_size      = 0;
        queue_cfg.wait_mode             = GQ_IRQ;
        queue_cfg.poll_policy           = GQ_POLL_ADAPTIVE;
        queue_cfg.poll_min_interval     = 50ns;
        queue_cfg.poll_max_interval     = 500ns;
        queue_cfg.poll_backoff_factor   = 2;
        queue_cfg.irq_watchdog_interval = 1us;
        queue_cfg.completion_timeout    = 0;
        queue_cfg.rx_slot_mode          = GQ_RX_EXPLICIT_REFILL;
        queue_cfg.ptr_codec = tlpq_ptr_codec::type_id::create(
            $sformatf("rx_%0d_ptr_codec", queue_id));
        queue_cfg.completion_source = tlpq_completion::type_id::create(
            $sformatf("rx_%0d_completion", queue_id));

        profile = tlpq_refill_profile::type_id::create(
            $sformatf("rx_%0d_refill", queue_id));
        if (queue_cfg == null || queue_cfg.ptr_codec == null ||
            queue_cfg.completion_source == null || profile == null) begin
            reason = "TLPQ RX strategy creation failed";
            return 0;
        end
        if (!queue_cfg.validate(queue_reason)) begin
            reason = {"TLPQ RX queue configuration: ", queue_reason};
            return 0;
        end
        if (!profile.validate(queue_cfg.depth, queue_reason)) begin
            reason = {"TLPQ RX refill profile: ", queue_reason};
            return 0;
        end
        if (!add_queue(queue_cfg, reason))
            return 0;
        if (!installed_adapter.register_tlpq_rx(
                channel, queue_id, hw_cfg, reason)) begin
            key = gq_queue_key(GQ_RX, queue_id);
            queues.delete(key);
            return 0;
        end

        channel_added[channel_key] = 1;
        channel_queue_ids[channel_key] = queue_id;
        channel_hw_cfgs[channel_key] = hw_cfg;
        refill_profiles[channel_key] = profile;
        reason = "";
        return 1;
    endfunction

    virtual function bit validate(output string reason);
        string key;
        string other_key;
        string profile_reason;
        int channel_key;
        tlpq_reg_adapter installed_adapter;
        tlpq_channel_e mapped_channel;
        tlpq_rx_hw_cfg_t mapped_hw_cfg;
        tlpq_ptr_codec installed_codec;
        tlpq_completion installed_completion;

        if (adapter == null || !$cast(installed_adapter, adapter)) begin
            reason = "TLPQ adapter must derive from tlpq_reg_adapter";
            return 0;
        end

        if (queues.first(key)) begin
            do begin
                if (queues[key] == null) begin
                    reason = $sformatf(
                        "TLPQ queue %s configuration must not be null", key);
                    return 0;
                end
                if (queues[key].role != GQ_RX ||
                    queues[key].depth != TLPQ_DEPTH ||
                    queues[key].desc_size != TLPQ_DESC_BYTES ||
                    queues[key].rx_slot_mode != GQ_RX_EXPLICIT_REFILL) begin
                    reason = $sformatf(
                        "TLPQ queue %s must be explicit-refill RX 32x16", key);
                    return 0;
                end
                if (!installed_adapter.get_tlpq_rx_mapping(
                        queues[key].queue_id, mapped_channel,
                        mapped_hw_cfg)) begin
                    reason = $sformatf(
                        "TLPQ queue %s has no semantic adapter mapping", key);
                    return 0;
                end
                channel_key = int'(mapped_channel);
                if (!channel_added.exists(channel_key) ||
                    !channel_added[channel_key] ||
                    channel_queue_ids[channel_key] != queues[key].queue_id ||
                    channel_hw_cfgs[channel_key] != mapped_hw_cfg) begin
                    reason = $sformatf(
                        "TLPQ queue %s channel metadata is inconsistent", key);
                    return 0;
                end
                if (!$cast(installed_codec, queues[key].ptr_codec) ||
                    !$cast(installed_completion,
                           queues[key].completion_source)) begin
                    reason = $sformatf(
                        "TLPQ queue %s has non-TLPQ strategies", key);
                    return 0;
                end
                if (!refill_profiles.exists(channel_key) ||
                    refill_profiles[channel_key] == null ||
                    refill_profiles[channel_key].initial_post_count != 31 ||
                    refill_profiles[channel_key].low_watermark != 30 ||
                    refill_profiles[channel_key].high_watermark != 31 ||
                    refill_profiles[channel_key].max_refill_batch != 1 ||
                    !refill_profiles[channel_key].restart_after_reset ||
                    !refill_profiles[channel_key].validate(
                        queues[key].depth, profile_reason)) begin
                    reason = $sformatf(
                        "TLPQ queue %s refill profile: %s",
                        key, profile_reason);
                    return 0;
                end

                other_key = key;
                if (queues.next(other_key)) begin
                    do begin
                        if (queues[other_key] != null &&
                            (queues[key].queue_id ==
                                 queues[other_key].queue_id ||
                             queues[key].ptr_codec ==
                                 queues[other_key].ptr_codec ||
                             queues[key].completion_source ==
                                 queues[other_key].completion_source)) begin
                            reason = "TLPQ queues share an ID or strategy";
                            return 0;
                        end
                    end while (queues.next(other_key));
                end
            end while (queues.next(key));
        end

        return super.validate(reason);
    endfunction
endclass

class tlpq_env extends gq_env;
    `uvm_component_utils(tlpq_env)

    function new(string name = "tlpq_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction
endclass

`endif
