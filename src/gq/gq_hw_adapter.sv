// src/gq/gq_hw_adapter.sv: 通用引擎使用的语义硬件边界，负责配置、发布、等待和禁用操作。
`ifndef GQ_HW_ADAPTER_SV
`define GQ_HW_ADAPTER_SV

virtual class gq_hw_adapter extends uvm_object;
    function new(string name = "gq_hw_adapter");
        super.new(name);
    endfunction

    // publish() may block in a concrete bus/DUT adapter. disable_queue() must be
    // callable concurrently for the same role/queue, must cause such a publish to
    // return, and must prevent its pre-disable tail update from becoming visible
    // after disable returns. The engine waits for publish completion before it
    // frees or reuses queue memory.
    pure virtual task configure_queue(
        gq_role_e role,
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned desc_size);

    pure virtual task disable_queue(gq_role_e role, int unsigned queue_id);

    pure virtual task publish(
        gq_role_e role,
        int unsigned queue_id,
        gq_raw_ptr_t raw_tail);

    pure virtual task wait_irq(gq_role_e role, int unsigned queue_id);
    pure virtual task ack_irq(gq_role_e role, int unsigned queue_id);
endclass

`endif
