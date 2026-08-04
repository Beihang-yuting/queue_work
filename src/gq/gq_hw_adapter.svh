`ifndef GQ_HW_ADAPTER_SVH
`define GQ_HW_ADAPTER_SVH

virtual class gq_hw_adapter extends uvm_object;
    function new(string name = "gq_hw_adapter");
        super.new(name);
    endfunction

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
