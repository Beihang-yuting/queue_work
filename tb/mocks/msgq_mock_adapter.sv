`ifndef MSGQ_MOCK_ADAPTER_SV
`define MSGQ_MOCK_ADAPTER_SV

class msgq_mock_adapter extends msgq_reg_adapter;
    `uvm_object_utils(msgq_mock_adapter)

    string trace[$];
    gq_addr_t configured_base[int unsigned];
    int unsigned configured_depth[int unsigned];
    int unsigned configured_entry_size[int unsigned];
    bit [15:0] published_tails[int unsigned][$];
    int unsigned wait_irq_count[int unsigned];
    int unsigned ack_irq_count[int unsigned];
    int unsigned read_current_ptr_count[int unsigned];
    bit current_ptr_valid[int unsigned];
    bit [15:0] current_ptr_value[int unsigned];
    uvm_event irq_events[int unsigned];

    function new(string name = "msgq_mock_adapter");
        super.new(name);
    endfunction

    function void clear_trace();
        trace.delete();
    endfunction

    function void record_reset(int unsigned queue_id);
        trace.push_back("RESET");
        current_ptr_valid[queue_id] = 0;
        current_ptr_value[queue_id] = 0;
        if (irq_events.exists(queue_id))
            irq_events[queue_id].reset();
    endfunction

    function void record_enable(int unsigned queue_id);
        trace.push_back("ENABLE");
        if (!irq_events.exists(queue_id))
            irq_events[queue_id] = new($sformatf("msgq_%0d_irq", queue_id));
    endfunction

    function void set_current_ptr(
        int unsigned queue_id, bit valid, bit [15:0] pointer);
        current_ptr_valid[queue_id] = valid;
        current_ptr_value[queue_id] = pointer;
    endfunction

    function void trigger_irq(int unsigned queue_id);
        if (!irq_events.exists(queue_id))
            irq_events[queue_id] = new($sformatf("msgq_%0d_irq", queue_id));
        irq_events[queue_id].trigger();
    endfunction

    virtual task configure_msgq_registers(
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned entry_size);
        trace.push_back("CONFIGURE");
        configured_base[queue_id] = base;
        configured_depth[queue_id] = depth;
        configured_entry_size[queue_id] = entry_size;
        if (!irq_events.exists(queue_id))
            irq_events[queue_id] = new($sformatf("msgq_%0d_irq", queue_id));
    endtask

    virtual task disable_msgq_registers(int unsigned queue_id);
        trace.push_back("DISABLE");
        if (irq_events.exists(queue_id))
            irq_events[queue_id].reset();
    endtask

    virtual task write_msgq_initial_tail(
        int unsigned queue_id, bit [15:0] tail);
        trace.push_back("PUBLISH");
        published_tails[queue_id].push_back(tail);
    endtask

    virtual task wait_msgq_irq(int unsigned queue_id);
        trace.push_back("WAIT_IRQ");
        wait_irq_count[queue_id]++;
        if (!irq_events.exists(queue_id))
            irq_events[queue_id] = new($sformatf("msgq_%0d_irq", queue_id));
        irq_events[queue_id].wait_on();
    endtask

    virtual task ack_msgq_irq(int unsigned queue_id);
        trace.push_back("ACK_IRQ");
        ack_irq_count[queue_id]++;
        if (irq_events.exists(queue_id))
            irq_events[queue_id].reset();
    endtask

    virtual task read_msgq_current_ptr(
        int unsigned queue_id,
        output bit valid,
        output bit [15:0] current_ptr);
        trace.push_back("READ_CURRENT_PTR");
        read_current_ptr_count[queue_id]++;
        valid = current_ptr_valid.exists(queue_id) ?
                current_ptr_valid[queue_id] : 0;
        current_ptr = current_ptr_value.exists(queue_id) ?
                      current_ptr_value[queue_id] : 0;
    endtask
endclass

`endif
