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
    uvm_event publish_events[int];
    uvm_event irq_wait_events[int];
    uvm_event irq_ack_blocked[int];
    uvm_event irq_ack_release[int];
    bit block_irq_ack_once[int];
    time wait_irq_times[int][$];
    time trigger_irq_times[int][$];
    time ack_irq_times[int][$];
    int unsigned cancellation_epoch[int];
    bit block_configure_once[int];
    bit block_publish_once[int];
    bit block_enable_once[int];
    uvm_event configure_entered[int];
    uvm_event configure_release[int];
    uvm_event publish_entered[int];
    uvm_event publish_release[int];
    uvm_event enable_entered[int];
    uvm_event enable_release[int];

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
        if (!publish_events.exists(channel_key))
            publish_events[channel_key] = new(
                $sformatf("tlpq_%s_publish", channel_name(channel)));
        if (!irq_wait_events.exists(channel_key))
            irq_wait_events[channel_key] = new(
                $sformatf("tlpq_%s_irq_wait", channel_name(channel)));
        if (!irq_ack_blocked.exists(channel_key))
            irq_ack_blocked[channel_key] = new(
                $sformatf("tlpq_%s_irq_ack_blocked",
                          channel_name(channel)));
        if (!irq_ack_release.exists(channel_key))
            irq_ack_release[channel_key] = new(
                $sformatf("tlpq_%s_irq_ack_release",
                          channel_name(channel)));
    endfunction

    protected function void ensure_barrier_events(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        if (!configure_entered.exists(channel_key))
            configure_entered[channel_key] = new(
                $sformatf("tlpq_%s_configure_entered",
                          channel_name(channel)));
        if (!configure_release.exists(channel_key))
            configure_release[channel_key] = new(
                $sformatf("tlpq_%s_configure_release",
                          channel_name(channel)));
        if (!publish_entered.exists(channel_key))
            publish_entered[channel_key] = new(
                $sformatf("tlpq_%s_publish_entered",
                          channel_name(channel)));
        if (!publish_release.exists(channel_key))
            publish_release[channel_key] = new(
                $sformatf("tlpq_%s_publish_release",
                          channel_name(channel)));
        if (!enable_entered.exists(channel_key))
            enable_entered[channel_key] = new(
                $sformatf("tlpq_%s_enable_entered",
                          channel_name(channel)));
        if (!enable_release.exists(channel_key))
            enable_release[channel_key] = new(
                $sformatf("tlpq_%s_enable_release",
                          channel_name(channel)));
    endfunction

    function void block_next_configure(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        ensure_barrier_events(channel);
        block_configure_once[channel_key] = 1;
        configure_entered[channel_key].reset();
        configure_release[channel_key].reset();
    endfunction

    function void release_configure(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        ensure_barrier_events(channel);
        configure_release[channel_key].trigger();
    endfunction

    function void block_next_publish(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        ensure_barrier_events(channel);
        block_publish_once[channel_key] = 1;
        publish_entered[channel_key].reset();
        publish_release[channel_key].reset();
    endfunction

    function void release_publish(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        ensure_barrier_events(channel);
        publish_release[channel_key].trigger();
    endfunction

    function void block_next_enable(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        ensure_barrier_events(channel);
        block_enable_once[channel_key] = 1;
        enable_entered[channel_key].reset();
        enable_release[channel_key].reset();
    endfunction

    function void clear_trace(tlpq_channel_e channel);
        trace[int'(channel)].delete();
    endfunction

    function void trigger_irq(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        ensure_irq_event(channel);
        trigger_irq_count[channel_key]++;
        trigger_irq_times[channel_key].push_back($time);
        irq_events[channel_key].trigger();
    endfunction

    function void block_next_irq_ack(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        ensure_irq_event(channel);
        block_irq_ack_once[channel_key] = 1;
        irq_ack_blocked[channel_key].reset();
        irq_ack_release[channel_key].reset();
    endfunction

    function void release_irq_ack(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        ensure_irq_event(channel);
        irq_ack_release[channel_key].trigger();
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
        int unsigned captured_epoch;

        channel_key = int'(channel);
        captured_epoch = cancellation_epoch[channel_key];
        ensure_barrier_events(channel);
        if (block_configure_once.exists(channel_key) &&
            block_configure_once[channel_key]) begin
            block_configure_once[channel_key] = 0;
            configure_entered[channel_key].trigger();
            configure_release[channel_key].wait_on();
        end
        if (cancellation_epoch[channel_key] != captured_epoch)
            return;
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
        int unsigned captured_epoch;

        channel_key = int'(channel);
        captured_epoch = cancellation_epoch[channel_key];
        ensure_barrier_events(channel);
        if (block_enable_once.exists(channel_key) &&
            block_enable_once[channel_key]) begin
            block_enable_once[channel_key] = 0;
            enable_entered[channel_key].trigger();
            enable_release[channel_key].wait_on();
        end
        if (cancellation_epoch[channel_key] != captured_epoch)
            return;
        trace[channel_key].push_back($sformatf(
            "ENABLE(channel=%s)", channel_name(channel)));
        enable_count[channel_key]++;
        ensure_irq_event(channel);
    endtask

    virtual task disable_tlpq_rx(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        cancellation_epoch[channel_key]++;
        ensure_barrier_events(channel);
        configure_release[channel_key].trigger();
        publish_release[channel_key].trigger();
        enable_release[channel_key].trigger();
        trace[channel_key].push_back($sformatf(
            "DISABLE(channel=%s)", channel_name(channel)));
        disable_count[channel_key]++;
        if (irq_events.exists(channel_key))
            irq_events[channel_key].reset();
    endtask

    virtual task write_tlpq_rx_tail(
        tlpq_channel_e channel, bit [15:0] tail);
        int channel_key;
        int unsigned captured_epoch;

        channel_key = int'(channel);
        captured_epoch = cancellation_epoch[channel_key];
        ensure_barrier_events(channel);
        if (block_publish_once.exists(channel_key) &&
            block_publish_once[channel_key]) begin
            block_publish_once[channel_key] = 0;
            publish_entered[channel_key].trigger();
            publish_release[channel_key].wait_on();
        end
        if (cancellation_epoch[channel_key] != captured_epoch)
            return;
        trace[channel_key].push_back($sformatf(
            "PUBLISH(channel=%s,tail=%0d)", channel_name(channel), tail));
        published_tails[channel_key].push_back(tail);
        publish_events[channel_key].trigger();
    endtask

    virtual task wait_tlpq_rx_irq(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        trace[channel_key].push_back($sformatf(
            "WAIT_IRQ(channel=%s)", channel_name(channel)));
        wait_irq_count[channel_key]++;
        wait_irq_times[channel_key].push_back($time);
        ensure_irq_event(channel);
        irq_wait_events[channel_key].trigger();
        irq_events[channel_key].wait_on();
    endtask

    virtual task ack_tlpq_rx_irq(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        trace[channel_key].push_back($sformatf(
            "ACK_IRQ(channel=%s)", channel_name(channel)));
        ack_irq_count[channel_key]++;
        ack_irq_times[channel_key].push_back($time);
        ensure_irq_event(channel);
        if (block_irq_ack_once.exists(channel_key) &&
            block_irq_ack_once[channel_key]) begin
            block_irq_ack_once[channel_key] = 0;
            irq_ack_blocked[channel_key].trigger();
            irq_ack_release[channel_key].wait_on();
        end
        if (irq_events.exists(channel_key))
            irq_events[channel_key].reset();
    endtask
endclass

`endif
