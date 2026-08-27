`ifndef TLPQ_REG_ADAPTER_SV
`define TLPQ_REG_ADAPTER_SV

typedef struct packed {
    bit [2:0]  host_id;
    bit [15:0] bdf;
    bit [12:0] msix_index;
    bit        msix_valid;
} tlpq_rx_hw_cfg_t;

virtual class tlpq_reg_adapter extends gq_hw_adapter;
    protected tlpq_channel_e queue_channels[int unsigned];
    protected tlpq_rx_hw_cfg_t queue_hw_cfgs[int unsigned];
    protected int unsigned channel_queue_ids[int];
    protected bit enable_armed[int unsigned];
    protected longint unsigned configuration_generation[int unsigned];

    function new(string name = "tlpq_reg_adapter");
        super.new(name);
    endfunction

    pure virtual task reset_tlpq_rx(tlpq_channel_e channel);

    pure virtual task configure_tlpq_rx(
        tlpq_channel_e channel, gq_addr_t base, int unsigned depth,
        int unsigned desc_size, tlpq_rx_hw_cfg_t hw_cfg);

    pure virtual task enable_tlpq_rx(tlpq_channel_e channel);
    pure virtual task disable_tlpq_rx(tlpq_channel_e channel);

    pure virtual task write_tlpq_rx_tail(
        tlpq_channel_e channel, bit [15:0] tail);

    pure virtual task wait_tlpq_rx_irq(tlpq_channel_e channel);
    pure virtual task ack_tlpq_rx_irq(tlpq_channel_e channel);

    function bit register_tlpq_rx(
        tlpq_channel_e channel, int unsigned queue_id,
        tlpq_rx_hw_cfg_t hw_cfg, output string reason);
        int channel_key;

        channel_key = int'(channel);
        if (queue_channels.exists(queue_id)) begin
            reason = $sformatf("duplicate TLPQ queue ID %0d", queue_id);
            return 0;
        end
        if (channel_queue_ids.exists(channel_key)) begin
            reason = $sformatf("duplicate TLPQ channel %0d", channel_key);
            return 0;
        end

        queue_channels[queue_id] = channel;
        queue_hw_cfgs[queue_id] = hw_cfg;
        channel_queue_ids[channel_key] = queue_id;
        enable_armed[queue_id] = 0;
        configuration_generation[queue_id] = 0;
        reason = "";
        return 1;
    endfunction

    function bit get_tlpq_rx_mapping(
        int unsigned queue_id, output tlpq_channel_e channel,
        output tlpq_rx_hw_cfg_t hw_cfg);
        if (!queue_channels.exists(queue_id)) begin
            channel = TLPQ_HOST;
            hw_cfg = '0;
            return 0;
        end
        channel = queue_channels[queue_id];
        hw_cfg = queue_hw_cfgs[queue_id];
        return 1;
    endfunction

    protected function bit require_rx(
        gq_role_e role, int unsigned queue_id, string operation);
        if (role == GQ_RX)
            return 1;
        `uvm_error("TLPQ_REG_ROLE", $sformatf(
            "%s requires role=RX for queue_id=%0d", operation, queue_id))
        return 0;
    endfunction

    protected function bit resolve_queue(
        int unsigned queue_id, string operation,
        output tlpq_channel_e channel, output tlpq_rx_hw_cfg_t hw_cfg);
        if (get_tlpq_rx_mapping(queue_id, channel, hw_cfg))
            return 1;
        `uvm_error("TLPQ_REG_QUEUE", $sformatf(
            "%s received unknown queue_id=%0d", operation, queue_id))
        return 0;
    endfunction

    virtual task configure_queue(
        gq_role_e role,
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned desc_size);
        tlpq_channel_e channel;
        tlpq_rx_hw_cfg_t hw_cfg;

        if (!require_rx(role, queue_id, "configure_queue") ||
            !resolve_queue(queue_id, "configure_queue", channel, hw_cfg))
            return;

        configuration_generation[queue_id]++;
        enable_armed[queue_id] = 0;
        reset_tlpq_rx(channel);
        configure_tlpq_rx(channel, base, depth, desc_size, hw_cfg);
        enable_armed[queue_id] = 1;
    endtask

    virtual task disable_queue(gq_role_e role, int unsigned queue_id);
        tlpq_channel_e channel;
        tlpq_rx_hw_cfg_t hw_cfg;

        if (!require_rx(role, queue_id, "disable_queue") ||
            !resolve_queue(queue_id, "disable_queue", channel, hw_cfg))
            return;

        // Invalidate a blocked pre-disable publish before asking the derived
        // adapter to cancel its bus operation.
        configuration_generation[queue_id]++;
        enable_armed[queue_id] = 0;
        disable_tlpq_rx(channel);
    endtask

    virtual task publish(
        gq_role_e role,
        int unsigned queue_id,
        gq_raw_ptr_t raw_tail);
        tlpq_channel_e channel;
        tlpq_rx_hw_cfg_t hw_cfg;
        longint unsigned publish_generation;

        if (!require_rx(role, queue_id, "publish") ||
            !resolve_queue(queue_id, "publish", channel, hw_cfg))
            return;
        if (raw_tail[31:16] != 0) begin
            `uvm_error("TLPQ_REG_PTR", $sformatf(
                "queue_id=%0d raw tail 0x%08h exceeds 16 bits",
                queue_id, raw_tail))
            return;
        end

        publish_generation = configuration_generation[queue_id];
        write_tlpq_rx_tail(channel, raw_tail[15:0]);
        if (enable_armed[queue_id] &&
            configuration_generation[queue_id] == publish_generation) begin
            // Clear before the timed callback so another publish cannot
            // observe the arm while enable_tlpq_rx() is in progress.
            enable_armed[queue_id] = 0;
            enable_tlpq_rx(channel);
        end
    endtask

    virtual task wait_irq(gq_role_e role, int unsigned queue_id);
        tlpq_channel_e channel;
        tlpq_rx_hw_cfg_t hw_cfg;

        if (!require_rx(role, queue_id, "wait_irq") ||
            !resolve_queue(queue_id, "wait_irq", channel, hw_cfg))
            return;
        wait_tlpq_rx_irq(channel);
    endtask

    virtual task ack_irq(gq_role_e role, int unsigned queue_id);
        tlpq_channel_e channel;
        tlpq_rx_hw_cfg_t hw_cfg;

        if (!require_rx(role, queue_id, "ack_irq") ||
            !resolve_queue(queue_id, "ack_irq", channel, hw_cfg))
            return;
        ack_tlpq_rx_irq(channel);
    endtask
endclass

`endif
