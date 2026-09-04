// tb/tests/gq_agent_test.sv: UVM 测试 gq_agent_test：验证对应队列组件的定向行为和接口契约。
`ifndef GQ_AGENT_TEST_SV
`define GQ_AGENT_TEST_SV

class gq_agent_counting_mem extends host_mem_manager;
    `uvm_object_utils(gq_agent_counting_mem)

    function new(string name = "gq_agent_counting_mem");
        super.new(name);
    endfunction

    function int unsigned outstanding_blocks();
        return alloc_count;
    endfunction
endclass

class gq_agent_test_monitor extends gq_monitor;
    `uvm_component_utils(gq_agent_test_monitor)

    uvm_event loop_returned;

    function new(string name = "gq_agent_test_monitor",
                 uvm_component parent = null);
        super.new(name, parent);
        loop_returned = new("loop_returned");
    endfunction

    task run_phase(uvm_phase phase);
        super.run_phase(phase);
        loop_returned.trigger();
    endtask
endclass

class gq_agent_completion_collector extends uvm_component;
    `uvm_component_utils(gq_agent_completion_collector)

    uvm_analysis_imp #(gq_desc_base, gq_agent_completion_collector)
        analysis_export;
    host_mem_api mem;
    bit [15:0] expected_srcid;
    bit [15:0] expected_dstid;
    int unsigned completion_count;
    int unsigned owned_memory_observations;

    function new(string name = "gq_agent_completion_collector",
                 uvm_component parent = null);
        super.new(name, parent);
        analysis_export = new("analysis_export", this);
        mem = null;
        expected_srcid = 0;
        expected_dstid = 0;
        completion_count = 0;
        owned_memory_observations = 0;
    endfunction

    function void write(gq_desc_base desc);
        mailbox_tx_desc tx;
        byte observed[];

        if (!$cast(tx, desc))
            `uvm_fatal("AGENT_MONITOR_TYPE",
                       "monitor published a non-mailbox TX descriptor")
        if (tx.srcid != expected_srcid || tx.dstid != expected_dstid)
            `uvm_fatal("AGENT_MONITOR_ROUTE",
                       $sformatf("expected srcid/dstid %0h/%0h, got %0h/%0h",
                                 expected_srcid, expected_dstid,
                                 tx.srcid, tx.dstid))
        completion_count++;
        if (tx.buf_len != 0) begin
            mem.read_mem(tx.buf_addr, tx.buf_len, observed,
                         `__FILE__, `__LINE__);
            if (observed.size() == tx.buf_len)
                owned_memory_observations++;
        end
    endfunction
endclass

class gq_agent_test extends uvm_test;
    `uvm_component_utils(gq_agent_test)

    gq_agent_counting_mem mem;
    gq_test_ptr_codec codec;
    mailbox_mock_adapter adapter;
    mailbox_mock_dut dut;
    mailbox_env_cfg cfg;
    gq_queue_cfg irq_cfg;
    mailbox_env env;
    gq_agent_test_monitor poll_monitor;
    gq_agent_test_monitor irq_monitor;
    gq_agent_completion_collector poll_collector;
    gq_agent_completion_collector irq_collector;

    function new(string name = "gq_agent_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        string reason;

        super.build_phase(phase);
        gq_monitor::type_id::set_type_override(
            gq_agent_test_monitor::get_type());
        mem = new("mem");
        mem.init_region(64'h0000_0001_7200_0000,
                        64'h0000_0001_72ff_ffff, MODE_LINEAR, 16);
        codec = gq_test_ptr_codec::type_id::create("codec");
        adapter = mailbox_mock_adapter::type_id::create("adapter");
        dut = mailbox_mock_dut::type_id::create("dut");
        dut.mem = mem;
        dut.adapter = adapter;

        cfg = mailbox_env_cfg::type_id::create("cfg");
        cfg.mem = mem;
        cfg.adapter = adapter;
        cfg.ptr_codec = codec;
        if (!cfg.add_tx(12, 32, reason))
            `uvm_fatal("AGENT_CFG", reason)

        irq_cfg = gq_queue_cfg::type_id::create("irq_cfg");
        irq_cfg.queue_id           = 13;
        irq_cfg.role               = GQ_TX;
        irq_cfg.depth              = 32;
        irq_cfg.desc_size          = 64;
        irq_cfg.alignment          = 64;
        irq_cfg.status_area_size   = 0;
        irq_cfg.wait_mode          = GQ_IRQ;
        irq_cfg.poll_policy        = GQ_POLL_FIXED;
        irq_cfg.poll_min_interval  = 10ns;
        irq_cfg.poll_max_interval  = 10ns;
        irq_cfg.poll_backoff_factor = 2;
        irq_cfg.irq_watchdog_interval = 100ns;
        irq_cfg.completion_timeout = 1us;
        irq_cfg.ptr_codec          = codec;
        irq_cfg.completion_source  = mailbox_completion::type_id::create(
            "irq_completion");
        if (!cfg.add_queue(irq_cfg, reason))
            `uvm_fatal("AGENT_CFG", reason)

        uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", cfg);
        env = mailbox_env::type_id::create("env", this);

        poll_collector = gq_agent_completion_collector::type_id::create(
            "poll_collector", this);
        poll_collector.mem = mem;
        poll_collector.expected_srcid = 16'h1201;
        poll_collector.expected_dstid = 16'h1202;
        irq_collector = gq_agent_completion_collector::type_id::create(
            "irq_collector", this);
        irq_collector.mem = mem;
        irq_collector.expected_srcid = 16'h1301;
        irq_collector.expected_dstid = 16'h1302;
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (!$cast(poll_monitor, env.get_monitor("tx_12")))
            `uvm_fatal("AGENT_MONITOR_PATH",
                       "tx_12 monitor was not created with test override")
        if (!$cast(irq_monitor, env.get_monitor("tx_13")))
            `uvm_fatal("AGENT_MONITOR_PATH",
                       "tx_13 monitor was not created with test override")
        poll_monitor.completion_ap.connect(poll_collector.analysis_export);
        irq_monitor.completion_ap.connect(irq_collector.analysis_export);
    endfunction

    function gq_queue_engine find_engine(string key);
        uvm_component component_handle;
        gq_queue_engine engine;

        component_handle = uvm_root::get().find(
            {"uvm_test_top.env.", key, ".engine"});
        if (!$cast(engine, component_handle))
            `uvm_fatal("AGENT_ENGINE_PATH", {key, " engine was not created"})
        return engine;
    endfunction

    function gq_sequencer find_sequencer(string key);
        uvm_component component_handle;
        gq_sequencer sequencer;

        component_handle = uvm_root::get().find(
            {"uvm_test_top.env.", key, ".sequencer"});
        if (!$cast(sequencer, component_handle))
            `uvm_fatal("AGENT_SEQUENCER_PATH",
                       {key, " sequencer was not created"})
        return sequencer;
    endfunction

    function void check_component_tree(string key);
        uvm_component component_handle;
        uvm_component legacy_components[$];
        gq_driver driver;
        gq_monitor monitor;

        component_handle = uvm_root::get().find(
            {"uvm_test_top.env.", key, ".driver"});
        if (!$cast(driver, component_handle))
            `uvm_fatal("AGENT_DRIVER_PATH", {key, " driver was not created"})
        component_handle = uvm_root::get().find(
            {"uvm_test_top.env.", key, ".monitor"});
        if (!$cast(monitor, component_handle))
            `uvm_fatal("AGENT_MONITOR_PATH", {key, " monitor was not created"})
        uvm_root::get().find_all(
            {"uvm_test_top.env.", key, ".completion_worker"},
            legacy_components);
        if (legacy_components.size() != 0)
            `uvm_fatal("AGENT_WORKER_PATH",
                       "legacy completion worker is still present")
    endfunction

    task run_scenario();
        gq_queue_engine poll_engine;
        gq_queue_engine irq_engine;
        gq_sequencer poll_sequencer;
        gq_sequencer irq_sequencer;
        mailbox_tx_sequence poll_sequence;
        mailbox_tx_sequence irq_sequence;
        mailbox_tx_desc poll_desc;
        mailbox_tx_desc irq_desc;
        bit monitor_loops_returned;

        monitor_loops_returned = 0;
        cfg.wait_ready();
        if (env.agent_count() != 2)
            `uvm_fatal("AGENT_COUNT", "poll and IRQ agents were not created")
        check_component_tree("tx_12");
        check_component_tree("tx_13");
        poll_engine = find_engine("tx_12");
        irq_engine = find_engine("tx_13");
        poll_sequencer = find_sequencer("tx_12");
        irq_sequencer = find_sequencer("tx_13");

        poll_desc = mailbox_tx_desc::type_id::create("poll_desc");
        poll_desc.srcid = 16'h1201;
        poll_desc.dstid = 16'h1202;
        poll_desc.msg_type = 16'h1203;
        poll_desc.buf_len = 16;
        poll_desc.data_len = 1;
        poll_desc.data[0] = 8'ha5;

        poll_sequence = mailbox_tx_sequence::type_id::create("poll_sequence");
        poll_sequence.add_desc(poll_desc);
        poll_sequence.start(poll_sequencer);
        if (poll_sequence.response == null ||
            poll_sequence.response.status != GQ_OK ||
            poll_sequence.response.committed_count != 1)
            `uvm_fatal("AGENT_DRIVER", "poll driver did not submit TX")

        dut.complete_slot(poll_engine, 0, 32, 64);
        for (int unsigned poll = 0; poll < 2000; poll++) begin
            if (poll_collector.completion_count == 1)
                break;
            #1ns;
        end
        if (poll_collector.completion_count != 1 ||
            irq_collector.completion_count != 0)
            `uvm_fatal("AGENT_MONITOR_ROUTE",
                       "poll completion was not published by the poll monitor")

        irq_desc = mailbox_tx_desc::type_id::create("irq_desc");
        irq_desc.srcid = 16'h1301;
        irq_desc.dstid = 16'h1302;
        irq_desc.msg_type = 16'h1303;
        irq_desc.buf_len = 16;
        irq_desc.data_len = 1;
        irq_desc.data[0] = 8'h5a;

        irq_sequence = mailbox_tx_sequence::type_id::create("irq_sequence");
        irq_sequence.add_desc(irq_desc);
        irq_sequence.start(irq_sequencer);
        if (irq_sequence.response == null ||
            irq_sequence.response.status != GQ_OK ||
            irq_sequence.response.committed_count != 1)
            `uvm_fatal("AGENT_DRIVER", "IRQ driver did not submit TX")

        dut.complete_slot(irq_engine, 0, 32, 64);
        dut.trigger_irq(GQ_TX, 13);
        for (int unsigned poll = 0; poll < 2000; poll++) begin
            if (irq_collector.completion_count == 1)
                break;
            #1ns;
        end
        if (poll_collector.completion_count != 1 ||
            irq_collector.completion_count != 1 ||
            adapter.wait_irq_calls == 0 || adapter.ack_irq_calls != 1)
            `uvm_fatal("AGENT_MONITOR_TIMEOUT",
                       "IRQ monitor did not publish and acknowledge completion")
        if (poll_collector.owned_memory_observations != 1 ||
            irq_collector.owned_memory_observations != 1)
            `uvm_fatal("AGENT_MONITOR_LIFETIME",
                       "owned TX memory was invalid during analysis write")
        if (poll_engine.head_seq() != 1 || poll_engine.tail_seq() != 1 ||
            irq_engine.head_seq() != 1 || irq_engine.tail_seq() != 1)
            `uvm_fatal("AGENT_MONITOR_STATE",
                       "monitors did not retire both completed descriptors")
        if (poll_monitor.loop_returned.is_on() ||
            irq_monitor.loop_returned.is_on())
            `uvm_fatal("AGENT_MONITOR_EARLY_EXIT",
                       "monitor completion loop returned before cleanup")

        env.cleanup_and_check_leaks();
        fork : wait_for_monitor_loops
            begin
                poll_monitor.loop_returned.wait_on();
                irq_monitor.loop_returned.wait_on();
                monitor_loops_returned = 1;
            end
            begin
                #1us;
            end
        join_any
        disable wait_for_monitor_loops;
        if (!monitor_loops_returned)
            `uvm_fatal("AGENT_MONITOR_STOP",
                       "monitor completion loops did not return after cleanup")
        if (mem.outstanding_blocks() != 0)
            `uvm_fatal("AGENT_MONITOR_LEAK",
                       "agent cleanup left host memory allocated")
    endtask

    task run_phase(uvm_phase phase);
        bit scenario_done;

        phase.raise_objection(this);
        scenario_done = 0;
        fork : scenario_or_timeout
            begin
                run_scenario();
                scenario_done = 1;
            end
            begin
                #10us;
                if (!scenario_done)
                    `uvm_fatal("AGENT_TEST_TIMEOUT",
                               "agent/monitor scenario did not finish")
            end
        join_any
        disable scenario_or_timeout;
        phase.drop_objection(this);
    endtask
endclass

`endif
