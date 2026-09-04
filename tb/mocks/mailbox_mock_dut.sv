// tb/mocks/mailbox_mock_dut.sv: 向仿真主机内存写入完成数据的 Mailbox 模拟 DUT 辅助对象。
`ifndef MAILBOX_MOCK_DUT_SV
`define MAILBOX_MOCK_DUT_SV

class mailbox_mock_dut extends uvm_object;
    `uvm_object_utils(mailbox_mock_dut)

    host_mem_api mem;
    mailbox_mock_adapter adapter;

    function new(string name = "mailbox_mock_dut");
        super.new(name);
    endfunction

    function void complete_slot(gq_queue_engine engine,
                                gq_logical_seq_t logical_seq,
                                int unsigned depth,
                                int unsigned desc_size);
        byte packed_data[];
        gq_addr_t slot_addr;

        slot_addr = engine.ring_base() +
                    ((logical_seq % depth) * desc_size);
        mem.read_mem(slot_addr, desc_size, packed_data, `__FILE__, `__LINE__);
        packed_data[0][1] = 1'b1;
        mem.write_mem(slot_addr, packed_data, `__FILE__, `__LINE__);
    endfunction

    function void trigger_irq(gq_role_e role, int unsigned queue_id);
        adapter.trigger_irq(role, queue_id);
    endfunction
endclass

`endif
