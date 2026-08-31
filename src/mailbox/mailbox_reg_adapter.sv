`ifndef MAILBOX_REG_ADAPTER_SV
`define MAILBOX_REG_ADAPTER_SV

virtual class mailbox_reg_adapter extends gq_hw_adapter;
    function new(string name = "mailbox_reg_adapter");
        super.new(name);
    endfunction

    pure virtual task configure_mailbox_registers(
        gq_role_e role,
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned desc_size);

    // This callback is also the cancellation path for a concurrent blocked
    // write_mailbox_notify() on the same role and logical queue ID.
    pure virtual task disable_mailbox_registers(
        gq_role_e role,
        int unsigned queue_id);

    pure virtual task write_mailbox_notify(
        gq_role_e role,
        int unsigned queue_id,
        bit [15:0] raw_tail);

    pure virtual task wait_mailbox_irq(
        gq_role_e role,
        int unsigned queue_id);

    pure virtual task ack_mailbox_irq(
        gq_role_e role,
        int unsigned queue_id);

    virtual task configure_queue(
        gq_role_e role,
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned desc_size);
        configure_mailbox_registers(role, queue_id, base, depth, desc_size);
    endtask

    virtual task disable_queue(gq_role_e role, int unsigned queue_id);
        disable_mailbox_registers(role, queue_id);
    endtask

    virtual task publish(
        gq_role_e role,
        int unsigned queue_id,
        gq_raw_ptr_t raw_tail);
        if (raw_tail[31:16] != 0) begin
            `uvm_error("MAILBOX_REG_PTR", $sformatf(
                "role=%s queue_id=%0d raw tail 0x%08h exceeds 16 bits",
                role == GQ_TX ? "TX" : "RX", queue_id, raw_tail))
            return;
        end
        write_mailbox_notify(role, queue_id, raw_tail[15:0]);
    endtask

    virtual task wait_irq(gq_role_e role, int unsigned queue_id);
        wait_mailbox_irq(role, queue_id);
    endtask

    virtual task ack_irq(gq_role_e role, int unsigned queue_id);
        ack_mailbox_irq(role, queue_id);
    endtask
endclass

`endif
