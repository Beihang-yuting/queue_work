// tb/mocks/dmaq_mock_adapter.sv: 记录语义操作并检查借用缓存行为的 DMAQ 模拟适配器。
`ifndef DMAQ_MOCK_ADAPTER_SV
`define DMAQ_MOCK_ADAPTER_SV

class dmaq_mock_adapter extends dmaq_reg_adapter;
    `uvm_object_utils(dmaq_mock_adapter)

    host_mem_api mem;
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
    int unsigned trigger_irq_count[int unsigned];
    int unsigned publish_inspection_count[int unsigned];
    byte last_published_slot[int unsigned][];
    uvm_event irq_events[int unsigned];
    uvm_event irq_cancel_events[int unsigned];
    uvm_event publish_events[int unsigned];
    uvm_event irq_wait_events[int unsigned];
    uvm_event disable_events[int unsigned];
    uvm_event irq_ack_blocked[int unsigned];
    uvm_event irq_ack_release[int unsigned];
    uvm_event publish_blocked[int unsigned];
    uvm_event publish_release[int unsigned];
    uvm_event publish_returned[int unsigned];
    bit block_irq_ack_once[int unsigned];
    bit block_publish_once[int unsigned];

    function new(string name = "dmaq_mock_adapter");
        super.new(name);
        mem = null;
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
        if (!publish_events.exists(queue_id))
            publish_events[queue_id] = new(
                $sformatf("dmaq_%0d_publish", queue_id));
        if (!irq_wait_events.exists(queue_id))
            irq_wait_events[queue_id] = new(
                $sformatf("dmaq_%0d_irq_wait", queue_id));
        if (!disable_events.exists(queue_id))
            disable_events[queue_id] = new(
                $sformatf("dmaq_%0d_disable", queue_id));
        if (!irq_ack_blocked.exists(queue_id))
            irq_ack_blocked[queue_id] = new(
                $sformatf("dmaq_%0d_irq_ack_blocked", queue_id));
        if (!irq_ack_release.exists(queue_id))
            irq_ack_release[queue_id] = new(
                $sformatf("dmaq_%0d_irq_ack_release", queue_id));
        if (!publish_blocked.exists(queue_id))
            publish_blocked[queue_id] = new(
                $sformatf("dmaq_%0d_publish_blocked", queue_id));
        if (!publish_release.exists(queue_id))
            publish_release[queue_id] = new(
                $sformatf("dmaq_%0d_publish_release", queue_id));
        if (!publish_returned.exists(queue_id))
            publish_returned[queue_id] = new(
                $sformatf("dmaq_%0d_publish_returned", queue_id));
    endfunction

    function void trigger_irq(int unsigned queue_id);
        ensure_events(queue_id);
        trigger_irq_count[queue_id]++;
        irq_events[queue_id].trigger();
    endfunction

    function void block_next_irq_ack(int unsigned queue_id);
        ensure_events(queue_id);
        block_irq_ack_once[queue_id] = 1;
        irq_ack_blocked[queue_id].reset();
        irq_ack_release[queue_id].reset();
    endfunction

    function void release_irq_ack(int unsigned queue_id);
        ensure_events(queue_id);
        irq_ack_release[queue_id].trigger();
    endfunction

    function void block_next_publish(int unsigned queue_id);
        ensure_events(queue_id);
        block_publish_once[queue_id] = 1;
        publish_blocked[queue_id].reset();
        publish_release[queue_id].reset();
        publish_returned[queue_id].reset();
    endfunction

    function void release_publish(int unsigned queue_id);
        ensure_events(queue_id);
        publish_release[queue_id].trigger();
    endfunction

    virtual task reset_dmaq(int unsigned queue_id);
        trace.push_back($sformatf("RESET(queue=%0d)", queue_id));
        reset_count[queue_id]++;
        ensure_events(queue_id);
        irq_events[queue_id].reset();
        irq_cancel_events[queue_id].reset();
        publish_release[queue_id].reset();
        block_irq_ack_once[queue_id] = 0;
        block_publish_once[queue_id] = 0;
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
        publish_release[queue_id].trigger();
        disable_events[queue_id].trigger();
    endtask

    virtual task write_dmaq_tail(int unsigned queue_id, bit [15:0] tail);
        byte committed_slot[];
        int unsigned raw_index;
        int unsigned physical_slot;
        int unsigned disable_before;
        bit block_this_publish;
        bit publish_cancelled;

        ensure_events(queue_id);
        committed_slot = new[0];
        if (mem != null && configured_base.exists(queue_id) &&
            configured_depth.exists(queue_id) &&
            configured_depth[queue_id] != 0 &&
            configured_desc_size.exists(queue_id) &&
            configured_desc_size[queue_id] == DMAQ_DESC_BYTES) begin
            raw_index = tail[14:0];
            if (raw_index == 0)
                physical_slot = configured_depth[queue_id] - 1;
            else
                physical_slot = raw_index - 1;
            mem.read_mem(configured_base[queue_id] +
                         (physical_slot * DMAQ_DESC_BYTES),
                         DMAQ_DESC_BYTES, committed_slot,
                         `__FILE__, `__LINE__);
            last_published_slot[queue_id] = new[committed_slot.size()];
            foreach (committed_slot[i])
                last_published_slot[queue_id][i] = committed_slot[i];
            publish_inspection_count[queue_id]++;
        end

        disable_before = disable_count.exists(queue_id) ?
                         disable_count[queue_id] : 0;
        block_this_publish = block_publish_once.exists(queue_id) &&
                             block_publish_once[queue_id];
        if (block_this_publish) begin
            block_publish_once[queue_id] = 0;
            publish_blocked[queue_id].trigger();
            publish_release[queue_id].wait_on();
        end
        publish_cancelled = block_this_publish &&
            disable_count.exists(queue_id) &&
            disable_count[queue_id] != disable_before;
        if (!publish_cancelled) begin
            trace.push_back($sformatf("PUBLISH(queue=%0d,tail=0x%04h)",
                                      queue_id, tail));
            publish_count[queue_id]++;
            published_tails[queue_id].push_back(tail);
            publish_events[queue_id].trigger();
        end
        publish_returned[queue_id].trigger();
    endtask

    virtual task wait_dmaq_irq(int unsigned queue_id);
        trace.push_back($sformatf("WAIT_IRQ(queue=%0d)", queue_id));
        wait_irq_count[queue_id]++;
        ensure_events(queue_id);
        irq_wait_events[queue_id].trigger();
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
        if (block_irq_ack_once.exists(queue_id) &&
            block_irq_ack_once[queue_id]) begin
            block_irq_ack_once[queue_id] = 0;
            irq_ack_blocked[queue_id].trigger();
            irq_ack_release[queue_id].wait_on();
        end
        irq_events[queue_id].reset();
    endtask
endclass

`endif
