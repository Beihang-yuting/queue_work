`ifndef MAILBOX_MOCK_ADAPTER_SVH
`define MAILBOX_MOCK_ADAPTER_SVH

class mailbox_mock_adapter extends gq_hw_adapter;
    `uvm_object_utils(mailbox_mock_adapter)

    int unsigned configure_calls;
    int unsigned disable_calls;
    int unsigned publish_calls;
    int unsigned configure_count[string];
    int unsigned disable_count[string];
    int unsigned publish_count[string];
    gq_addr_t configured_base[string];
    int unsigned configured_depth[string];
    int unsigned configured_desc_size[string];
    gq_raw_ptr_t published_tails[string][$];
    uvm_event irq_events[string];

    function new(string name = "mailbox_mock_adapter");
        super.new(name);
        configure_calls = 0;
        disable_calls   = 0;
        publish_calls   = 0;
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
        if (!irq_events.exists(key))
            irq_events[key] = new({key, "_irq"});
        irq_events[key].wait_on();
    endtask

    virtual task ack_irq(gq_role_e role, int unsigned queue_id);
        string key;

        key = gq_queue_key(role, queue_id);
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
endclass

`endif
