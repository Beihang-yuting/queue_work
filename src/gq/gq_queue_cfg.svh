`ifndef GQ_QUEUE_CFG_SVH
`define GQ_QUEUE_CFG_SVH

class gq_queue_cfg extends uvm_object;
    `uvm_object_utils(gq_queue_cfg)

    int unsigned   queue_id;
    gq_role_e      role;
    int unsigned   depth;
    int unsigned   desc_size;
    int unsigned   alignment;
    int unsigned   status_area_size;
    gq_wait_mode_e wait_mode;
    time           poll_interval;
    time           completion_timeout;

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
        wait_mode          = GQ_POLL;
        poll_interval      = 0;
        completion_timeout = 0;
        ptr_codec          = null;
        completion_source  = null;
    endfunction

    function bit validate(output string reason);
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

        if (wait_mode == GQ_POLL && poll_interval == 0) begin
            reason = "poll interval must be non-zero in poll mode";
            return 0;
        end

        if (completion_timeout == 0) begin
            reason = "completion timeout must be non-zero";
            return 0;
        end

        reason = "";
        return 1;
    endfunction
endclass

`endif
