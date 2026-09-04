// src/msgq/msgq_refill_profile.sv: 选择具体条目或原始条目创建方式的 MSGQ 类型/配置工厂。
`ifndef MSGQ_REFILL_PROFILE_SV
`define MSGQ_REFILL_PROFILE_SV

virtual class msgq_entry_factory extends uvm_object;
    function new(string name = "msgq_entry_factory");
        super.new(name);
    endfunction

    pure virtual function msgq_entry_base create_entry(
        int unsigned queue_id, gq_logical_seq_t logical_seq,
        int unsigned entry_size);
endclass

class msgq_refill_profile extends gq_refill_profile;
    `uvm_object_utils(msgq_refill_profile)

    msgq_kind_e kind;
    msgq_format_profile_e format_profile;
    int unsigned entry_size;
    bit strict_reserved;
    msgq_entry_factory factory;

    // MAC-age/1588 使用内置解析器；FSE/IACL/EACL/vDPA/notify 通过调用者提供的
    // 原始条目工厂处理，不猜测载荷字段。
    function new(string name = "msgq_refill_profile");
        super.new(name);
        kind           = MSGQ_MAC_AGE;
        format_profile = MSGQ_PROFILE_EMP_ACTIVE;
        entry_size     = MSGQ_MAC_AGE_ENTRY_BYTES;
        strict_reserved = 1;
        factory        = null;
    endfunction

    virtual function bit validate(int unsigned depth, output string reason);
        if (!super.validate(depth, reason))
            return 0;

        case (kind)
            MSGQ_MAC_AGE: begin
                if (depth != MSGQ_MAC_AGE_DEPTH ||
                    entry_size != MSGQ_MAC_AGE_ENTRY_BYTES) begin
                    reason = $sformatf(
                        "MAC-age geometry must be depth %0d and entry size %0d",
                        MSGQ_MAC_AGE_DEPTH, MSGQ_MAC_AGE_ENTRY_BYTES);
                    return 0;
                end
            end
            MSGQ_1588: begin
                int unsigned expected_depth;

                expected_depth = format_profile == MSGQ_PROFILE_EMP_ACTIVE ?
                                 MSGQ_1588_EMP_DEPTH :
                                 MSGQ_1588_LINUX_DEPTH;
                if (depth != expected_depth ||
                    entry_size != MSGQ_1588_ENTRY_BYTES) begin
                    reason = $sformatf(
                        "1588 geometry must be depth %0d and entry size %0d",
                        expected_depth, MSGQ_1588_ENTRY_BYTES);
                    return 0;
                end
            end
            MSGQ_FSE, MSGQ_IACL, MSGQ_EACL, MSGQ_VDPA, MSGQ_NOTIFY: begin
                if (!gq_is_pow2(depth)) begin
                    reason = $sformatf(
                        "raw depth must be a non-zero power of two (got %0d)",
                        depth);
                    return 0;
                end
                if (entry_size == 0) begin
                    reason = "raw entry size must be non-zero";
                    return 0;
                end
                if (factory == null) begin
                    reason = "raw entry factory must not be null";
                    return 0;
                end
            end
            default: begin
                reason = $sformatf("unsupported MSGQ kind %0d", kind);
                return 0;
            end
        endcase

        reason = "";
        return 1;
    endfunction

    virtual function gq_desc_base create_desc(
        int unsigned queue_id, gq_logical_seq_t logical_seq);
        msgq_entry_base entry;
        msgq_mac_age_entry mac_entry;
        msgq_1588_entry timestamp_entry;

        // 选择类型专用对象后，再为返回条目设置逻辑序号和配置的条目大小。
        case (kind)
            MSGQ_MAC_AGE: begin
                mac_entry = msgq_mac_age_entry::type_id::create(
                    $sformatf("rx_%0d_mac_age_%0d", queue_id, logical_seq));
                mac_entry.strict_reserved = strict_reserved;
                entry = mac_entry;
            end
            MSGQ_1588: begin
                timestamp_entry = msgq_1588_entry::type_id::create(
                    $sformatf("rx_%0d_1588_%0d", queue_id, logical_seq));
                timestamp_entry.set_format_profile(format_profile);
                timestamp_entry.strict_reserved = strict_reserved;
                entry = timestamp_entry;
            end
            default: begin
                if (factory == null)
                    return null;
                entry = factory.create_entry(queue_id, logical_seq,
                                             entry_size);
            end
        endcase

        if (entry == null)
            return null;
        entry.logical_seq = logical_seq;
        entry.set_entry_size(entry_size);
        return entry;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        msgq_refill_profile rhs_profile;

        super.do_copy(rhs);
        if (!$cast(rhs_profile, rhs))
            `uvm_fatal("MSGQ_REFILL_COPY",
                       "source is not an MSGQ refill profile")
        kind            = rhs_profile.kind;
        format_profile  = rhs_profile.format_profile;
        entry_size      = rhs_profile.entry_size;
        strict_reserved = rhs_profile.strict_reserved;
        factory         = rhs_profile.factory;
    endfunction
endclass

`endif
