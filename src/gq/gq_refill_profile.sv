`ifndef GQ_REFILL_PROFILE_SV
`define GQ_REFILL_PROFILE_SV

virtual class gq_refill_profile extends uvm_object;
    int unsigned initial_post_count;
    int unsigned low_watermark;
    int unsigned high_watermark;
    int unsigned max_refill_batch;
    bit          restart_after_reset;

    function new(string name = "gq_refill_profile");
        super.new(name);
        initial_post_count = 0;
        low_watermark      = 0;
        high_watermark     = 1;
        max_refill_batch   = 0;
        restart_after_reset = 0;
    endfunction

    virtual function bit validate(int unsigned depth, output string reason);
        if (low_watermark >= high_watermark) begin
            reason = $sformatf(
                "low watermark %0d must be less than high watermark %0d",
                low_watermark, high_watermark);
            return 0;
        end
        if (high_watermark > depth) begin
            reason = $sformatf("high watermark %0d exceeds queue depth %0d",
                               high_watermark, depth);
            return 0;
        end
        if (initial_post_count > depth) begin
            reason = $sformatf("initial post count %0d exceeds queue depth %0d",
                               initial_post_count, depth);
            return 0;
        end
        reason = "";
        return 1;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        gq_refill_profile rhs_profile;

        super.do_copy(rhs);
        if (!$cast(rhs_profile, rhs))
            `uvm_fatal("GQ_REFILL_COPY", "source is not a refill profile")
        initial_post_count  = rhs_profile.initial_post_count;
        low_watermark       = rhs_profile.low_watermark;
        high_watermark      = rhs_profile.high_watermark;
        max_refill_batch    = rhs_profile.max_refill_batch;
        restart_after_reset = rhs_profile.restart_after_reset;
    endfunction

    virtual function gq_refill_profile clone_profile();
        uvm_object cloned_object;
        gq_refill_profile cloned_profile;

        cloned_object = clone();
        if (cloned_object == null || !$cast(cloned_profile, cloned_object))
            return null;
        return cloned_profile;
    endfunction

    pure virtual function gq_desc_base create_desc(
        int unsigned queue_id, gq_logical_seq_t logical_seq);
endclass

`endif
