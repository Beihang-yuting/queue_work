`ifndef MAILBOX_REFILL_PROFILE_SVH
`define MAILBOX_REFILL_PROFILE_SVH

class mailbox_refill_profile extends gq_refill_profile;
    `uvm_object_utils(mailbox_refill_profile)

    longint unsigned min_buf_len;
    longint unsigned max_buf_len;

    function new(string name = "mailbox_refill_profile");
        super.new(name);
        min_buf_len = 1;
        max_buf_len = 4096;
    endfunction

    virtual function bit validate(int unsigned depth, output string reason);
        if (!super.validate(depth, reason))
            return 0;
        if (min_buf_len == 0) begin
            reason = "minimum RX buffer length must be positive";
            return 0;
        end
        if (min_buf_len > max_buf_len) begin
            reason = $sformatf(
                "minimum RX buffer length %0d exceeds maximum %0d",
                min_buf_len, max_buf_len);
            return 0;
        end
        if (min_buf_len > 64'h0000_0000_ffff_ffff ||
            max_buf_len > 64'h0000_0000_ffff_ffff) begin
            reason = "RX buffer length must fit the 32-bit descriptor and allocator API";
            return 0;
        end
        reason = "";
        return 1;
    endfunction

    virtual function bit [31:0] choose_buf_len(
        gq_logical_seq_t logical_seq);
        int unsigned min_len;
        int unsigned max_len;

        min_len = int'(min_buf_len);
        max_len = int'(max_buf_len);
        return $urandom_range(max_len, min_len);
    endfunction

    virtual function gq_desc_base create_desc(
        int unsigned queue_id, gq_logical_seq_t logical_seq);
        mailbox_rx_desc desc;

        desc = mailbox_rx_desc::type_id::create(
            $sformatf("rx_%0d_desc_%0d", queue_id, logical_seq));
        desc.buf_len = choose_buf_len(logical_seq);
        return desc;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        mailbox_refill_profile rhs_profile;

        super.do_copy(rhs);
        if (!$cast(rhs_profile, rhs))
            `uvm_fatal("MAILBOX_REFILL_COPY",
                       "source is not a mailbox refill profile")
        min_buf_len = rhs_profile.min_buf_len;
        max_buf_len = rhs_profile.max_buf_len;
    endfunction
endclass

`endif
