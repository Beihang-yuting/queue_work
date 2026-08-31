`ifndef MSGQ_REG_ADAPTER_SV
`define MSGQ_REG_ADAPTER_SV

virtual class msgq_reg_adapter extends gq_hw_adapter;
    function new(string name = "msgq_reg_adapter");
        super.new(name);
    endfunction

    pure virtual task configure_msgq_registers(
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned entry_size);

    // This callback is also the cancellation path for a concurrent blocked
    // write_msgq_initial_tail() on the same logical queue ID.
    pure virtual task disable_msgq_registers(int unsigned queue_id);

    pure virtual task write_msgq_initial_tail(
        int unsigned queue_id, bit [15:0] tail);

    pure virtual task wait_msgq_irq(int unsigned queue_id);
    pure virtual task ack_msgq_irq(int unsigned queue_id);

    pure virtual task read_msgq_current_ptr(
        int unsigned queue_id,
        output bit valid,
        output bit [15:0] current_ptr);

    protected function bit require_rx(
        gq_role_e role, int unsigned queue_id, string operation);
        if (role == GQ_RX)
            return 1;
        `uvm_error("MSGQ_REG_ROLE", $sformatf(
            "%s requires role=RX for queue_id=%0d", operation, queue_id))
        return 0;
    endfunction

    virtual task configure_queue(
        gq_role_e role,
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned desc_size);
        if (!require_rx(role, queue_id, "configure_queue"))
            return;
        configure_msgq_registers(queue_id, base, depth, desc_size);
    endtask

    virtual task disable_queue(gq_role_e role, int unsigned queue_id);
        if (!require_rx(role, queue_id, "disable_queue"))
            return;
        disable_msgq_registers(queue_id);
    endtask

    virtual task publish(
        gq_role_e role,
        int unsigned queue_id,
        gq_raw_ptr_t raw_tail);
        if (!require_rx(role, queue_id, "publish"))
            return;
        if (raw_tail[31:16] != 0) begin
            `uvm_error("MSGQ_REG_PTR", $sformatf(
                "queue_id=%0d raw tail 0x%08h exceeds 16 bits",
                queue_id, raw_tail))
            return;
        end
        write_msgq_initial_tail(queue_id, raw_tail[15:0]);
    endtask

    virtual task wait_irq(gq_role_e role, int unsigned queue_id);
        if (!require_rx(role, queue_id, "wait_irq"))
            return;
        wait_msgq_irq(queue_id);
    endtask

    virtual task ack_irq(gq_role_e role, int unsigned queue_id);
        if (!require_rx(role, queue_id, "ack_irq"))
            return;
        ack_msgq_irq(queue_id);
    endtask
endclass

`endif
