`ifndef CMDQ_MOCK_ADAPTER_SV
`define CMDQ_MOCK_ADAPTER_SV

class cmdq_mock_adapter extends cmdq_reg_adapter;
    `uvm_object_utils(cmdq_mock_adapter)

    string trace[$];
    gq_addr_t configured_base[int unsigned];
    int unsigned configured_depth[int unsigned];
    int unsigned configured_desc_size[int unsigned];
    cmdq_hw_cfg_t configured_hw_cfg[int unsigned];
    bit [15:0] published_tails[int unsigned][$];
    int unsigned reset_count[int unsigned];
    int unsigned configure_count[int unsigned];
    int unsigned enable_count[int unsigned];
    int unsigned disable_count[int unsigned];
    int unsigned publish_count[int unsigned];
    int unsigned wait_irq_count[int unsigned];
    int unsigned ack_irq_count[int unsigned];
    int unsigned trigger_irq_count[int unsigned];
    uvm_event irq_events[int unsigned];

    function new(string name = "cmdq_mock_adapter",
                 cmdq_hw_cfg_t hw_cfg = '0);
        super.new(name, hw_cfg);
    endfunction

    function void clear_trace();
        trace.delete();
    endfunction

    function void trigger_irq(int unsigned queue_id);
        if (!irq_events.exists(queue_id))
            irq_events[queue_id] = new($sformatf("cmdq_%0d_irq", queue_id));
        trigger_irq_count[queue_id]++;
        irq_events[queue_id].trigger();
    endfunction

    virtual task reset_cmdq(int unsigned queue_id);
        trace.push_back($sformatf("RESET(queue=%0d)", queue_id));
        reset_count[queue_id]++;
        if (irq_events.exists(queue_id))
            irq_events[queue_id].reset();
    endtask

    virtual task configure_cmdq_registers(
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned desc_size,
        cmdq_hw_cfg_t hw_cfg);
        trace.push_back($sformatf(
            {"CONFIGURE(queue=%0d,base=0x%016h,depth=%0d,size=%0d,",
             "hid=0x%02h,fid=0x%04h,msix=0x%04h,valid=%0b)"},
            queue_id, base, depth, desc_size, hw_cfg.host_id,
            hw_cfg.function_id, hw_cfg.msix_index, hw_cfg.msix_valid));
        configure_count[queue_id]++;
        configured_base[queue_id] = base;
        configured_depth[queue_id] = depth;
        configured_desc_size[queue_id] = desc_size;
        configured_hw_cfg[queue_id] = hw_cfg;
        if (!irq_events.exists(queue_id))
            irq_events[queue_id] = new($sformatf("cmdq_%0d_irq", queue_id));
    endtask

    virtual task enable_cmdq(int unsigned queue_id);
        trace.push_back($sformatf("ENABLE(queue=%0d)", queue_id));
        enable_count[queue_id]++;
        if (!irq_events.exists(queue_id))
            irq_events[queue_id] = new($sformatf("cmdq_%0d_irq", queue_id));
    endtask

    virtual task disable_cmdq(int unsigned queue_id);
        trace.push_back($sformatf("DISABLE(queue=%0d)", queue_id));
        disable_count[queue_id]++;
        if (irq_events.exists(queue_id))
            irq_events[queue_id].reset();
    endtask

    virtual task write_cmdq_tail(int unsigned queue_id, bit [15:0] tail);
        trace.push_back($sformatf(
            "PUBLISH(queue=%0d,tail=0x%04h)", queue_id, tail));
        publish_count[queue_id]++;
        published_tails[queue_id].push_back(tail);
    endtask

    virtual task wait_cmdq_irq(int unsigned queue_id);
        trace.push_back($sformatf("WAIT_IRQ(queue=%0d)", queue_id));
        wait_irq_count[queue_id]++;
        if (!irq_events.exists(queue_id))
            irq_events[queue_id] = new($sformatf("cmdq_%0d_irq", queue_id));
        irq_events[queue_id].wait_on();
    endtask

    virtual task ack_cmdq_irq(int unsigned queue_id);
        trace.push_back($sformatf("ACK_IRQ(queue=%0d)", queue_id));
        ack_irq_count[queue_id]++;
        if (irq_events.exists(queue_id))
            irq_events[queue_id].reset();
    endtask
endclass

`endif
