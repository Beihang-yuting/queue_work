// tb/mocks/msgq_mock_adapter.sv: 记录寄存器操作并可编程推进当前指针的 MSGQ 模拟适配器。
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
    int unsigned reset_count[int unsigned];
    int unsigned configure_count[int unsigned];
    int unsigned enable_count[int unsigned];
    int unsigned disable_count[int unsigned];
    int unsigned trigger_irq_count[int unsigned];
    int unsigned failed_current_ptr_read_count[int unsigned];
    int unsigned blocked_current_ptr_read_count[int unsigned];
    bit current_ptr_valid[int unsigned];
    bit [15:0] current_ptr_value[int unsigned];
    bit fail_next_current_ptr_read[int unsigned];
    bit block_current_ptr_read_once[int unsigned];
    uvm_event irq_events[int unsigned];
    uvm_event current_ptr_read_entered[int unsigned];
    uvm_event current_ptr_read_release[int unsigned];

    function new(string name = "msgq_mock_adapter");
        super.new(name);
    endfunction

    function void clear_trace();
        trace.delete();
    endfunction

    function void record_reset(int unsigned queue_id);
        trace.push_back("RESET");
        reset_count[queue_id]++;
        current_ptr_valid[queue_id] = 0;
        current_ptr_value[queue_id] = 0;
        if (irq_events.exists(queue_id))
            irq_events[queue_id].reset();
    endfunction

    function void record_enable(int unsigned queue_id);
        trace.push_back("ENABLE");
        enable_count[queue_id]++;
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
        trigger_irq_count[queue_id]++;
        irq_events[queue_id].trigger();
    endfunction

    function void fail_next_read(int unsigned queue_id);
        fail_next_current_ptr_read[queue_id] = 1;
    endfunction

    function void block_next_current_ptr_read(int unsigned queue_id);
        block_current_ptr_read_once[queue_id] = 1;
        if (!current_ptr_read_entered.exists(queue_id))
            current_ptr_read_entered[queue_id] = new(
                $sformatf("msgq_%0d_current_ptr_read_entered", queue_id));
        if (!current_ptr_read_release.exists(queue_id))
            current_ptr_read_release[queue_id] = new(
                $sformatf("msgq_%0d_current_ptr_read_release", queue_id));
        current_ptr_read_entered[queue_id].reset();
        current_ptr_read_release[queue_id].reset();
    endfunction

    function void release_current_ptr_read(int unsigned queue_id);
        if (!current_ptr_read_release.exists(queue_id))
            current_ptr_read_release[queue_id] = new(
                $sformatf("msgq_%0d_current_ptr_read_release", queue_id));
        current_ptr_read_release[queue_id].trigger();
    endfunction

    virtual task configure_msgq_registers(
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned entry_size);
        trace.push_back("CONFIGURE");
        configure_count[queue_id]++;
        configured_base[queue_id] = base;
        configured_depth[queue_id] = depth;
        configured_entry_size[queue_id] = entry_size;
        if (!irq_events.exists(queue_id))
            irq_events[queue_id] = new($sformatf("msgq_%0d_irq", queue_id));
    endtask

    virtual task disable_msgq_registers(int unsigned queue_id);
        trace.push_back("DISABLE");
        disable_count[queue_id]++;
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
        bit captured_valid;
        bit [15:0] captured_ptr;
        bit captured_failure;

        trace.push_back("READ_CURRENT_PTR");
        read_current_ptr_count[queue_id]++;
        captured_valid = current_ptr_valid.exists(queue_id) ?
                         current_ptr_valid[queue_id] : 0;
        captured_ptr = current_ptr_value.exists(queue_id) ?
                       current_ptr_value[queue_id] : 0;
        captured_failure = fail_next_current_ptr_read.exists(queue_id) &&
                           fail_next_current_ptr_read[queue_id];
        if (captured_failure) begin
            fail_next_current_ptr_read[queue_id] = 0;
            failed_current_ptr_read_count[queue_id]++;
        end
        if (block_current_ptr_read_once.exists(queue_id) &&
            block_current_ptr_read_once[queue_id]) begin
            block_current_ptr_read_once[queue_id] = 0;
            blocked_current_ptr_read_count[queue_id]++;
            if (!current_ptr_read_entered.exists(queue_id))
                current_ptr_read_entered[queue_id] = new(
                    $sformatf("msgq_%0d_current_ptr_read_entered", queue_id));
            if (!current_ptr_read_release.exists(queue_id))
                current_ptr_read_release[queue_id] = new(
                    $sformatf("msgq_%0d_current_ptr_read_release", queue_id));
            current_ptr_read_entered[queue_id].trigger();
            current_ptr_read_release[queue_id].wait_on();
        end
        valid = captured_failure ? 0 : captured_valid;
        current_ptr = captured_ptr;
    endtask
endclass

`endif
