`ifndef GQ_QUEUE_CFG_SV
`define GQ_QUEUE_CFG_SV

class gq_queue_cfg extends uvm_object;
    `uvm_object_utils(gq_queue_cfg)

    int unsigned   queue_id;
    gq_role_e      role;
    int unsigned   depth;
    int unsigned   desc_size;
    int unsigned   alignment;
    int unsigned   status_area_size;
    gq_wait_mode_e    wait_mode;
    gq_poll_policy_e  poll_policy;
    time              poll_min_interval;
    time              poll_max_interval;
    int unsigned      poll_backoff_factor;
    time              irq_watchdog_interval;
    time              completion_timeout;
    gq_rx_slot_mode_e rx_slot_mode;

    gq_ptr_codec         ptr_codec;
    gq_completion_source completion_source;

    function new(string name = "gq_queue_cfg");
        super.new(name);
        queue_id           = 0;
        role               = GQ_TX;
        depth              = 0;
        desc_size          = 0;
        alignment          = 0;
        status_area_size   = 0;
        wait_mode             = GQ_POLL;
        poll_policy           = GQ_POLL_FIXED;
        poll_min_interval     = 10ns;
        poll_max_interval     = 10ns;
        poll_backoff_factor   = 2;
        irq_watchdog_interval = 0;
        completion_timeout    = 0;
        rx_slot_mode           = GQ_RX_EXPLICIT_REFILL;
        ptr_codec             = null;
        completion_source     = null;
    endfunction

    function bit validate(output string reason);
        string completion_reason;
        string pointer_reason;

        if (!gq_is_pow2(depth)) begin
            reason = $sformatf("depth must be a power of two and at least 2 (got %0d)", depth);
            return 0;
        end

        if (desc_size == 0) begin
            reason = "descriptor size must be non-zero";
            return 0;
        end

        if (alignment == 0) begin
            reason = "alignment must be non-zero";
            return 0;
        end

        if (ptr_codec == null) begin
            reason = "pointer codec must not be null";
            return 0;
        end

        if (!ptr_codec.validate(depth, pointer_reason)) begin
            reason = {"pointer codec: ", pointer_reason};
            return 0;
        end

        if (completion_source == null) begin
            reason = "completion source must not be null";
            return 0;
        end

        if (!completion_source.validate(status_area_size,
                                        completion_reason)) begin
            reason = {"completion source: ", completion_reason};
            return 0;
        end

        if (poll_min_interval == 0) begin
            reason = "poll minimum interval must be non-zero";
            return 0;
        end

        if (poll_max_interval < poll_min_interval) begin
            reason = "poll maximum interval must not be below the minimum";
            return 0;
        end

        if (poll_backoff_factor < 1) begin
            reason = "poll backoff factor must be at least one";
            return 0;
        end

        if (poll_policy == GQ_POLL_FIXED &&
            poll_min_interval != poll_max_interval) begin
            reason = "fixed polling requires equal minimum and maximum intervals";
            return 0;
        end

        if (role == GQ_TX && completion_timeout == 0) begin
            reason = "TX completion timeout must be non-zero";
            return 0;
        end

        if (role == GQ_TX && completion_timeout <= poll_max_interval) begin
            reason = "TX completion timeout must be greater than the poll maximum interval";
            return 0;
        end

        if (completion_timeout != 0 &&
            (completion_timeout / 4) < poll_max_interval)
            `uvm_warning("GQ_CFG_TIMEOUT", $sformatf(
                "completion timeout %0t is below four poll maximum intervals (%0t)",
                completion_timeout, poll_max_interval))

        reason = "";
        return 1;
    endfunction
endclass

`endif
