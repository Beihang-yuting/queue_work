// tb/tests/mailbox_reg_adapter_test.sv: UVM 测试 mailbox_reg_adapter_test：验证对应队列组件的定向行为和接口契约。
`ifndef MAILBOX_REG_ADAPTER_TEST_SV
`define MAILBOX_REG_ADAPTER_TEST_SV

class mailbox_test_reg_adapter extends mailbox_reg_adapter;
    `uvm_object_utils(mailbox_test_reg_adapter)

    int unsigned configure_calls;
    int unsigned disable_calls;
    int unsigned notify_calls;
    int unsigned wait_irq_calls;
    int unsigned ack_irq_calls;
    gq_role_e configured_role;
    int unsigned configured_queue_id;
    gq_addr_t configured_base;
    int unsigned configured_depth;
    int unsigned configured_desc_size;
    gq_role_e notified_role;
    int unsigned notified_queue_id;
    bit [15:0] notified_tail;
    gq_role_e disabled_role;
    int unsigned disabled_queue_id;
    gq_role_e waited_role;
    int unsigned waited_queue_id;
    gq_role_e acked_role;
    int unsigned acked_queue_id;

    function new(string name = "mailbox_test_reg_adapter");
        super.new(name);
        configure_calls = 0;
        disable_calls = 0;
        notify_calls = 0;
        wait_irq_calls = 0;
        ack_irq_calls = 0;
    endfunction

    virtual task configure_mailbox_registers(
        gq_role_e role,
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned desc_size);
        configure_calls++;
        configured_role = role;
        configured_queue_id = queue_id;
        configured_base = base;
        configured_depth = depth;
        configured_desc_size = desc_size;
    endtask

    virtual task disable_mailbox_registers(
        gq_role_e role, int unsigned queue_id);
        disable_calls++;
        disabled_role = role;
        disabled_queue_id = queue_id;
    endtask

    virtual task write_mailbox_notify(
        gq_role_e role, int unsigned queue_id, bit [15:0] raw_tail);
        notify_calls++;
        notified_role = role;
        notified_queue_id = queue_id;
        notified_tail = raw_tail;
    endtask

    virtual task wait_mailbox_irq(
        gq_role_e role, int unsigned queue_id);
        wait_irq_calls++;
        waited_role = role;
        waited_queue_id = queue_id;
    endtask

    virtual task ack_mailbox_irq(
        gq_role_e role, int unsigned queue_id);
        ack_irq_calls++;
        acked_role = role;
        acked_queue_id = queue_id;
    endtask
endclass

class mailbox_reg_ptr_catcher extends uvm_report_catcher;
    `uvm_object_utils(mailbox_reg_ptr_catcher)

    int unsigned caught_errors;

    function new(string name = "mailbox_reg_ptr_catcher");
        super.new(name);
        caught_errors = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR && get_id() == "MAILBOX_REG_PTR") begin
            caught_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class mailbox_reg_adapter_test extends uvm_test;
    `uvm_component_utils(mailbox_reg_adapter_test)

    function new(string name = "mailbox_reg_adapter_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void append_failure(ref string failures, input string message);
        failures = {failures, failures == "" ? "" : "; ", message};
    endfunction

    task run_phase(uvm_phase phase);
        mailbox_test_reg_adapter adapter;
        mailbox_reg_ptr_catcher ptr_catcher;
        int unsigned notify_before;
        string failures;

        phase.raise_objection(this);
        adapter = mailbox_test_reg_adapter::type_id::create("adapter");

        adapter.configure_queue(GQ_RX, 12, 64'h0000_0001_2345_6000,
                                256, 16);
        if (adapter.configure_calls != 1 ||
            adapter.configured_role != GQ_RX ||
            adapter.configured_queue_id != 12 ||
            adapter.configured_base != 64'h0000_0001_2345_6000 ||
            adapter.configured_depth != 256 ||
            adapter.configured_desc_size != 16)
            `uvm_fatal("MAILBOX_REG_CFG",
                       "generic queue configuration did not reach the register adapter intact")

        adapter.publish(GQ_TX, 27, 32'h0000_80a5);
        if (adapter.notify_calls != 1 ||
            adapter.notified_role != GQ_TX ||
            adapter.notified_queue_id != 27 ||
            adapter.notified_tail != 16'h80a5)
            `uvm_fatal("MAILBOX_REG_NOTIFY",
                       "mailbox publish did not deliver the 16-bit hardware tail")

        failures = "";
        adapter.disable_queue(GQ_RX, 28);
        if (adapter.disable_calls != 1 || adapter.disabled_role != GQ_RX ||
            adapter.disabled_queue_id != 28)
            append_failure(failures,
                           "generic disable did not reach the mailbox callback");

        adapter.wait_irq(GQ_TX, 29);
        if (adapter.wait_irq_calls != 1 || adapter.waited_role != GQ_TX ||
            adapter.waited_queue_id != 29)
            append_failure(failures,
                           "generic IRQ wait did not reach the mailbox callback");

        adapter.ack_irq(GQ_RX, 30);
        if (adapter.ack_irq_calls != 1 || adapter.acked_role != GQ_RX ||
            adapter.acked_queue_id != 30)
            append_failure(failures,
                           "generic IRQ ack did not reach the mailbox callback");

        notify_before = adapter.notify_calls;
        ptr_catcher = mailbox_reg_ptr_catcher::type_id::create("ptr_catcher");
        uvm_report_cb::add(null, ptr_catcher);
        adapter.publish(GQ_TX, 31, 32'h0001_80a5);
        uvm_report_cb::delete(null, ptr_catcher);
        if (ptr_catcher.caught_errors != 1)
            append_failure(failures,
                           "publish did not report a nonzero raw-tail high half");
        if (adapter.notify_calls != notify_before)
            append_failure(failures,
                           "invalid raw tail reached the mailbox notify callback");

        if (failures != "")
            `uvm_fatal("MAILBOX_REG_FORWARD", failures)

        phase.drop_objection(this);
    endtask
endclass

`endif
