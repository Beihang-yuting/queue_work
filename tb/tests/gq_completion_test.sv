`ifndef GQ_COMPLETION_TEST_SV
`define GQ_COMPLETION_TEST_SV

class gq_overcount_completion extends gq_completion_source;
    `uvm_object_utils(gq_overcount_completion)

    function new(string name = "gq_overcount_completion");
        super.new(name);
    endfunction

    virtual function int unsigned completed_count(
        host_mem_api mem,
        gq_addr_t ring_base,
        gq_addr_t status_addr,
        int unsigned depth,
        int unsigned desc_size,
        gq_logical_seq_t logical_head,
        input gq_desc_base pending[$]);
        return pending.size() + 1;
    endfunction
endclass

class gq_counting_completion extends gq_completion_source;
    `uvm_object_utils(gq_counting_completion)

    int unsigned query_calls;

    function new(string name = "gq_counting_completion");
        super.new(name);
        query_calls = 0;
    endfunction

    virtual function int unsigned completed_count(
        host_mem_api mem,
        gq_addr_t ring_base,
        gq_addr_t status_addr,
        int unsigned depth,
        int unsigned desc_size,
        gq_logical_seq_t logical_head,
        input gq_desc_base pending[$]);
        query_calls++;
        return 0;
    endfunction
endclass

class gq_completion_read_guard_mem extends host_mem_manager;
    int unsigned read_calls;

    function new(string name = "gq_completion_read_guard_mem");
        super.new(name);
        read_calls = 0;
    endfunction

    virtual function void read_mem(
        bit [63:0] addr,
        int unsigned size,
        ref byte data[],
        input string file = "",
        input int line = 0);
        read_calls++;
        data = new[size];
        foreach (data[i])
            data[i] = 0;
    endfunction
endclass

class gq_completion_protocol_catcher extends uvm_report_catcher;
    `uvm_object_utils(gq_completion_protocol_catcher)

    bit caught_protocol_error;

    function new(string name = "gq_completion_protocol_catcher");
        super.new(name);
        caught_protocol_error = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR &&
            get_id() == "GQ_COMPLETION_PROTOCOL") begin
            caught_protocol_error = 1;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class gq_completion_addr_catcher extends uvm_report_catcher;
    `uvm_object_utils(gq_completion_addr_catcher)

    int unsigned caught_addr_errors;

    function new(string name = "gq_completion_addr_catcher");
        super.new(name);
        caught_addr_errors = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR &&
            get_id() == "GQ_COMPLETION_ADDR") begin
            caught_addr_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class gq_completion_test_engine extends gq_queue_engine;
    `uvm_component_utils(gq_completion_test_engine)

    int unsigned outstanding_audit_steps;

    function new(string name = "gq_completion_test_engine",
                 uvm_component parent = null);
        super.new(name, parent);
        outstanding_audit_steps = 0;
    endfunction

    protected virtual function void audit_outstanding_entry(
        string transition_name, gq_logical_seq_t seq, gq_desc_base desc);
        outstanding_audit_steps++;
        super.audit_outstanding_entry(transition_name, seq, desc);
    endfunction
endclass

class gq_completion_collector extends uvm_component;
    `uvm_component_utils(gq_completion_collector)

    uvm_analysis_imp #(gq_desc_base, gq_completion_collector) analysis_export;
    bit [15:0] retired_srcids[$];
    byte rx_first_bytes[$];
    host_mem_api observer_mem;
    bit observed_owned_memory;

    function new(string name = "gq_completion_collector",
                 uvm_component parent = null);
        super.new(name, parent);
        analysis_export = new("analysis_export", this);
        observer_mem = null;
        observed_owned_memory = 0;
    endfunction

    function void write(gq_desc_base desc);
        mailbox_tx_desc tx;
        mailbox_rx_desc rx;
        byte observed_data[];

        if ($cast(tx, desc)) begin
            retired_srcids.push_back(tx.srcid);
            if (observer_mem != null && tx.buf_len != 0) begin
                observer_mem.read_mem(tx.buf_addr, tx.buf_len, observed_data,
                                      `__FILE__, `__LINE__);
                if (observed_data.size() == tx.buf_len)
                    observed_owned_memory = 1;
            end
            return;
        end
        if ($cast(rx, desc)) begin
            if (rx.rx_data.size() == 0)
                `uvm_fatal("COMPLETE_RX", "RX completion data was not parsed")
            rx_first_bytes.push_back(rx.rx_data[0]);
            if (observer_mem != null && rx.buf_len != 0) begin
                observer_mem.read_mem(rx.buf_addr, rx.buf_len, observed_data,
                                      `__FILE__, `__LINE__);
                if (observed_data.size() == rx.buf_len)
                    observed_owned_memory = 1;
            end
            return;
        end
        `uvm_fatal("COMPLETE_TYPE", "completion had an unknown descriptor type")
    endfunction
endclass

class gq_completion_test extends uvm_test;
    `uvm_component_utils(gq_completion_test)

    host_mem_manager       mem;
    gq_test_ptr_codec      ptr_codec;
    mailbox_mock_adapter   adapter;
    mailbox_mock_dut       dut;
    gq_queue_cfg           cfg;
    gq_completion_test_engine engine;
    gq_completion_collector collector;
    gq_queue_cfg           tail_cfg;
    gq_tail_mem_completion tail_source;
    gq_queue_engine        tail_engine;
    host_mem_manager       protocol_mem;
    mailbox_mock_adapter   protocol_adapter;
    gq_queue_cfg           protocol_cfg;
    gq_queue_engine        protocol_engine;
    host_mem_manager       poll_mem;
    mailbox_mock_adapter   poll_adapter;
    gq_queue_cfg           poll_cfg;
    gq_queue_engine        poll_engine;
    gq_completion_collector poll_collector;
    host_mem_manager       irq_mem;
    mailbox_mock_adapter   irq_adapter;
    gq_queue_cfg           irq_cfg;
    gq_queue_engine        irq_engine;
    gq_completion_collector irq_collector;
    host_mem_manager       worker_mem;
    mailbox_mock_adapter   worker_adapter;
    mailbox_env_cfg        worker_env_cfg;
    mailbox_env            worker_env;
    gq_completion_collector worker_collector;
    host_mem_manager       rx_mem;
    mailbox_mock_adapter   rx_adapter;
    gq_queue_cfg           rx_cfg;
    gq_queue_engine        rx_engine;
    gq_completion_collector rx_collector;
    host_mem_manager       cleanup_mem;
    mailbox_mock_adapter   cleanup_adapter;
    gq_queue_cfg           cleanup_cfg;
    gq_queue_engine        cleanup_engine;
    gq_counting_completion cleanup_source;
    bit                    irq_wait_returned;
    bit                    irq_wait_timed_out;
    time                   irq_wait_timeout;

    function new(string name = "gq_completion_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function mailbox_tx_desc make_tx(string name, int unsigned index);
        mailbox_tx_desc desc;

        desc = mailbox_tx_desc::type_id::create(name);
        desc.srcid    = 16'h5100 + index;
        desc.dstid    = 16'h5200 + index;
        desc.msg_type = 16'h5300 + index;
        desc.buf_len  = 0;
        desc.data_len = 1;
        desc.data[0]  = byte'(index);
        return desc;
    endfunction

    function void build_phase(uvm_phase phase);
        string reason;

        super.build_phase(phase);

        mem = new("mem");
        mem.init_region(64'h0000_0001_4000_0000,
                        64'h0000_0001_40ff_ffff, MODE_LINEAR, 16);
        ptr_codec = gq_test_ptr_codec::type_id::create("ptr_codec");
        adapter   = mailbox_mock_adapter::type_id::create("adapter");
        dut       = mailbox_mock_dut::type_id::create("dut");
        dut.mem     = mem;
        dut.adapter = adapter;

        cfg = gq_queue_cfg::type_id::create("cfg");
        cfg.queue_id           = 11;
        cfg.role               = GQ_TX;
        cfg.depth              = 32;
        cfg.desc_size          = 64;
        cfg.alignment          = 64;
        cfg.status_area_size   = 0;
        cfg.wait_mode          = GQ_POLL;
        cfg.poll_interval      = 10ns;
        cfg.completion_timeout = 1us;
        cfg.ptr_codec          = ptr_codec;
        cfg.completion_source  = mailbox_completion::type_id::create(
            "completion_source");

        uvm_config_db#(gq_queue_cfg)::set(this, "engine", "cfg", cfg);
        uvm_config_db#(host_mem_api)::set(this, "engine", "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "engine", "adapter", adapter);
        engine    = gq_completion_test_engine::type_id::create("engine", this);
        collector = gq_completion_collector::type_id::create("collector", this);
        collector.observer_mem = mem;

        tail_cfg = gq_queue_cfg::type_id::create("tail_cfg");
        tail_cfg.queue_id           = 23;
        tail_cfg.role               = GQ_TX;
        tail_cfg.depth              = 32;
        tail_cfg.desc_size          = 64;
        tail_cfg.alignment          = 64;
        tail_cfg.status_area_size   = 8;
        tail_cfg.wait_mode          = GQ_POLL;
        tail_cfg.poll_interval      = 10ns;
        tail_cfg.completion_timeout = 1us;
        tail_cfg.ptr_codec          = ptr_codec;
        tail_source = new("tail_source", ptr_codec, 4, GQ_LITTLE_ENDIAN);
        tail_cfg.completion_source  = tail_source;
        uvm_config_db#(gq_queue_cfg)::set(this, "tail_engine", "cfg",
                                          tail_cfg);
        uvm_config_db#(host_mem_api)::set(this, "tail_engine", "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "tail_engine", "adapter",
                                           adapter);
        tail_engine = gq_queue_engine::type_id::create("tail_engine", this);

        protocol_mem = new("protocol_mem");
        protocol_mem.init_region(64'h0000_0001_4100_0000,
                                 64'h0000_0001_41ff_ffff,
                                 MODE_LINEAR, 16);
        protocol_adapter = mailbox_mock_adapter::type_id::create(
            "protocol_adapter");
        protocol_cfg = gq_queue_cfg::type_id::create("protocol_cfg");
        protocol_cfg.queue_id           = 15;
        protocol_cfg.role               = GQ_TX;
        protocol_cfg.depth              = 32;
        protocol_cfg.desc_size          = 64;
        protocol_cfg.alignment          = 64;
        protocol_cfg.status_area_size   = 0;
        protocol_cfg.wait_mode          = GQ_POLL;
        protocol_cfg.poll_interval      = 10ns;
        protocol_cfg.completion_timeout = 1us;
        protocol_cfg.ptr_codec          = ptr_codec;
        protocol_cfg.completion_source  =
            gq_overcount_completion::type_id::create("overcount_source");
        uvm_config_db#(gq_queue_cfg)::set(this, "protocol_engine", "cfg",
                                          protocol_cfg);
        uvm_config_db#(host_mem_api)::set(this, "protocol_engine", "mem",
                                          protocol_mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "protocol_engine", "adapter",
                                           protocol_adapter);
        protocol_engine = gq_queue_engine::type_id::create(
            "protocol_engine", this);

        poll_mem = new("poll_mem");
        poll_mem.init_region(64'h0000_0001_4200_0000,
                             64'h0000_0001_42ff_ffff, MODE_LINEAR, 16);
        poll_adapter = mailbox_mock_adapter::type_id::create("poll_adapter");
        poll_cfg = gq_queue_cfg::type_id::create("poll_cfg");
        poll_cfg.queue_id           = 16;
        poll_cfg.role               = GQ_TX;
        poll_cfg.depth              = 32;
        poll_cfg.desc_size          = 64;
        poll_cfg.alignment          = 64;
        poll_cfg.status_area_size   = 0;
        poll_cfg.wait_mode          = GQ_POLL;
        poll_cfg.poll_interval      = 10ns;
        poll_cfg.completion_timeout = 1us;
        poll_cfg.ptr_codec          = ptr_codec;
        poll_cfg.completion_source  = mailbox_completion::type_id::create(
            "poll_completion");
        uvm_config_db#(gq_queue_cfg)::set(this, "poll_engine", "cfg", poll_cfg);
        uvm_config_db#(host_mem_api)::set(this, "poll_engine", "mem", poll_mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "poll_engine", "adapter",
                                           poll_adapter);
        poll_engine = gq_queue_engine::type_id::create("poll_engine", this);
        poll_collector = gq_completion_collector::type_id::create(
            "poll_collector", this);

        irq_mem = new("irq_mem");
        irq_mem.init_region(64'h0000_0001_4300_0000,
                            64'h0000_0001_43ff_ffff, MODE_LINEAR, 16);
        irq_adapter = mailbox_mock_adapter::type_id::create("irq_adapter");
        irq_cfg = gq_queue_cfg::type_id::create("irq_cfg");
        irq_cfg.queue_id           = 17;
        irq_cfg.role               = GQ_TX;
        irq_cfg.depth              = 32;
        irq_cfg.desc_size          = 64;
        irq_cfg.alignment          = 64;
        irq_cfg.status_area_size   = 0;
        irq_cfg.wait_mode          = GQ_IRQ;
        irq_cfg.poll_interval      = 10ns;
        irq_cfg.completion_timeout = 1us;
        irq_cfg.ptr_codec          = ptr_codec;
        irq_cfg.completion_source  = mailbox_completion::type_id::create(
            "irq_completion");
        uvm_config_db#(gq_queue_cfg)::set(this, "irq_engine", "cfg", irq_cfg);
        uvm_config_db#(host_mem_api)::set(this, "irq_engine", "mem", irq_mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "irq_engine", "adapter",
                                           irq_adapter);
        irq_engine = gq_queue_engine::type_id::create("irq_engine", this);
        irq_collector = gq_completion_collector::type_id::create(
            "irq_collector", this);

        worker_mem = new("worker_mem");
        worker_mem.init_region(64'h0000_0001_4400_0000,
                               64'h0000_0001_44ff_ffff,
                               MODE_LINEAR, 16);
        worker_adapter = mailbox_mock_adapter::type_id::create(
            "worker_adapter");
        worker_env_cfg = mailbox_env_cfg::type_id::create("worker_env_cfg");
        worker_env_cfg.mem       = worker_mem;
        worker_env_cfg.adapter   = worker_adapter;
        worker_env_cfg.ptr_codec = ptr_codec;
        if (!worker_env_cfg.add_tx(20, 32, reason))
            `uvm_fatal("WORKER_CFG", reason)
        uvm_config_db#(gq_env_cfg)::set(this, "worker_env", "cfg",
                                        worker_env_cfg);
        worker_env = mailbox_env::type_id::create("worker_env", this);
        worker_collector = gq_completion_collector::type_id::create(
            "worker_collector", this);

        rx_mem = new("rx_mem");
        rx_mem.init_region(64'h0000_0001_4500_0000,
                           64'h0000_0001_45ff_ffff, MODE_LINEAR, 16);
        rx_adapter = mailbox_mock_adapter::type_id::create("rx_adapter");
        rx_cfg = gq_queue_cfg::type_id::create("rx_cfg");
        rx_cfg.queue_id           = 21;
        rx_cfg.role               = GQ_RX;
        rx_cfg.depth              = 32;
        rx_cfg.desc_size          = 16;
        rx_cfg.alignment          = 64;
        rx_cfg.status_area_size   = 0;
        rx_cfg.wait_mode          = GQ_POLL;
        rx_cfg.poll_interval      = 10ns;
        rx_cfg.completion_timeout = 1us;
        rx_cfg.ptr_codec          = ptr_codec;
        rx_cfg.completion_source  = mailbox_completion::type_id::create(
            "rx_completion");
        uvm_config_db#(gq_queue_cfg)::set(this, "rx_engine", "cfg", rx_cfg);
        uvm_config_db#(host_mem_api)::set(this, "rx_engine", "mem", rx_mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "rx_engine", "adapter",
                                           rx_adapter);
        rx_engine = gq_queue_engine::type_id::create("rx_engine", this);
        rx_collector = gq_completion_collector::type_id::create(
            "rx_collector", this);
        rx_collector.observer_mem = rx_mem;

        cleanup_mem = new("cleanup_mem");
        cleanup_mem.init_region(64'h0000_0001_4600_0000,
                                64'h0000_0001_46ff_ffff,
                                MODE_LINEAR, 16);
        cleanup_adapter = mailbox_mock_adapter::type_id::create(
            "cleanup_adapter");
        cleanup_source = gq_counting_completion::type_id::create(
            "cleanup_source");
        cleanup_cfg = gq_queue_cfg::type_id::create("cleanup_cfg");
        cleanup_cfg.queue_id           = 22;
        cleanup_cfg.role               = GQ_TX;
        cleanup_cfg.depth              = 32;
        cleanup_cfg.desc_size          = 64;
        cleanup_cfg.alignment          = 64;
        cleanup_cfg.status_area_size   = 4;
        cleanup_cfg.wait_mode          = GQ_POLL;
        cleanup_cfg.poll_interval      = 10ns;
        cleanup_cfg.completion_timeout = 1us;
        cleanup_cfg.ptr_codec          = ptr_codec;
        cleanup_cfg.completion_source  = cleanup_source;
        uvm_config_db#(gq_queue_cfg)::set(this, "cleanup_engine", "cfg",
                                          cleanup_cfg);
        uvm_config_db#(host_mem_api)::set(this, "cleanup_engine", "mem",
                                          cleanup_mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "cleanup_engine", "adapter",
                                           cleanup_adapter);
        cleanup_engine = gq_queue_engine::type_id::create(
            "cleanup_engine", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        engine.completion_ap.connect(collector.analysis_export);
        poll_engine.completion_ap.connect(poll_collector.analysis_export);
        irq_engine.completion_ap.connect(irq_collector.analysis_export);
        rx_engine.completion_ap.connect(rx_collector.analysis_export);
        begin
            uvm_component worker_engine_component;
            gq_queue_engine worker_engine;

            worker_engine_component = uvm_root::get().find(
                "uvm_test_top.worker_env.tx_20.engine");
            if (!$cast(worker_engine, worker_engine_component))
                `uvm_fatal("WORKER_PATH", "could not find worker engine")
            worker_engine.completion_ap.connect(
                worker_collector.analysis_export);
        end
    endfunction

    function void check_tail_memory_endian();
        gq_tail_mem_completion little_source;
        gq_tail_mem_completion big_source;
        gq_tail_mem_completion zero_offset_source;
        gq_completion_read_guard_mem guard_mem;
        gq_completion_addr_catcher addr_catcher;
        gq_desc_base pending[$];
        mailbox_tx_desc pending_desc;
        gq_raw_ptr_t raw;
        gq_addr_t status_base;
        byte raw_bytes[];
        int unsigned count;

        status_base = mem.alloc(16, 4, `__FILE__, `__LINE__);
        if (status_base == '1)
            `uvm_fatal("TAIL_MEM", "could not allocate status test area")
        for (int unsigned i = 0; i < 4; i++) begin
            pending_desc = mailbox_tx_desc::type_id::create(
                $sformatf("tail_pending_%0d", i));
            pending.push_back(pending_desc);
        end
        raw = ptr_codec.encode_publish(7, 10, 32);

        little_source = new("little_source", ptr_codec, 4,
                            GQ_LITTLE_ENDIAN);
        raw_bytes = new[4];
        for (int unsigned i = 0; i < 4; i++)
            raw_bytes[i] = byte'(raw >> (8 * i));
        mem.write_mem(status_base + 4, raw_bytes, `__FILE__, `__LINE__);
        count = little_source.completed_count(mem, 0, status_base, 32, 64,
                                              7, pending);
        if (count != 3)
            `uvm_fatal("TAIL_ENDIAN", $sformatf(
                "little-endian count got %0d expected 3", count))

        big_source = new("big_source", ptr_codec, 8, GQ_BIG_ENDIAN);
        for (int unsigned i = 0; i < 4; i++)
            raw_bytes[i] = byte'(raw >> (8 * (3 - i)));
        mem.write_mem(status_base + 8, raw_bytes, `__FILE__, `__LINE__);
        count = big_source.completed_count(mem, 0, status_base, 32, 64,
                                           7, pending);
        if (count != 3)
            `uvm_fatal("TAIL_ENDIAN", $sformatf(
                "big-endian count got %0d expected 3", count))

        raw = raw ^ 32'h0001_0000;
        for (int unsigned i = 0; i < 4; i++)
            raw_bytes[i] = byte'(raw >> (8 * i));
        mem.write_mem(status_base + 4, raw_bytes, `__FILE__, `__LINE__);
        count = little_source.completed_count(mem, 0, status_base, 32, 64,
                                              7, pending);
        if (count != 0)
            `uvm_fatal("TAIL_DECODE", "decode failure did not return zero")

        raw = ptr_codec.encode_publish(65534, 65538, 32);
        for (int unsigned i = 0; i < 4; i++)
            raw_bytes[i] = byte'(raw >> (8 * i));
        mem.write_mem(status_base + 4, raw_bytes, `__FILE__, `__LINE__);
        count = little_source.completed_count(mem, 0, status_base, 32, 64,
                                              65534, pending);
        if (count != 4)
            `uvm_fatal("TAIL_WRAP", $sformatf(
                "little-endian 16-bit wrap count got %0d expected 4", count))
        for (int unsigned i = 0; i < 4; i++)
            raw_bytes[i] = byte'(raw >> (8 * (3 - i)));
        mem.write_mem(status_base + 8, raw_bytes, `__FILE__, `__LINE__);
        count = big_source.completed_count(mem, 0, status_base, 32, 64,
                                           65534, pending);
        if (count != 4)
            `uvm_fatal("TAIL_WRAP", $sformatf(
                "big-endian 16-bit wrap count got %0d expected 4", count))

        guard_mem = new("guard_mem");
        zero_offset_source = new("zero_offset_source", ptr_codec, 0,
                                 GQ_LITTLE_ENDIAN);
        addr_catcher = new("addr_catcher");
        uvm_report_cb::add(null, addr_catcher);
        count = little_source.completed_count(
            guard_mem, 0, 64'hffff_ffff_ffff_fffe, 32, 64, 0, pending);
        if (count != 0)
            `uvm_fatal("TAIL_ADDR", "status base plus offset overflow was accepted")
        count = zero_offset_source.completed_count(
            guard_mem, 0, 64'hffff_ffff_ffff_fffe, 32, 64, 0, pending);
        if (count != 0)
            `uvm_fatal("TAIL_ADDR", "four-byte status read overflow was accepted")
        uvm_report_cb::delete(null, addr_catcher);
        if (addr_catcher.caught_addr_errors != 2 || guard_mem.read_calls != 0)
            `uvm_fatal("TAIL_ADDR", $sformatf(
                "overflow guard caught=%0d reads=%0d expected 2/0",
                addr_catcher.caught_addr_errors, guard_mem.read_calls))

        mem.free(status_base, `__FILE__, `__LINE__);
    endfunction

    function void check_completion_validation();
        gq_queue_cfg missing_source_cfg;
        gq_queue_cfg generic_mailbox_queue;
        gq_queue_cfg tail_validation_cfg;
        mailbox_env_cfg auto_cfg;
        mailbox_completion installed_source;
        gq_tail_mem_completion validation_source;
        string reason;

        missing_source_cfg = gq_queue_cfg::type_id::create(
            "missing_source_cfg");
        missing_source_cfg.queue_id           = 12;
        missing_source_cfg.role               = GQ_TX;
        missing_source_cfg.depth              = 32;
        missing_source_cfg.desc_size          = 64;
        missing_source_cfg.alignment          = 64;
        missing_source_cfg.wait_mode          = GQ_POLL;
        missing_source_cfg.poll_interval      = 10ns;
        missing_source_cfg.completion_timeout = 1us;
        missing_source_cfg.ptr_codec          = ptr_codec;
        missing_source_cfg.completion_source  = null;
        if (missing_source_cfg.validate(reason) ||
            !uvm_is_match("*completion source*", reason))
            `uvm_fatal("COMPLETE_VALIDATE",
                       "queue validation accepted a null completion source")

        tail_validation_cfg = gq_queue_cfg::type_id::create(
            "tail_validation_cfg");
        tail_validation_cfg.queue_id           = 19;
        tail_validation_cfg.role               = GQ_TX;
        tail_validation_cfg.depth              = 32;
        tail_validation_cfg.desc_size          = 64;
        tail_validation_cfg.alignment          = 64;
        tail_validation_cfg.status_area_size   = 7;
        tail_validation_cfg.wait_mode          = GQ_POLL;
        tail_validation_cfg.poll_interval      = 10ns;
        tail_validation_cfg.completion_timeout = 1us;
        tail_validation_cfg.ptr_codec          = ptr_codec;
        validation_source = new("short_tail_source", ptr_codec, 4,
                                GQ_LITTLE_ENDIAN);
        tail_validation_cfg.completion_source = validation_source;
        if (tail_validation_cfg.validate(reason) ||
            !uvm_is_match("*status area*", reason))
            `uvm_fatal("TAIL_VALIDATE",
                       "tail source accepted a status area shorter than offset+4")
        tail_validation_cfg.status_area_size = 8;
        if (!tail_validation_cfg.validate(reason))
            `uvm_fatal("TAIL_VALIDATE", {"legal tail status boundary failed: ",
                                         reason})
        validation_source = new("null_codec_tail_source", null, 0,
                                GQ_LITTLE_ENDIAN);
        tail_validation_cfg.completion_source = validation_source;
        if (tail_validation_cfg.validate(reason) ||
            !uvm_is_match("*codec*", reason))
            `uvm_fatal("TAIL_VALIDATE", "tail source accepted a null codec")
        validation_source = new("overflow_tail_source", ptr_codec,
                                32'hffff_fffe, GQ_LITTLE_ENDIAN);
        tail_validation_cfg.status_area_size = 32'hffff_ffff;
        tail_validation_cfg.completion_source = validation_source;
        if (tail_validation_cfg.validate(reason) ||
            !uvm_is_match("*status area*", reason))
            `uvm_fatal("TAIL_VALIDATE", "tail source offset+4 overflow was accepted")

        auto_cfg = mailbox_env_cfg::type_id::create("auto_cfg");
        auto_cfg.mem       = mem;
        auto_cfg.adapter   = adapter;
        auto_cfg.ptr_codec = ptr_codec;
        if (!auto_cfg.add_tx(13, 32, reason) ||
            !auto_cfg.add_rx(14, 32, reason))
            `uvm_fatal("COMPLETE_INSTALL", reason)
        generic_mailbox_queue = gq_queue_cfg::type_id::create(
            "generic_mailbox_queue");
        generic_mailbox_queue.queue_id           = 18;
        generic_mailbox_queue.role               = GQ_TX;
        generic_mailbox_queue.depth              = 32;
        generic_mailbox_queue.desc_size          = 64;
        generic_mailbox_queue.alignment          = 64;
        generic_mailbox_queue.wait_mode          = GQ_POLL;
        generic_mailbox_queue.poll_interval      = 10ns;
        generic_mailbox_queue.completion_timeout = 1us;
        generic_mailbox_queue.ptr_codec          = ptr_codec;
        generic_mailbox_queue.completion_source  = null;
        if (!auto_cfg.add_queue(generic_mailbox_queue, reason) ||
            !auto_cfg.validate(reason))
            `uvm_fatal("COMPLETE_INSTALL", reason)
        if (!$cast(installed_source,
                   auto_cfg.queues["tx_13"].completion_source) ||
            installed_source == null)
            `uvm_fatal("COMPLETE_INSTALL",
                       "mailbox TX completion source was not installed")
        if (!$cast(installed_source,
                   auto_cfg.queues["rx_14"].completion_source) ||
            installed_source == null)
            `uvm_fatal("COMPLETE_INSTALL",
                       "mailbox RX completion source was not installed")
        if (!$cast(installed_source,
                   auto_cfg.queues["tx_18"].completion_source) ||
            installed_source == null)
            `uvm_fatal("COMPLETE_INSTALL",
                       "generic-added mailbox completion source was not installed")
    endfunction

    task check_tail_engine_integration();
        mailbox_tx_desc desc;
        gq_request request;
        gq_response response;
        gq_raw_ptr_t raw;
        byte raw_bytes[];

        tail_engine.initialize();
        desc = make_tx("tail_engine_desc", 10);
        request = gq_request::type_id::create("tail_engine_request");
        request.add_desc(desc);
        response = gq_response::type_id::create("tail_engine_response");
        tail_engine.submit_batch(request, response);
        if (response.status != GQ_OK)
            `uvm_fatal("TAIL_ENGINE", "legal tail-source submit failed")
        raw = ptr_codec.encode_publish(0, 1, tail_cfg.depth);
        raw_bytes = new[4];
        for (int unsigned i = 0; i < 4; i++)
            raw_bytes[i] = byte'(raw >> (8 * i));
        mem.write_mem(tail_engine.status_addr() + 4, raw_bytes,
                      `__FILE__, `__LINE__);
        tail_engine.drain_completed();
        if (tail_engine.head_seq() != 1 ||
            tail_engine.outstanding_count() != 0)
            `uvm_fatal("TAIL_ENGINE",
                       "legal tail status area did not retire through engine")
        tail_engine.cleanup();
    endtask

    task check_overcount_protocol();
        mailbox_tx_desc desc;
        gq_request request;
        gq_response response;
        gq_completion_protocol_catcher catcher;

        protocol_engine.initialize();
        desc = make_tx("protocol_desc", 8);
        request = gq_request::type_id::create("protocol_request");
        request.add_desc(desc);
        response = gq_response::type_id::create("protocol_response");
        protocol_engine.submit_batch(request, response);
        if (response.status != GQ_OK)
            `uvm_fatal("COMPLETE_PROTOCOL", "protocol setup submit failed")

        catcher = new("protocol_catcher");
        uvm_report_cb::add(null, catcher);
        protocol_engine.drain_completed();
        uvm_report_cb::delete(null, catcher);
        if (!catcher.caught_protocol_error)
            `uvm_fatal("COMPLETE_PROTOCOL",
                       "over-count did not report a completion protocol error")
        if (protocol_engine.head_seq() != 0 ||
            protocol_engine.tail_seq() != 1 ||
            protocol_engine.outstanding_count() != 1 ||
            protocol_engine.get_outstanding(0) != desc)
            `uvm_fatal("COMPLETE_PROTOCOL",
                       "over-count retired or changed outstanding state")
        protocol_engine.cleanup();
        protocol_mem.leak_check(`__FILE__, `__LINE__);
    endtask

    task wait_for_irq_completion_or_timeout();
        irq_wait_timed_out = 0;
        fork : flag_or_timeout
            begin
                wait (irq_wait_returned);
            end
            begin
                #(irq_wait_timeout);
                irq_wait_timed_out = 1;
            end
        join_any
        disable flag_or_timeout;
    endtask

    task check_irq_wait_watchdog();
        irq_wait_returned = 0;
        irq_wait_timeout  = irq_cfg.completion_timeout;
        wait_for_irq_completion_or_timeout();
        if (!irq_wait_timed_out)
            `uvm_fatal("IRQ_WATCHDOG",
                       "bounded IRQ completion wait did not report timeout")
    endtask

    task check_parallel_irq_waiters();
        gq_queue_cfg cfg_a;
        gq_queue_cfg cfg_b;
        mailbox_mock_adapter shared_adapter;
        gq_irq_wait_policy policy_a;
        gq_irq_wait_policy policy_b;
        bit returned_a;
        bit returned_b;
        bit wake_a;
        bit wake_b;

        cfg_a = gq_queue_cfg::type_id::create("parallel_irq_cfg_a");
        cfg_b = gq_queue_cfg::type_id::create("parallel_irq_cfg_b");
        cfg_a.queue_id = 24;
        cfg_b.queue_id = 25;
        cfg_a.role = GQ_TX;
        cfg_b.role = GQ_TX;
        cfg_a.completion_timeout = 100ns;
        cfg_b.completion_timeout = 100ns;
        shared_adapter = mailbox_mock_adapter::type_id::create(
            "parallel_irq_shared_adapter");
        policy_a = gq_irq_wait_policy::type_id::create(
            "parallel_irq_policy_a");
        policy_b = gq_irq_wait_policy::type_id::create(
            "parallel_irq_policy_b");
        returned_a = 0;
        returned_b = 0;
        wake_a = 0;
        wake_b = 0;

        fork
            begin
                policy_a.wait_for_wakeup(cfg_a, shared_adapter, wake_a);
                returned_a = 1;
            end
            begin
                policy_b.wait_for_wakeup(cfg_b, shared_adapter, wake_b);
                returned_b = 1;
            end
        join_none
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (shared_adapter.wait_irq_calls == 2)
                break;
        end
        if (shared_adapter.wait_irq_calls != 2)
            `uvm_fatal("IRQ_PARALLEL", "parallel IRQ waits did not arm")

        shared_adapter.trigger_irq(GQ_TX, cfg_a.queue_id);
        #1ns;
        if (!returned_a || !wake_a)
            `uvm_fatal("IRQ_PARALLEL", "first parallel IRQ wait did not wake")
        if (returned_b || wake_b)
            `uvm_fatal("IRQ_PARALLEL",
                       "first IRQ wake cancelled an unrelated queue wait")

        shared_adapter.trigger_irq(GQ_TX, cfg_b.queue_id);
        #1ns;
        if (!returned_b || !wake_b)
            `uvm_fatal("IRQ_PARALLEL", "second parallel IRQ wait did not wake")
    endtask

    task run_wait_mode(gq_queue_engine target_engine,
                       gq_queue_cfg target_cfg,
                       host_mem_manager target_mem,
                       mailbox_mock_adapter target_adapter,
                       gq_completion_collector target_collector);
        mailbox_tx_desc descs[3];
        gq_request request;
        gq_response response;
        mailbox_mock_dut target_dut;
        time wait_start;

        target_dut = mailbox_mock_dut::type_id::create(
            $sformatf("wait_dut_%0d", target_cfg.queue_id));
        target_dut.mem     = target_mem;
        target_dut.adapter = target_adapter;
        target_engine.initialize();
        request = gq_request::type_id::create(
            $sformatf("wait_request_%0d", target_cfg.queue_id));
        for (int unsigned i = 0; i < 3; i++) begin
            descs[i] = make_tx($sformatf("wait_%0d_desc_%0d",
                                         target_cfg.queue_id, i), i);
            request.add_desc(descs[i]);
        end
        response = gq_response::type_id::create(
            $sformatf("wait_response_%0d", target_cfg.queue_id));
        target_engine.submit_batch(request, response);
        if (response.status != GQ_OK)
            `uvm_fatal("WAIT_SUBMIT", "wait-mode setup submit failed")

        target_dut.complete_slot(target_engine, 0, 32, 64);
        target_dut.complete_slot(target_engine, 2, 32, 64);
        if (target_cfg.wait_mode == GQ_POLL) begin
            wait_start = $time;
            target_engine.wait_and_drain_once();
            if (($time - wait_start) < target_cfg.poll_interval)
                `uvm_fatal("WAIT_POLL", "poll wake did not wait poll_interval")
        end else begin
            irq_wait_returned = 0;
            irq_wait_timeout  = target_cfg.completion_timeout;
            fork : first_irq_wait
                begin
                    target_engine.wait_and_drain_once();
                    irq_wait_returned = 1;
                end
            join_none
            #1ns;
            if (irq_wait_returned)
                `uvm_fatal("WAIT_IRQ", "IRQ wait returned before an interrupt")
            target_dut.trigger_irq(target_cfg.role, target_cfg.queue_id);
            wait_for_irq_completion_or_timeout();
            if (irq_wait_timed_out)
                `uvm_fatal("WAIT_IRQ", "first IRQ completion wait timed out")
        end
        if (target_collector.retired_srcids.size() != 1 ||
            target_collector.retired_srcids[0] != 16'h5100)
            `uvm_fatal("WAIT_ORDER", "first wait retired the wrong descriptors")

        target_dut.complete_slot(target_engine, 1, 32, 64);
        if (target_cfg.wait_mode == GQ_POLL) begin
            target_engine.wait_and_drain_once();
        end else begin
            irq_wait_returned = 0;
            irq_wait_timeout  = target_cfg.completion_timeout;
            fork : second_irq_wait
                begin
                    target_engine.wait_and_drain_once();
                    irq_wait_returned = 1;
                end
            join_none
            #1ns;
            target_dut.trigger_irq(target_cfg.role, target_cfg.queue_id);
            wait_for_irq_completion_or_timeout();
            if (irq_wait_timed_out)
                `uvm_fatal("WAIT_IRQ", "second IRQ completion wait timed out")
        end
        if (target_collector.retired_srcids.size() != 3 ||
            target_collector.retired_srcids[1] != 16'h5101 ||
            target_collector.retired_srcids[2] != 16'h5102)
            `uvm_fatal("WAIT_ORDER", "second wait retired out of order")
        if (target_cfg.wait_mode == GQ_IRQ &&
            (target_adapter.wait_irq_calls != 2 ||
             target_adapter.ack_irq_calls != 2))
            `uvm_fatal("WAIT_IRQ", "IRQ waits were not acknowledged exactly once")
        target_engine.cleanup();
        target_mem.leak_check(`__FILE__, `__LINE__);
    endtask

    task check_run_phase_worker();
        uvm_component component_handle;
        gq_queue_engine worker_engine;
        mailbox_mock_dut worker_dut;
        mailbox_tx_desc desc;
        gq_request request;
        gq_response response;
        bit completion_seen;

        worker_env_cfg.wait_ready();
        component_handle = uvm_root::get().find(
            "uvm_test_top.worker_env.tx_20.completion_worker");
        if (component_handle == null)
            `uvm_fatal("WORKER_PATH", "agent completion worker was not built")
        component_handle = uvm_root::get().find(
            "uvm_test_top.worker_env.tx_20.engine");
        if (!$cast(worker_engine, component_handle))
            `uvm_fatal("WORKER_PATH", "could not find run-phase engine")

        worker_dut = mailbox_mock_dut::type_id::create("worker_dut");
        worker_dut.mem     = worker_mem;
        worker_dut.adapter = worker_adapter;
        desc = make_tx("worker_desc", 9);
        request = gq_request::type_id::create("worker_request");
        request.add_desc(desc);
        response = gq_response::type_id::create("worker_response");
        worker_engine.submit_batch(request, response);
        worker_dut.complete_slot(worker_engine, 0, 32, 64);
        completion_seen = 0;
        fork : worker_or_timeout
            begin
                wait (worker_collector.retired_srcids.size() == 1);
                completion_seen = 1;
            end
            begin
                #100ns;
            end
        join_any
        disable worker_or_timeout;
        if (!completion_seen || worker_collector.retired_srcids[0] != 16'h5109)
            `uvm_fatal("WORKER_RUN", "run-phase worker did not drain completion")
        worker_env.cleanup();
        worker_mem.leak_check(`__FILE__, `__LINE__);
    endtask

    task check_tx_phase_wrap();
        mailbox_tx_desc fill_descs[29];
        mailbox_tx_desc wrapped_desc;
        mailbox_tx_desc decoded;
        gq_request request;
        gq_response response;
        byte packed_data[];

        request = gq_request::type_id::create("tx_fill_request");
        for (int unsigned i = 0; i < 29; i++) begin
            fill_descs[i] = make_tx($sformatf("tx_fill_%0d", i), i + 3);
            request.add_desc(fill_descs[i]);
        end
        response = gq_response::type_id::create("tx_fill_response");
        engine.submit_batch(request, response);
        if (response.status != GQ_OK || response.committed_count != 29)
            `uvm_fatal("TX_WRAP", "could not fill the first TX ring phase")
        for (gq_logical_seq_t seq = 3; seq < 32; seq++)
            dut.complete_slot(engine, seq, 32, 64);
        engine.drain_completed();
        if (engine.head_seq() != 32 || engine.tail_seq() != 32 ||
            collector.retired_srcids.size() != 32)
            `uvm_fatal("TX_WRAP", "first TX ring phase did not retire")

        wrapped_desc = make_tx("tx_wrapped_desc", 32);
        request = gq_request::type_id::create("tx_wrapped_request");
        request.add_desc(wrapped_desc);
        response = gq_response::type_id::create("tx_wrapped_response");
        engine.submit_batch(request, response);
        mem.read_mem(engine.ring_base(), 64, packed_data,
                     `__FILE__, `__LINE__);
        decoded = mailbox_tx_desc::type_id::create("tx_wrapped_decoded");
        if (!decoded.unpack(packed_data) || decoded.flags !== 16'h0001 ||
            wrapped_desc.flags !== 16'h0001)
            `uvm_fatal("TX_WRAP",
                       "wrapped TX pending ownership flags are incorrect")
        dut.complete_slot(engine, 32, 32, 64);
        engine.drain_completed();
        if (engine.head_seq() != 33 || collector.retired_srcids.size() != 33 ||
            collector.retired_srcids[32] != 16'h5120)
            `uvm_fatal("TX_WRAP", "wrapped TX descriptor did not retire")
        if (engine.outstanding_audit_steps != 0)
            `uvm_fatal("COMPLETE_SCALE", "regular drain performed a full audit")
    endtask

    task check_rx_phase_wrap();
        mailbox_rx_desc descs[32];
        mailbox_rx_desc wrapped_desc;
        mailbox_rx_desc decoded;
        mailbox_mock_dut rx_dut;
        gq_request request;
        gq_response response;
        byte payload[];
        byte packed_data[];

        rx_dut = mailbox_mock_dut::type_id::create("rx_dut");
        rx_dut.mem     = rx_mem;
        rx_dut.adapter = rx_adapter;
        rx_engine.initialize();
        request = gq_request::type_id::create("rx_fill_request");
        for (int unsigned i = 0; i < 32; i++) begin
            descs[i] = mailbox_rx_desc::type_id::create(
                $sformatf("rx_fill_%0d", i));
            descs[i].buf_len = 4;
            request.add_desc(descs[i]);
        end
        response = gq_response::type_id::create("rx_fill_response");
        rx_engine.submit_batch(request, response);
        if (response.status != GQ_OK || response.committed_count != 32)
            `uvm_fatal("RX_WRAP", "could not fill the first RX ring phase")
        payload = new[4];
        for (int unsigned i = 0; i < 32; i++) begin
            foreach (payload[j])
                payload[j] = byte'(i + j);
            rx_mem.write_mem(descs[i].buf_addr, payload,
                             `__FILE__, `__LINE__);
            rx_dut.complete_slot(rx_engine, i, 32, 16);
        end
        rx_engine.drain_completed();
        if (rx_engine.head_seq() != 32 || rx_engine.tail_seq() != 32 ||
            rx_collector.rx_first_bytes.size() != 32)
            `uvm_fatal("RX_WRAP", "first RX ring phase did not retire")
        for (int unsigned i = 0; i < 32; i++) begin
            if (rx_collector.rx_first_bytes[i] != byte'(i))
                `uvm_fatal("RX_ORDER", "RX analysis order/data is incorrect")
        end

        wrapped_desc = mailbox_rx_desc::type_id::create("rx_wrapped_desc");
        wrapped_desc.buf_len = 4;
        request = gq_request::type_id::create("rx_wrapped_request");
        request.add_desc(wrapped_desc);
        response = gq_response::type_id::create("rx_wrapped_response");
        rx_engine.submit_batch(request, response);
        rx_mem.read_mem(rx_engine.ring_base(), 16, packed_data,
                        `__FILE__, `__LINE__);
        decoded = mailbox_rx_desc::type_id::create("rx_wrapped_decoded");
        if (!decoded.unpack(packed_data) || decoded.flags !== 16'h0001 ||
            wrapped_desc.flags !== 16'h0001)
            `uvm_fatal("RX_WRAP",
                       "wrapped RX pending ownership flags are incorrect")
        foreach (payload[j])
            payload[j] = byte'(8'ha5 + j);
        rx_mem.write_mem(wrapped_desc.buf_addr, payload,
                         `__FILE__, `__LINE__);
        rx_dut.complete_slot(rx_engine, 32, 32, 16);
        rx_engine.drain_completed();
        if (rx_engine.head_seq() != 33 ||
            rx_collector.rx_first_bytes.size() != 33 ||
            rx_collector.rx_first_bytes[32] != 8'ha5 ||
            !rx_collector.observed_owned_memory)
            `uvm_fatal("RX_WRAP", "wrapped RX completion/analysis is incorrect")
        rx_engine.cleanup();
        rx_mem.leak_check(`__FILE__, `__LINE__);
    endtask

    task check_cleanup_during_poll_wait();
        bit worker_returned;

        cleanup_engine.initialize();
        worker_returned = 0;
        fork : cleanup_worker
            begin
                cleanup_engine.run_completion_worker();
                worker_returned = 1;
            end
        join_none
        #1ns;
        cleanup_engine.cleanup();
        #(cleanup_cfg.poll_interval + 1ns);
        if (!worker_returned)
            `uvm_fatal("CLEANUP_WORKER", "poll worker did not stop after cleanup")
        if (cleanup_source.query_calls != 0)
            `uvm_fatal("CLEANUP_WORKER",
                       "poll worker queried completion source after cleanup")
        cleanup_mem.leak_check(`__FILE__, `__LINE__);
    endtask

    task run_phase(uvm_phase phase);
        mailbox_tx_desc descs[3];
        gq_request request;
        gq_response response;

        phase.raise_objection(this);
        engine.initialize();
        check_completion_validation();
        check_tail_memory_endian();
        check_tail_engine_integration();
        check_overcount_protocol();
        check_irq_wait_watchdog();
        check_parallel_irq_waiters();
        run_wait_mode(poll_engine, poll_cfg, poll_mem, poll_adapter,
                      poll_collector);
        run_wait_mode(irq_engine, irq_cfg, irq_mem, irq_adapter,
                      irq_collector);
        for (int unsigned i = 0; i < poll_collector.retired_srcids.size(); i++) begin
            if (poll_collector.retired_srcids[i] !=
                irq_collector.retired_srcids[i])
                `uvm_fatal("WAIT_EQUIV", "poll and IRQ completion order differs")
        end
        check_run_phase_worker();
        check_cleanup_during_poll_wait();
        request = gq_request::type_id::create("request");
        for (int unsigned i = 0; i < 3; i++) begin
            descs[i] = make_tx($sformatf("desc_%0d", i), i);
            if (i == 0)
                descs[i].buf_len = 16;
            request.add_desc(descs[i]);
        end
        response = gq_response::type_id::create("response");
        engine.submit_batch(request, response);
        if (response.status != GQ_OK || response.committed_count != 3)
            `uvm_fatal("COMPLETE_SUBMIT", "three-descriptor submit failed")

        dut.complete_slot(engine, 0, cfg.depth, cfg.desc_size);
        dut.complete_slot(engine, 2, cfg.depth, cfg.desc_size);
        engine.drain_completed();
        if (collector.retired_srcids.size() != 1 ||
            collector.retired_srcids[0] != 16'h5100 ||
            engine.head_seq() != 1 || engine.outstanding_count() != 2)
            `uvm_fatal("COMPLETE_ORDER", "slot 2 retired across incomplete slot 1")
        if (!collector.observed_owned_memory)
            `uvm_fatal("COMPLETE_RELEASE",
                       "analysis subscriber could not observe owned TX memory")

        dut.complete_slot(engine, 1, cfg.depth, cfg.desc_size);
        engine.drain_completed();
        if (collector.retired_srcids.size() != 3 ||
            collector.retired_srcids[1] != 16'h5101 ||
            collector.retired_srcids[2] != 16'h5102 ||
            engine.head_seq() != 3 || engine.outstanding_count() != 0)
            `uvm_fatal("COMPLETE_ORDER", "remaining descriptors retired out of order")

        check_tx_phase_wrap();
        check_rx_phase_wrap();

        engine.cleanup();
        mem.leak_check(`__FILE__, `__LINE__);
        phase.drop_objection(this);
    endtask
endclass

`endif
