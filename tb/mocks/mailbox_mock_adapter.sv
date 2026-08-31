`ifndef MAILBOX_MOCK_ADAPTER_SV
`define MAILBOX_MOCK_ADAPTER_SV

class mailbox_mock_adapter extends gq_hw_adapter;
    `uvm_object_utils(mailbox_mock_adapter)

    int unsigned configure_calls;
    int unsigned disable_calls;
    int unsigned publish_calls;
    int unsigned wait_irq_calls;
    int unsigned ack_irq_calls;
    int unsigned configure_count[string];
    int unsigned disable_count[string];
    int unsigned publish_count[string];
    int unsigned wait_irq_count[string];
    gq_addr_t configured_base[string];
    int unsigned configured_depth[string];
    int unsigned configured_desc_size[string];
    gq_raw_ptr_t published_tails[string][$];
    int unsigned directed_completed_counts[string][$];
    uvm_event irq_events[string];

    function new(string name = "mailbox_mock_adapter");
        super.new(name);
        configure_calls = 0;
        disable_calls   = 0;
        publish_calls   = 0;
        wait_irq_calls  = 0;
        ack_irq_calls   = 0;
    endfunction

    virtual task configure_queue(
        gq_role_e role,
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned desc_size);
        string key;

        key = gq_queue_key(role, queue_id);
        configure_calls++;
        configure_count[key]++;
        configured_base[key]      = base;
        configured_depth[key]     = depth;
        configured_desc_size[key] = desc_size;
        if (!irq_events.exists(key))
            irq_events[key] = new({key, "_irq"});
    endtask

    virtual task disable_queue(gq_role_e role, int unsigned queue_id);
        string key;

        key = gq_queue_key(role, queue_id);
        disable_calls++;
        disable_count[key]++;
        if (irq_events.exists(key))
            irq_events[key].reset();
    endtask

    virtual task publish(
        gq_role_e role,
        int unsigned queue_id,
        gq_raw_ptr_t raw_tail);
        string key;

        key = gq_queue_key(role, queue_id);
        publish_calls++;
        publish_count[key]++;
        published_tails[key].push_back(raw_tail);
    endtask

    virtual task wait_irq(gq_role_e role, int unsigned queue_id);
        string key;

        key = gq_queue_key(role, queue_id);
        wait_irq_calls++;
        wait_irq_count[key]++;
        if (!irq_events.exists(key))
            irq_events[key] = new({key, "_irq"});
        irq_events[key].wait_on();
    endtask

    virtual task ack_irq(gq_role_e role, int unsigned queue_id);
        string key;

        key = gq_queue_key(role, queue_id);
        ack_irq_calls++;
        if (irq_events.exists(key))
            irq_events[key].reset();
    endtask

    function void trigger_irq(gq_role_e role, int unsigned queue_id);
        string key;

        key = gq_queue_key(role, queue_id);
        if (!irq_events.exists(key))
            irq_events[key] = new({key, "_irq"});
        irq_events[key].trigger();
    endfunction

    function void report_directed_completions(
        gq_role_e role, int unsigned queue_id, int unsigned completed_count);
        directed_completed_counts[gq_queue_key(role, queue_id)].push_back(
            completed_count);
    endfunction

    function bit take_directed_completions(
        gq_role_e role,
        int unsigned queue_id,
        output int unsigned completed_count);
        string key;

        key = gq_queue_key(role, queue_id);
        if (!directed_completed_counts.exists(key) ||
            directed_completed_counts[key].size() == 0) begin
            completed_count = 0;
            return 1;
        end
        completed_count = directed_completed_counts[key].pop_front();
        return 1;
    endfunction
endclass

// Protocol-neutral directed completion source for engine lifecycle tests. It
// reports queued counts without reading or interpreting descriptor bytes.
class gq_directed_completion_source extends gq_completion_source;
    `uvm_object_utils(gq_directed_completion_source)

    gq_role_e role;
    int unsigned queue_id;

    function new(string name = "gq_directed_completion_source");
        super.new(name);
        role = GQ_RX;
        queue_id = 0;
    endfunction

    virtual task query_completed(
        host_mem_api mem,
        gq_hw_adapter adapter,
        gq_addr_t ring_base,
        gq_addr_t status_addr,
        int unsigned depth,
        int unsigned desc_size,
        gq_logical_seq_t logical_head,
        input gq_desc_base pending[$],
        output bit valid,
        output int unsigned completed_count);
        mailbox_mock_adapter directed_adapter;

        valid = 0;
        completed_count = 0;
        if (!$cast(directed_adapter, adapter))
            return;
        valid = directed_adapter.take_directed_completions(
            role, queue_id, completed_count);
    endtask
endclass

`endif
