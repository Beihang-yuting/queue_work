`ifndef TLPQ_MOCK_ADAPTER_SV
`define TLPQ_MOCK_ADAPTER_SV

class tlpq_mock_adapter extends tlpq_reg_adapter;
    `uvm_object_utils(tlpq_mock_adapter)

    string trace[int][$];
    gq_addr_t configured_base[int];
    int unsigned configured_depth[int];
    int unsigned configured_desc_size[int];
    tlpq_rx_hw_cfg_t configured_hw_cfg[int];
    bit [15:0] published_tails[int][$];
    int unsigned reset_count[int];
    int unsigned configure_count[int];
    int unsigned enable_count[int];
    int unsigned disable_count[int];
    int unsigned wait_irq_count[int];
    int unsigned ack_irq_count[int];
    int unsigned trigger_irq_count[int];
    uvm_event irq_events[int];

    function new(string name = "tlpq_mock_adapter");
        super.new(name);
    endfunction

    protected function string channel_name(tlpq_channel_e channel);
        return channel == TLPQ_HOST ? "HOST" : "SWITCH";
    endfunction

    protected function void ensure_irq_event(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        if (!irq_events.exists(channel_key))
            irq_events[channel_key] = new(
                $sformatf("tlpq_%s_irq", channel_name(channel)));
    endfunction

    function void clear_trace(tlpq_channel_e channel);
        trace[int'(channel)].delete();
    endfunction

    function void trigger_irq(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        ensure_irq_event(channel);
        trigger_irq_count[channel_key]++;
        irq_events[channel_key].trigger();
    endfunction

    virtual task reset_tlpq_rx(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        trace[channel_key].push_back($sformatf(
            "RESET(channel=%s)", channel_name(channel)));
        reset_count[channel_key]++;
        ensure_irq_event(channel);
        irq_events[channel_key].reset();
    endtask

    virtual task configure_tlpq_rx(
        tlpq_channel_e channel, gq_addr_t base, int unsigned depth,
        int unsigned desc_size, tlpq_rx_hw_cfg_t hw_cfg);
        int channel_key;

        channel_key = int'(channel);
        trace[channel_key].push_back($sformatf(
            {"CONFIGURE(channel=%s,base=0x%016h,depth=%0d,size=%0d,",
             "host_id=0x%01h,bdf=0x%04h,msix=0x%04h,valid=%0b)"},
            channel_name(channel), base, depth, desc_size, hw_cfg.host_id,
            hw_cfg.bdf, hw_cfg.msix_index, hw_cfg.msix_valid));
        configure_count[channel_key]++;
        configured_base[channel_key] = base;
        configured_depth[channel_key] = depth;
        configured_desc_size[channel_key] = desc_size;
        configured_hw_cfg[channel_key] = hw_cfg;
        ensure_irq_event(channel);
    endtask

    virtual task enable_tlpq_rx(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        trace[channel_key].push_back($sformatf(
            "ENABLE(channel=%s)", channel_name(channel)));
        enable_count[channel_key]++;
        ensure_irq_event(channel);
    endtask

    virtual task disable_tlpq_rx(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        trace[channel_key].push_back($sformatf(
            "DISABLE(channel=%s)", channel_name(channel)));
        disable_count[channel_key]++;
        if (irq_events.exists(channel_key))
            irq_events[channel_key].reset();
    endtask

    virtual task write_tlpq_rx_tail(
        tlpq_channel_e channel, bit [15:0] tail);
        int channel_key;

        channel_key = int'(channel);
        trace[channel_key].push_back($sformatf(
            "PUBLISH(channel=%s,tail=%0d)", channel_name(channel), tail));
        published_tails[channel_key].push_back(tail);
    endtask

    virtual task wait_tlpq_rx_irq(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        trace[channel_key].push_back($sformatf(
            "WAIT_IRQ(channel=%s)", channel_name(channel)));
        wait_irq_count[channel_key]++;
        ensure_irq_event(channel);
        irq_events[channel_key].wait_on();
    endtask

    virtual task ack_tlpq_rx_irq(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        trace[channel_key].push_back($sformatf(
            "ACK_IRQ(channel=%s)", channel_name(channel)));
        ack_irq_count[channel_key]++;
        if (irq_events.exists(channel_key))
            irq_events[channel_key].reset();
    endtask
endclass

`endif
