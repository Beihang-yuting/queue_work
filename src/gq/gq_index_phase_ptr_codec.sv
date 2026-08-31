`ifndef GQ_INDEX_PHASE_PTR_CODEC_SV
`define GQ_INDEX_PHASE_PTR_CODEC_SV

class gq_index_phase_ptr_codec extends gq_ptr_codec;
    protected int unsigned index_width;
    protected int unsigned phase_bit;
    protected bit          config_valid;
    protected string       config_reason;

    function new(string name = "gq_index_phase_ptr_codec",
                 int unsigned index_width = 15,
                 int unsigned phase_bit = 15);
        super.new(name);
        this.index_width = index_width;
        this.phase_bit   = phase_bit;
        config_valid     = 1;
        config_reason    = "";

        if (index_width == 0) begin
            config_valid  = 0;
            config_reason = "index width must be non-zero";
        end
        else if (phase_bit < index_width) begin
            config_valid  = 0;
            config_reason = "phase bit must not overlap the index field";
        end
        else if (phase_bit >= $bits(gq_raw_ptr_t)) begin
            config_valid  = 0;
            config_reason = "phase bit must lie within the raw pointer";
        end
    endfunction

    function bit validate_depth(int unsigned depth, output string reason);
        longint unsigned max_depth;

        if (!config_valid) begin
            reason = config_reason;
            return 0;
        end

        max_depth = 1;
        max_depth <<= index_width;
        if (depth == 0 || depth > max_depth) begin
            reason = $sformatf("depth must be between 1 and %0d (got %0d)",
                               max_depth, depth);
            return 0;
        end

        reason = "";
        return 1;
    endfunction

    virtual function bit validate(int unsigned depth, output string reason);
        return validate_depth(depth, reason);
    endfunction

    virtual function gq_raw_ptr_t encode_publish(
        gq_logical_seq_t old_tail,
        gq_logical_seq_t new_tail,
        int unsigned depth);
        gq_raw_ptr_t raw;
        string reason;

        raw = '0;
        if (!validate_depth(depth, reason)) begin
            `uvm_error("GQ_PTR_CFG", reason)
            return raw;
        end

        raw = gq_raw_ptr_t'(new_tail % depth);
        raw[phase_bit] = bit'((new_tail / depth) & 1);
        return raw;
    endfunction
endclass

`endif
