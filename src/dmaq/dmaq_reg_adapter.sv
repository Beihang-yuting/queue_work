`ifndef DMAQ_REG_ADAPTER_SV
`define DMAQ_REG_ADAPTER_SV

virtual class dmaq_reg_adapter extends gq_hw_adapter;
    protected bit binding_valid;
    protected int unsigned bound_queue_id;
    protected dmaq_hw_cfg_t bound_hw_cfg;

    function new(string name = "dmaq_reg_adapter");
        super.new(name);
        binding_valid = 0;
        bound_queue_id = 0;
        bound_hw_cfg = '0;
    endfunction

    function bit reserve_queue_binding(int unsigned queue_id,
                                       dmaq_hw_cfg_t hw_cfg,
                                       output string reason);
        if (binding_valid) begin
            reason = $sformatf(
                "DMAQ adapter is already bound to queue_id=%0d",
                bound_queue_id);
            return 0;
        end
        binding_valid = 1;
        bound_queue_id = queue_id;
        bound_hw_cfg = hw_cfg;
        reason = "";
        return 1;
    endfunction

    function bit release_queue_binding(int unsigned queue_id,
                                       dmaq_hw_cfg_t hw_cfg);
        if (!binding_valid || bound_queue_id != queue_id ||
            bound_hw_cfg != hw_cfg)
            return 0;
        binding_valid = 0;
        bound_queue_id = 0;
        bound_hw_cfg = '0;
        return 1;
    endfunction

    function bit get_queue_binding(output int unsigned queue_id,
                                   output dmaq_hw_cfg_t hw_cfg);
        queue_id = bound_queue_id;
        hw_cfg = bound_hw_cfg;
        return binding_valid;
    endfunction

    pure virtual task reset_dmaq(int unsigned queue_id);
    pure virtual task configure_dmaq_registers(
        int unsigned queue_id, gq_addr_t base, int unsigned depth,
        int unsigned desc_size, dmaq_hw_cfg_t hw_cfg);
    pure virtual task enable_dmaq(int unsigned queue_id);
    pure virtual task disable_dmaq(int unsigned queue_id);
    pure virtual task write_dmaq_tail(int unsigned queue_id, bit [15:0] tail);
    pure virtual task wait_dmaq_irq(int unsigned queue_id);
    pure virtual task ack_dmaq_irq(int unsigned queue_id);

    protected function bit require_tx(gq_role_e role, int unsigned queue_id,
                                      string operation);
        if (role == GQ_TX)
            return 1;
        `uvm_error("DMAQ_REG_ROLE", $sformatf(
            "%s requires role=TX for queue_id=%0d", operation, queue_id))
        return 0;
    endfunction

    virtual task configure_queue(gq_role_e role, int unsigned queue_id,
                                 gq_addr_t base, int unsigned depth,
                                 int unsigned desc_size);
        dmaq_hw_cfg_t hw_cfg;

        if (!require_tx(role, queue_id, "configure_queue"))
            return;
        if (desc_size != DMAQ_DESC_BYTES) begin
            `uvm_error("DMAQ_REG_SIZE", $sformatf(
                "queue_id=%0d descriptor size %0d must be %0d", queue_id,
                desc_size, DMAQ_DESC_BYTES))
            return;
        end
        if (!binding_valid || bound_queue_id != queue_id) begin
            `uvm_error("DMAQ_REG_BINDING", $sformatf(
                "queue_id=%0d has no matching DMAQ adapter binding",
                queue_id))
            return;
        end
        hw_cfg = bound_hw_cfg;
        reset_dmaq(queue_id);
        configure_dmaq_registers(queue_id, base, depth, desc_size, hw_cfg);
        enable_dmaq(queue_id);
    endtask

    virtual task disable_queue(gq_role_e role, int unsigned queue_id);
        if (!require_tx(role, queue_id, "disable_queue"))
            return;
        disable_dmaq(queue_id);
    endtask

    virtual task publish(gq_role_e role, int unsigned queue_id,
                         gq_raw_ptr_t raw_tail);
        if (!require_tx(role, queue_id, "publish"))
            return;
        if (raw_tail[31:16] != 0) begin
            `uvm_error("DMAQ_REG_PTR", $sformatf(
                "queue_id=%0d raw tail %08h exceeds 16 bits", queue_id,
                raw_tail))
            return;
        end
        write_dmaq_tail(queue_id, raw_tail[15:0]);
    endtask

    virtual task wait_irq(gq_role_e role, int unsigned queue_id);
        if (!require_tx(role, queue_id, "wait_irq"))
            return;
        wait_dmaq_irq(queue_id);
    endtask

    virtual task ack_irq(gq_role_e role, int unsigned queue_id);
        if (!require_tx(role, queue_id, "ack_irq"))
            return;
        ack_dmaq_irq(queue_id);
    endtask
endclass

`endif
