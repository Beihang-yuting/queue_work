`ifndef CMDQ_REG_ADAPTER_SV
`define CMDQ_REG_ADAPTER_SV

virtual class cmdq_reg_adapter extends gq_hw_adapter;
    cmdq_hw_cfg_t hw_cfg;

    function new(string name = "cmdq_reg_adapter",
                 cmdq_hw_cfg_t hw_cfg = '0);
        super.new(name);
        this.hw_cfg = hw_cfg;
    endfunction

    pure virtual task reset_cmdq(int unsigned queue_id);

    pure virtual task configure_cmdq_registers(
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned desc_size,
        cmdq_hw_cfg_t hw_cfg);

    pure virtual task enable_cmdq(int unsigned queue_id);
    pure virtual task disable_cmdq(int unsigned queue_id);

    pure virtual task write_cmdq_tail(
        int unsigned queue_id, bit [15:0] tail);

    pure virtual task wait_cmdq_irq(int unsigned queue_id);
    pure virtual task ack_cmdq_irq(int unsigned queue_id);

    protected function bit require_tx(
        gq_role_e role, int unsigned queue_id, string operation);
        if (role == GQ_TX)
            return 1;
        `uvm_error("CMDQ_REG_ROLE", $sformatf(
            "%s requires role=TX for queue_id=%0d", operation, queue_id))
        return 0;
    endfunction

    virtual task configure_queue(
        gq_role_e role,
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned desc_size);
        if (!require_tx(role, queue_id, "configure_queue"))
            return;
        reset_cmdq(queue_id);
        configure_cmdq_registers(queue_id, base, depth, desc_size, hw_cfg);
        enable_cmdq(queue_id);
    endtask

    virtual task disable_queue(gq_role_e role, int unsigned queue_id);
        if (!require_tx(role, queue_id, "disable_queue"))
            return;
        disable_cmdq(queue_id);
    endtask

    virtual task publish(
        gq_role_e role,
        int unsigned queue_id,
        gq_raw_ptr_t raw_tail);
        if (!require_tx(role, queue_id, "publish"))
            return;
        if (raw_tail[31:16] != 0) begin
            `uvm_error("CMDQ_REG_PTR", $sformatf(
                "queue_id=%0d raw tail %08h exceeds 16 bits",
                queue_id, raw_tail))
            return;
        end
        write_cmdq_tail(queue_id, raw_tail[15:0]);
    endtask

    virtual task wait_irq(gq_role_e role, int unsigned queue_id);
        if (!require_tx(role, queue_id, "wait_irq"))
            return;
        wait_cmdq_irq(queue_id);
    endtask

    virtual task ack_irq(gq_role_e role, int unsigned queue_id);
        if (!require_tx(role, queue_id, "ack_irq"))
            return;
        ack_cmdq_irq(queue_id);
    endtask
endclass

`endif
