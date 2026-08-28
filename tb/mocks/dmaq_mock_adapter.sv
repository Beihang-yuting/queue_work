`ifndef DMAQ_MOCK_ADAPTER_SV
`define DMAQ_MOCK_ADAPTER_SV

class dmaq_mock_adapter extends dmaq_reg_adapter;
    `uvm_object_utils(dmaq_mock_adapter)

    string trace[$];
    gq_addr_t configured_base[int unsigned];
    int unsigned configured_depth[int unsigned];
    int unsigned configured_desc_size[int unsigned];
    dmaq_hw_cfg_t configured_hw_cfg[int unsigned];
    bit [15:0] published_tails[int unsigned][$];
    int unsigned reset_count[int unsigned];
    int unsigned configure_count[int unsigned];
    int unsigned enable_count[int unsigned];
    int unsigned disable_count[int unsigned];
    int unsigned publish_count[int unsigned];
    int unsigned wait_irq_count[int unsigned];
    int unsigned ack_irq_count[int unsigned];
    uvm_event irq_events[int unsigned];
    uvm_event irq_cancel_events[int unsigned];

    function new(string name = "dmaq_mock_adapter",
                 dmaq_hw_cfg_t hw_cfg = '0);
        super.new(name, hw_cfg);
    endfunction

    function void clear_trace();
        trace.delete();
    endfunction

    protected function void ensure_events(int unsigned queue_id);
        if (!irq_events.exists(queue_id))
            irq_events[queue_id] = new($sformatf("dmaq_%0d_irq", queue_id));
        if (!irq_cancel_events.exists(queue_id))
            irq_cancel_events[queue_id] = new(
                $sformatf("dmaq_%0d_irq_cancel", queue_id));
    endfunction

    function void trigger_irq(int unsigned queue_id);
        ensure_events(queue_id);
        irq_events[queue_id].trigger();
    endfunction

    virtual task reset_dmaq(int unsigned queue_id);
        trace.push_back($sformatf("RESET(queue=%0d)", queue_id));
        reset_count[queue_id]++;
        ensure_events(queue_id);
        irq_events[queue_id].reset();
        irq_cancel_events[queue_id].reset();
    endtask

    virtual task configure_dmaq_registers(int unsigned queue_id,
                                           gq_addr_t base,
                                           int unsigned depth,
                                           int unsigned desc_size,
                                           dmaq_hw_cfg_t hw_cfg);
        trace.push_back($sformatf(
            {"CONFIGURE(queue=%0d,base=0x%016h,depth=%0d,size=%0d,",
             "hid=0x%08h,bdf=0x%04h,msix=0x%04h,valid=%0b)"},
            queue_id, base, depth, desc_size, hw_cfg.queue_hid,
            hw_cfg.queue_bdf, hw_cfg.msix_index, hw_cfg.msix_valid));
        configure_count[queue_id]++;
        configured_base[queue_id] = base;
        configured_depth[queue_id] = depth;
        configured_desc_size[queue_id] = desc_size;
        configured_hw_cfg[queue_id] = hw_cfg;
        ensure_events(queue_id);
    endtask

    virtual task enable_dmaq(int unsigned queue_id);
        trace.push_back($sformatf("ENABLE(queue=%0d)", queue_id));
        enable_count[queue_id]++;
        ensure_events(queue_id);
    endtask

    virtual task disable_dmaq(int unsigned queue_id);
        trace.push_back($sformatf("DISABLE(queue=%0d)", queue_id));
        disable_count[queue_id]++;
        ensure_events(queue_id);
        irq_events[queue_id].reset();
        irq_cancel_events[queue_id].trigger();
    endtask

    virtual task write_dmaq_tail(int unsigned queue_id, bit [15:0] tail);
        trace.push_back($sformatf("PUBLISH(queue=%0d,tail=0x%04h)",
                                  queue_id, tail));
        publish_count[queue_id]++;
        published_tails[queue_id].push_back(tail);
        ensure_events(queue_id);
    endtask

    virtual task wait_dmaq_irq(int unsigned queue_id);
        trace.push_back($sformatf("WAIT_IRQ(queue=%0d)", queue_id));
        wait_irq_count[queue_id]++;
        ensure_events(queue_id);
        fork
            begin
                irq_events[queue_id].wait_on();
            end
            begin
                irq_cancel_events[queue_id].wait_on();
            end
        join_any
        disable fork;
    endtask

    virtual task ack_dmaq_irq(int unsigned queue_id);
        trace.push_back($sformatf("ACK_IRQ(queue=%0d)", queue_id));
        ack_irq_count[queue_id]++;
        ensure_events(queue_id);
        irq_events[queue_id].reset();
    endtask
endclass

`endif
