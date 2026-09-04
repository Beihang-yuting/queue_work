// tb/tests/mailbox_wrap_test.sv: UVM 测试 mailbox_wrap_test：验证对应队列组件的定向行为和接口契约。
`ifndef MAILBOX_WRAP_TEST_SV
`define MAILBOX_WRAP_TEST_SV

class mailbox_wrap_test extends uvm_test;
    `uvm_component_utils(mailbox_wrap_test)

    host_mem_manager     mem;
    mailbox_mock_adapter adapter;
    mailbox_mock_dut     dut;
    mailbox_env_cfg      env_cfg;
    mailbox_env          env;

    function new(string name = "mailbox_wrap_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function mailbox_tx_desc make_tx(string name, int unsigned index);
        mailbox_tx_desc desc;

        desc = mailbox_tx_desc::type_id::create(name);
        desc.srcid    = 16'h7100 + index;
        desc.dstid    = 16'h7200 + index;
        desc.msg_type = 16'h7300 + index;
        desc.data_len = 1;
        desc.data[0]  = byte'(index);
        return desc;
    endfunction

    function void check_available(gq_queue_engine engine,
                                  gq_logical_seq_t logical_seq);
        mailbox_tx_desc decoded;
        byte packed_data[];
        gq_addr_t slot_addr;

        slot_addr = engine.ring_base() + ((logical_seq % 32) * 64);
        mem.read_mem(slot_addr, 64, packed_data, `__FILE__, `__LINE__);
        decoded = mailbox_tx_desc::type_id::create(
            $sformatf("decoded_%0d", logical_seq));
        if (!decoded.unpack(packed_data))
            `uvm_fatal("MAILBOX_WRAP_DESC", $sformatf(
                "logical sequence %0d did not unpack", logical_seq))
        if (decoded.flags !== 16'h0001)
            `uvm_fatal("MAILBOX_WRAP_DESC", $sformatf(
                "logical sequence %0d published flags 0x%04h, expected AVAIL=1 USED=0",
                logical_seq, decoded.flags))
    endfunction

    function void build_phase(uvm_phase phase);
        string reason;

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_9000_0000,
                        64'h0000_0001_90ff_ffff, MODE_LINEAR, 16);
        adapter     = mailbox_mock_adapter::type_id::create("adapter");
        dut         = mailbox_mock_dut::type_id::create("dut");
        dut.mem     = mem;
        dut.adapter = adapter;

        env_cfg         = mailbox_env_cfg::type_id::create("env_cfg");
        env_cfg.mem     = mem;
        env_cfg.adapter = adapter;
        if (!env_cfg.add_tx(7, 32, reason))
            `uvm_fatal("MAILBOX_WRAP_CFG", reason)
        uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", env_cfg);
        env = mailbox_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        uvm_component component_handle;
        gq_sequencer sequencer;
        gq_queue_engine engine;
        mailbox_tx_sequence tx_sequence;
        mailbox_tx_desc desc;
        bit completion_seen;

        phase.raise_objection(this);
        env_cfg.wait_ready();
        component_handle = uvm_root::get().find(
            "uvm_test_top.env.tx_7.sequencer");
        if (!$cast(sequencer, component_handle))
            `uvm_fatal("MAILBOX_WRAP_PATH", "could not find TX sequencer")
        component_handle = uvm_root::get().find(
            "uvm_test_top.env.tx_7.engine");
        if (!$cast(engine, component_handle))
            `uvm_fatal("MAILBOX_WRAP_PATH", "could not find TX engine")

        for (int unsigned logical_seq = 0; logical_seq < 33; logical_seq++) begin
            desc = make_tx($sformatf("desc_%0d", logical_seq), logical_seq);
            tx_sequence = mailbox_tx_sequence::type_id::create(
                $sformatf("sequence_%0d", logical_seq));
            tx_sequence.add_desc(desc);
            tx_sequence.start(sequencer);
            if (tx_sequence.response == null ||
                tx_sequence.response.status != GQ_OK ||
                tx_sequence.response.committed_count != 1)
                `uvm_fatal("MAILBOX_WRAP_SUBMIT", $sformatf(
                    "logical sequence %0d submission failed", logical_seq))
            if (engine.head_seq() != logical_seq ||
                engine.tail_seq() != logical_seq + 1 ||
                engine.outstanding_count() != 1)
                `uvm_fatal("MAILBOX_WRAP_STATE", $sformatf(
                    "logical sequence %0d submit state is incorrect",
                    logical_seq))
            if (adapter.published_tails["tx_7"].size() != logical_seq + 1)
                `uvm_fatal("MAILBOX_WRAP_PUBLISH", $sformatf(
                    "logical sequence %0d publish count is incorrect",
                    logical_seq))
            if (logical_seq == 31 &&
                adapter.published_tails["tx_7"][31] !== 32'h0000_8000)
                `uvm_fatal("MAILBOX_WRAP_PUBLISH",
                           "tail sequence 32 was not encoded as 0x8000")
            if (logical_seq == 32 &&
                adapter.published_tails["tx_7"][32] !== 32'h0000_8001)
                `uvm_fatal("MAILBOX_WRAP_PUBLISH",
                           "tail sequence 33 was not encoded as 0x8001")

            check_available(engine, logical_seq);
            dut.complete_slot(engine, logical_seq, 32, 64);
            completion_seen = 0;
            for (int unsigned poll = 0;
                 poll < 200 && !completion_seen; poll++) begin
                #1ns;
                completion_seen = engine.head_seq() == logical_seq + 1;
            end
            if (!completion_seen)
                `uvm_fatal("MAILBOX_WRAP_COMPLETE", $sformatf(
                    "logical sequence %0d did not complete with fixed USED=1",
                    logical_seq))
        end

        if (engine.head_seq() != 33 || engine.tail_seq() != 33 ||
            engine.outstanding_count() != 0)
            `uvm_fatal("MAILBOX_WRAP_FINAL", "final engine state is incorrect")
        phase.drop_objection(this);
    endtask
endclass

`endif
