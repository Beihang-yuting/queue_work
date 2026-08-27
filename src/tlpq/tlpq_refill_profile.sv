`ifndef TLPQ_REFILL_PROFILE_SV
`define TLPQ_REFILL_PROFILE_SV

class tlpq_refill_profile extends gq_refill_profile;
    `uvm_object_utils(tlpq_refill_profile)

    function new(string name = "tlpq_refill_profile");
        super.new(name);
        initial_post_count  = 31;
        low_watermark       = 30;
        high_watermark      = 31;
        max_refill_batch    = 1;
        restart_after_reset = 1;
    endfunction

    virtual function gq_desc_base create_desc(
        int unsigned queue_id, gq_logical_seq_t logical_seq);
        return tlpq_rx_desc::type_id::create(
            $sformatf("rx_%0d_desc_%0d", queue_id, logical_seq));
    endfunction
endclass

`endif
