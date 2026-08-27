`ifndef GQ_RESET_TEST_SV
`define GQ_RESET_TEST_SV

class gq_reset_spy_mem extends host_mem_manager;
    int unsigned ring_alloc_calls;
    int unsigned ring_free_calls;
    bit enforce_disable_before_desc_free;
    bit queue_disable_observed;
    bit pre_disable_desc_free;
    bit enforce_publish_quiescence;
    bit publish_quiesced;
    bit pre_quiesce_desc_free;
    bit pre_quiesce_ring_free;
    int unsigned descriptor_free_calls;
    protected bit ring_allocations[gq_addr_t];

    function new(string name = "gq_reset_spy_mem");
        super.new(name);
        ring_alloc_calls = 0;
        ring_free_calls  = 0;
        enforce_disable_before_desc_free = 0;
        queue_disable_observed            = 0;
        pre_disable_desc_free              = 0;
        enforce_publish_quiescence = 0;
        publish_quiesced = 1;
        pre_quiesce_desc_free = 0;
        pre_quiesce_ring_free = 0;
        descriptor_free_calls = 0;
    endfunction

    virtual function bit [63:0] alloc(
        int unsigned size,
        int unsigned align = 1,
        string file = "",
        int line = 0);
        bit [63:0] addr;

        addr = super.alloc(size, align, file, line);
        if (addr != '1 && size >= 512) begin
            ring_alloc_calls++;
            ring_allocations[addr] = 1;
        end
        return addr;
    endfunction

    virtual function void free(
        bit [63:0] addr,
        string file = "",
        int line = 0);
        bit is_ring_allocation;

        is_ring_allocation = ring_allocations.exists(addr);
        if (enforce_disable_before_desc_free && !queue_disable_observed &&
            !is_ring_allocation)
            pre_disable_desc_free = 1;
        if (enforce_publish_quiescence && !publish_quiesced) begin
            if (is_ring_allocation)
                pre_quiesce_ring_free = 1;
            else
                pre_quiesce_desc_free = 1;
        end
        if (ring_allocations.exists(addr)) begin
            ring_free_calls++;
            ring_allocations.delete(addr);
        end else
            descriptor_free_calls++;
        super.free(addr, file, line);
    endfunction
endclass

class gq_reset_order_adapter extends mailbox_mock_adapter;
    `uvm_object_utils(gq_reset_order_adapter)

    string configure_order[$];
    string disable_order[$];
    time publish_delay;
    uvm_event publish_entered;
    bit block_publish_until_disable;
    string blocked_publish_key;
    uvm_event publish_cancelled;
    uvm_event cancel_observed;
    uvm_event allow_cancelled_publish_return;
    int unsigned cancelled_publish_count;
    bit hold_cancelled_publish_return;
    bit publish_returned;
    bit disabled_state[string];
    bit post_disable_publish;
    gq_reset_spy_mem spy_mem;

    function new(string name = "gq_reset_order_adapter");
        super.new(name);
        publish_delay        = 0;
        publish_entered      = new({name, "_publish_entered"});
        block_publish_until_disable = 0;
        blocked_publish_key = "";
        publish_cancelled = new({name, "_publish_cancelled"});
        cancel_observed = new({name, "_cancel_observed"});
        allow_cancelled_publish_return = new(
            {name, "_allow_cancelled_publish_return"});
        cancelled_publish_count = 0;
        hold_cancelled_publish_return = 0;
        publish_returned = 0;
        post_disable_publish = 0;
    endfunction

    virtual task configure_queue(
        gq_role_e role,
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned desc_size);
        configure_order.push_back(gq_queue_key(role, queue_id));
        super.configure_queue(role, queue_id, base, depth, desc_size);
        disabled_state[gq_queue_key(role, queue_id)] = 0;
    endtask

    virtual task disable_queue(gq_role_e role, int unsigned queue_id);
        string key;

        key = gq_queue_key(role, queue_id);
        disabled_state[key] = 1;
        if (block_publish_until_disable && key == blocked_publish_key) begin
            if (spy_mem != null) begin
                spy_mem.enforce_publish_quiescence = 1;
                spy_mem.publish_quiesced = 0;
                spy_mem.pre_quiesce_desc_free = 0;
                spy_mem.pre_quiesce_ring_free = 0;
            end
            publish_cancelled.trigger();
        end
        if (spy_mem != null && spy_mem.enforce_disable_before_desc_free)
            spy_mem.queue_disable_observed = 1;
        disable_order.push_back(key);
        super.disable_queue(role, queue_id);
    endtask

    virtual task publish(gq_role_e role, int unsigned queue_id,
                         gq_raw_ptr_t raw_tail);
        string key;

        key = gq_queue_key(role, queue_id);
        publish_entered.trigger();
        if (block_publish_until_disable && key == blocked_publish_key) begin
            publish_cancelled.wait_on();
            publish_cancelled.reset();
            cancelled_publish_count++;
            cancel_observed.trigger();
            if (hold_cancelled_publish_return) begin
                allow_cancelled_publish_return.wait_on();
                allow_cancelled_publish_return.reset();
            end
            if (spy_mem != null)
                spy_mem.publish_quiesced = 1;
            publish_returned = 1;
            return;
        end
        #(publish_delay);
        if (disabled_state.exists(key) && disabled_state[key])
            post_disable_publish = 1;
        super.publish(role, queue_id, raw_tail);
    endtask
endclass

class gq_reset_irq_adapter extends mailbox_mock_adapter;
    `uvm_object_utils(gq_reset_irq_adapter)

    time ack_delay;
    uvm_event ack_entered;

    function new(string name = "gq_reset_irq_adapter");
        super.new(name);
        ack_delay   = 0;
        ack_entered = new({name, "_ack_entered"});
    endfunction

    virtual task ack_irq(gq_role_e role, int unsigned queue_id);
        ack_entered.trigger();
        #(ack_delay);
        super.ack_irq(role, queue_id);
    endtask
endclass

class gq_reset_counting_completion extends mailbox_completion;
    `uvm_object_utils(gq_reset_counting_completion)

    int unsigned query_calls;

    function new(string name = "gq_reset_counting_completion");
        super.new(name);
        query_calls = 0;
    endfunction

    virtual task query_completed(
        host_mem_api mem,
        gq_hw_adapter adapter,
        gq_addr_t ring_base,
        gq_addr_t status_addr,
        int unsigned depth,
        int unsigned desc_size,
        gq_logical_seq_t logical_head,
        input gq_desc_base pending[$],
        output bit valid,
        output int unsigned completed_count);
        query_calls++;
        super.query_completed(mem, adapter, ring_base, status_addr, depth,
                              desc_size, logical_head, pending, valid,
                              completed_count);
    endtask
endclass

class gq_reset_lifecycle_adapter extends mailbox_mock_adapter;
    `uvm_object_utils(gq_reset_lifecycle_adapter)

    time configure_delay;
    time disable_delay;
    uvm_event configure_entered;
    uvm_event disable_entered;

    function new(string name = "gq_reset_lifecycle_adapter");
        super.new(name);
        configure_delay = 0;
        disable_delay = 0;
        configure_entered = new({name, "_configure_entered"});
        disable_entered = new({name, "_disable_entered"});
    endfunction

    virtual task configure_queue(
        gq_role_e role,
        int unsigned queue_id,
        gq_addr_t base,
        int unsigned depth,
        int unsigned desc_size);
        configure_entered.trigger();
        #(configure_delay);
        super.configure_queue(role, queue_id, base, depth, desc_size);
    endtask

    virtual task disable_queue(gq_role_e role, int unsigned queue_id);
        disable_entered.trigger();
        #(disable_delay);
        super.disable_queue(role, queue_id);
    endtask
endclass

class gq_reset_race_engine extends gq_queue_engine;
    `uvm_component_utils(gq_reset_race_engine)

    uvm_event completion_query_returned_event;
    uvm_event allow_completion_return;
    uvm_event completion_validated_event;
    uvm_event allow_completion_commit;
    bit pause_after_validation;

    function new(string name = "gq_reset_race_engine",
                 uvm_component parent = null);
        super.new(name, parent);
        completion_query_returned_event = new({name, "_query_returned"});
        allow_completion_return         = new({name, "_allow_return"});
        completion_validated_event      = new({name, "_validated"});
        allow_completion_commit         = new({name, "_allow_commit"});
        pause_after_validation          = 0;
    endfunction

    protected virtual task completion_query_returned();
        completion_query_returned_event.trigger();
        allow_completion_return.wait_on();
        allow_completion_return.reset();
    endtask

    protected virtual task completion_commit_entered();
        if (pause_after_validation) begin
            completion_validated_event.trigger();
            allow_completion_commit.wait_on();
            allow_completion_commit.reset();
        end
    endtask

    task probe_serialization_locks_for_test();
        submit_serialization.get(1);
        submit_serialization.put(1);
        completion_serialization.get(1);
        completion_serialization.put(1);
    endtask

    task configuration_done_for_test(output bit done);
        state_lock.get(1);
        done = configuration_done != null && configuration_done.is_on();
        state_lock.put(1);
    endtask
endclass

class gq_reset_test extends uvm_test;
    `uvm_component_utils(gq_reset_test)

    gq_reset_spy_mem      mem;
    gq_test_ptr_codec     ptr_codec;
    gq_reset_order_adapter adapter;
    mailbox_mock_dut      dut;
    mailbox_env_cfg       env_cfg;
    mailbox_env           env;
    mailbox_env_cfg       disabled_cfg;
    mailbox_env           disabled_env;
    gq_completion_collector collector;
    host_mem_manager      irq_mem;
    gq_reset_irq_adapter  irq_adapter;
    gq_reset_counting_completion irq_completion;
    mailbox_mock_dut      irq_dut;
    gq_queue_cfg          irq_cfg;
    gq_queue_engine       irq_engine;
    gq_completion_collector irq_collector;
    host_mem_manager      stale_mem;
    gq_reset_lifecycle_adapter stale_adapter;
    mailbox_mock_dut      stale_dut;
    gq_queue_cfg          stale_cfg;
    gq_reset_race_engine  stale_engine;
    gq_completion_collector stale_collector;
    gq_reset_spy_mem      repost_mem;
    gq_reset_order_adapter repost_adapter;
    gq_queue_cfg          repost_cfg;
    gq_reset_race_engine  repost_engine;
    gq_reset_spy_mem      publish_reset_mem;
    gq_reset_order_adapter publish_reset_adapter;
    gq_queue_cfg          publish_reset_cfg;
    gq_queue_engine       publish_reset_engine;

    function new(string name = "gq_reset_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function gq_queue_engine find_engine(string key);
        uvm_component component_handle;
        gq_queue_engine engine;

        component_handle = uvm_root::get().find(
            {"uvm_test_top.env.", key, ".engine"});
        if (!$cast(engine, component_handle))
            `uvm_fatal("RESET_PATH", {"could not find engine ", key})
        return engine;
    endfunction

    function gq_sequencer find_sequencer(string key);
        uvm_component component_handle;
        gq_sequencer sequencer;

        component_handle = uvm_root::get().find(
            {"uvm_test_top.env.", key, ".sequencer"});
        if (!$cast(sequencer, component_handle))
            `uvm_fatal("RESET_PATH", {"could not find sequencer ", key})
        return sequencer;
    endfunction

    function mailbox_tx_desc make_tx(string name, int unsigned index);
        mailbox_tx_desc desc;

        desc = mailbox_tx_desc::type_id::create(name);
        desc.srcid    = 16'h7000 + index;
        desc.dstid    = 16'h7100 + index;
        desc.msg_type = 16'h7200 + index;
        desc.buf_len  = 16;
        desc.data_len = 4;
        for (int unsigned i = 0; i < desc.data_len; i++)
            desc.data[i] = byte'(index + i);
        return desc;
    endfunction

    task wait_for_disable_count(int unsigned expected);
        bit seen;

        seen = 0;
        for (int unsigned poll = 0; poll < 200; poll++) begin
            #1ns;
            if (adapter.disable_calls == expected) begin
                seen = 1;
                break;
            end
        end
        if (!seen)
            `uvm_fatal("RESET_TIMEOUT", $sformatf(
                "disable count did not reach %0d", expected))
    endtask

    task wait_for_configure_count(int unsigned expected);
        bit seen;

        seen = 0;
        for (int unsigned poll = 0; poll < 200; poll++) begin
            #1ns;
            if (adapter.configure_calls == expected) begin
                seen = 1;
                break;
            end
        end
        if (!seen)
            `uvm_fatal("RESET_TIMEOUT", $sformatf(
                "configure count did not reach %0d", expected))
    endtask

    function void build_phase(uvm_phase phase);
        string reason;

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_7000_0000,
                        64'h0000_0001_70ff_ffff, MODE_LINEAR, 16);
        ptr_codec = gq_test_ptr_codec::type_id::create("ptr_codec");
        adapter   = gq_reset_order_adapter::type_id::create("adapter");
        adapter.spy_mem = mem;
        dut       = mailbox_mock_dut::type_id::create("dut");
        dut.mem     = mem;
        dut.adapter = adapter;
        env_cfg   = mailbox_env_cfg::type_id::create("env_cfg");
        env_cfg.mem       = mem;
        env_cfg.adapter   = adapter;
        env_cfg.ptr_codec = ptr_codec;
        if (!env_cfg.add_tx(7, 32, reason) ||
            !env_cfg.add_rx(5, 32, reason) ||
            !env_cfg.add_rx(6, 32, reason))
            `uvm_fatal("RESET_CFG", reason)
        uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", env_cfg);
        env = mailbox_env::type_id::create("env", this);
        disabled_cfg = mailbox_env_cfg::type_id::create("disabled_cfg");
        disabled_cfg.mem       = mem;
        disabled_cfg.adapter   = adapter;
        disabled_cfg.ptr_codec = ptr_codec;
        uvm_config_db#(gq_env_cfg)::set(this, "disabled_env", "cfg",
                                        disabled_cfg);
        disabled_env = mailbox_env::type_id::create("disabled_env", this);
        collector = gq_completion_collector::type_id::create(
            "collector", this);

        irq_mem = new("irq_mem");
        irq_mem.init_region(64'h0000_0001_7100_0000,
                            64'h0000_0001_71ff_ffff, MODE_LINEAR, 16);
        irq_adapter = gq_reset_irq_adapter::type_id::create("irq_adapter");
        irq_completion = gq_reset_counting_completion::type_id::create(
            "irq_completion");
        irq_dut = mailbox_mock_dut::type_id::create("irq_dut");
        irq_dut.mem     = irq_mem;
        irq_dut.adapter = irq_adapter;
        irq_cfg = gq_queue_cfg::type_id::create("irq_cfg");
        irq_cfg.queue_id           = 19;
        irq_cfg.role               = GQ_TX;
        irq_cfg.depth              = 32;
        irq_cfg.desc_size          = 64;
        irq_cfg.alignment          = 64;
        irq_cfg.status_area_size   = 0;
        irq_cfg.wait_mode          = GQ_IRQ;
        irq_cfg.poll_min_interval  = 1ns;
        irq_cfg.poll_max_interval  = 1ns;
        irq_cfg.completion_timeout = 20ns;
        irq_cfg.ptr_codec          = ptr_codec;
        irq_cfg.completion_source  = irq_completion;
        uvm_config_db#(gq_queue_cfg)::set(this, "irq_engine", "cfg", irq_cfg);
        uvm_config_db#(host_mem_api)::set(this, "irq_engine", "mem", irq_mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "irq_engine", "adapter",
                                           irq_adapter);
        irq_engine = gq_queue_engine::type_id::create("irq_engine", this);
        irq_collector = gq_completion_collector::type_id::create(
            "irq_collector", this);

        stale_mem = new("stale_mem");
        stale_mem.init_region(64'h0000_0001_7200_0000,
                              64'h0000_0001_72ff_ffff, MODE_LINEAR, 16);
        stale_adapter = gq_reset_lifecycle_adapter::type_id::create(
            "stale_adapter");
        stale_dut = mailbox_mock_dut::type_id::create("stale_dut");
        stale_dut.mem     = stale_mem;
        stale_dut.adapter = stale_adapter;
        stale_cfg = gq_queue_cfg::type_id::create("stale_cfg");
        stale_cfg.queue_id           = 21;
        stale_cfg.role               = GQ_TX;
        stale_cfg.depth              = 32;
        stale_cfg.desc_size          = 64;
        stale_cfg.alignment          = 64;
        stale_cfg.status_area_size   = 0;
        stale_cfg.wait_mode          = GQ_POLL;
        stale_cfg.poll_min_interval  = 1ns;
        stale_cfg.poll_max_interval  = 1ns;
        stale_cfg.completion_timeout = 20ns;
        stale_cfg.ptr_codec          = ptr_codec;
        stale_cfg.completion_source  = mailbox_completion::type_id::create(
            "stale_completion");
        uvm_config_db#(gq_queue_cfg)::set(this, "stale_engine", "cfg",
                                          stale_cfg);
        uvm_config_db#(host_mem_api)::set(this, "stale_engine", "mem",
                                          stale_mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "stale_engine", "adapter",
                                           stale_adapter);
        stale_engine = gq_reset_race_engine::type_id::create(
            "stale_engine", this);
        stale_collector = gq_completion_collector::type_id::create(
            "stale_collector", this);

        repost_mem = new("repost_mem");
        repost_mem.init_region(64'h0000_0001_7300_0000,
                               64'h0000_0001_73ff_ffff, MODE_LINEAR, 16);
        repost_adapter = gq_reset_order_adapter::type_id::create(
            "repost_adapter");
        repost_adapter.spy_mem = repost_mem;
        repost_cfg = gq_queue_cfg::type_id::create("repost_cfg");
        repost_cfg.queue_id           = 22;
        repost_cfg.role               = GQ_RX;
        repost_cfg.depth              = 32;
        repost_cfg.desc_size          = 16;
        repost_cfg.alignment          = 64;
        repost_cfg.status_area_size   = 0;
        repost_cfg.wait_mode          = GQ_POLL;
        repost_cfg.poll_min_interval  = 1ns;
        repost_cfg.poll_max_interval  = 1ns;
        repost_cfg.completion_timeout = 20ns;
        repost_cfg.ptr_codec          = ptr_codec;
        repost_cfg.completion_source  = mailbox_completion::type_id::create(
            "repost_completion");
        uvm_config_db#(gq_queue_cfg)::set(this, "repost_engine", "cfg",
                                          repost_cfg);
        uvm_config_db#(host_mem_api)::set(this, "repost_engine", "mem",
                                          repost_mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "repost_engine", "adapter",
                                           repost_adapter);
        repost_engine = gq_reset_race_engine::type_id::create(
            "repost_engine", this);

        publish_reset_mem = new("publish_reset_mem");
        publish_reset_mem.init_region(64'h0000_0001_7400_0000,
                                      64'h0000_0001_74ff_ffff,
                                      MODE_LINEAR, 16);
        publish_reset_adapter = gq_reset_order_adapter::type_id::create(
            "publish_reset_adapter");
        publish_reset_adapter.spy_mem = publish_reset_mem;
        publish_reset_cfg = gq_queue_cfg::type_id::create(
            "publish_reset_cfg");
        publish_reset_cfg.queue_id           = 23;
        publish_reset_cfg.role               = GQ_TX;
        publish_reset_cfg.depth              = 32;
        publish_reset_cfg.desc_size          = 64;
        publish_reset_cfg.alignment          = 64;
        publish_reset_cfg.status_area_size   = 0;
        publish_reset_cfg.wait_mode          = GQ_POLL;
        publish_reset_cfg.poll_min_interval  = 1ns;
        publish_reset_cfg.poll_max_interval  = 1ns;
        publish_reset_cfg.completion_timeout = 20ns;
        publish_reset_cfg.ptr_codec          = ptr_codec;
        publish_reset_cfg.completion_source =
            mailbox_completion::type_id::create("publish_reset_completion");
        uvm_config_db#(gq_queue_cfg)::set(
            this, "publish_reset_engine", "cfg", publish_reset_cfg);
        uvm_config_db#(host_mem_api)::set(
            this, "publish_reset_engine", "mem", publish_reset_mem);
        uvm_config_db#(gq_hw_adapter)::set(
            this, "publish_reset_engine", "adapter", publish_reset_adapter);
        publish_reset_engine = gq_queue_engine::type_id::create(
            "publish_reset_engine", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        gq_queue_engine tx_engine;

        super.connect_phase(phase);
        tx_engine = find_engine("tx_7");
        tx_engine.completion_ap.connect(collector.analysis_export);
        stale_engine.completion_ap.connect(stale_collector.analysis_export);
        irq_engine.completion_ap.connect(irq_collector.analysis_export);
    endfunction

    task run_phase(uvm_phase phase);
        gq_queue_engine tx_engine;
        gq_queue_engine rx_engine;
        gq_queue_engine rx_no_restart_engine;
        gq_sequencer tx_sequencer;
        gq_sequencer rx_sequencer;
        gq_sequencer rx_no_restart_sequencer;
        mailbox_tx_sequence tx_sequence;
        mailbox_tx_sequence reset_sequence;
        mailbox_rx_start_sequence rx_sequence;
        mailbox_tx_sequence recovered_sequence;
        mailbox_tx_sequence fill_sequence;
        mailbox_tx_sequence blocked_sequence;
        gq_deterministic_refill_profile profile;
        gq_deterministic_refill_profile no_restart_profile;
        gq_deterministic_refill_profile new_no_restart_profile;
        mailbox_rx_start_sequence no_restart_sequence;
        mailbox_rx_start_sequence new_no_restart_sequence;
        gq_addr_t old_tx_ring;
        gq_addr_t old_rx_ring;
        bit irq_worker_returned;
        mailbox_tx_desc stale_desc;
        gq_request stale_request;
        gq_response stale_response;
        bit stale_query_seen;
        bit stale_drain_returned;
        bit stale_reset_returned;
        bit commit_drain_returned;
        bit commit_reset_returned;
        mailbox_tx_desc irq_desc;
        gq_request irq_request;
        gq_response irq_response;
        bit cleanup_blocked_returned;
        bit cleanup_call_returned;
        gq_request cleanup_fill_request;
        gq_request cleanup_blocked_request;
        gq_response cleanup_fill_response;
        gq_response cleanup_blocked_response;
        bit blocked_sequence_returned;
        bit refill_publish_seen;
        time irq_reset_start;
        bit delayed_ack_reset_returned;
        int unsigned disable_calls_before_delayed_ack;
        gq_request global_publish_request;
        gq_response global_publish_response;
        gq_request cleanup_publish_request;
        gq_response cleanup_publish_response;
        bit cleanup_publish_returned;
        bit env_cleanup_returned;
        int unsigned publish_count_before_cancel;
        int unsigned cancelled_count_before_cleanup;
        int unsigned lifetime_ring_free_before;
        int unsigned lifetime_desc_free_before;
        bit disable_cleanup_returned;
        bit disable_drain_returned;
        bit configure_release_returned;
        bit configure_cleanup_returned;
        bit configure_probe_returned;
        int unsigned configure_calls_before_race;
        int unsigned disable_calls_before_configure_race;
        bit cleanup_owner_returned;
        bit cleanup_joiner_returned;
        bit cleanup_initialize_returned;
        int unsigned disable_calls_before_cleanup_join;
        int unsigned configure_calls_before_cleanup_join;
        gq_deterministic_refill_profile repost_profile;
        gq_request repost_start_request;
        gq_response repost_start_response;
        bit repost_release_returned;
        bit repost_cleanup_returned;
        bit repost_configuration_done;
        int unsigned repost_publish_count_before;
        int unsigned repost_disable_count_before;
        gq_request publish_reset_request;
        gq_response publish_reset_response;
        bit publish_reset_submit_returned;
        bit publish_reset_assert_returned;
        int unsigned publish_reset_count_before;
        int unsigned publish_reset_ring_free_before;
        int unsigned publish_reset_desc_free_before;

        phase.raise_objection(this);
        fork : reset_test_watchdog
            begin
                #10us;
                `uvm_fatal("RESET_WATCHDOG",
                           "gq_reset_test exceeded 10us; probable lifecycle deadlock")
            end
        join_none
        env_cfg.wait_ready();
        disabled_cfg.wait_ready();
        tx_engine    = find_engine("tx_7");
        rx_engine    = find_engine("rx_5");
        rx_no_restart_engine = find_engine("rx_6");
        tx_sequencer = find_sequencer("tx_7");
        rx_sequencer = find_sequencer("rx_5");
        rx_no_restart_sequencer = find_sequencer("rx_6");

        if (disabled_env.agent_count() != 0 ||
            adapter.configure_calls != 3 || mem.ring_alloc_calls != 3)
            `uvm_fatal("RESET_INIT", "initial rings were not configured")
        if (env_cfg.trigger_reset_deasserted())
            `uvm_fatal("RESET_EVENT", "out-of-order reset release was accepted")

        tx_sequence = mailbox_tx_sequence::type_id::create("tx_sequence");
        tx_sequence.add_desc(make_tx("tx_0", 0));
        tx_sequence.add_desc(make_tx("tx_1", 1));
        tx_sequence.start(tx_sequencer);
        if (tx_sequence.response == null ||
            tx_sequence.response.status != GQ_OK ||
            tx_sequence.response.committed_count != 2 ||
            tx_sequence.response.reset_epoch != 0)
            `uvm_fatal("RESET_TX", "initial TX submit failed")

        profile = gq_deterministic_refill_profile::type_id::create("profile");
        profile.initial_post_count  = 3;
        profile.low_watermark       = 1;
        profile.high_watermark      = 3;
        profile.restart_after_reset = 1;
        profile.base_len            = 80;
        rx_sequence = mailbox_rx_start_sequence::type_id::create("rx_sequence");
        rx_sequence.set_refill_profile(profile);
        rx_sequence.start(rx_sequencer);
        if (rx_sequence.response == null ||
            rx_sequence.response.status != GQ_OK ||
            rx_sequence.response.committed_count != 3 ||
            rx_sequence.response.reset_epoch != 0)
            `uvm_fatal("RESET_RX", "initial RX start failed")

        no_restart_profile = gq_deterministic_refill_profile::type_id::create(
            "no_restart_profile");
        no_restart_profile.initial_post_count  = 2;
        no_restart_profile.low_watermark       = 1;
        no_restart_profile.high_watermark      = 3;
        no_restart_profile.restart_after_reset = 0;
        no_restart_profile.base_len            = 120;
        no_restart_sequence = mailbox_rx_start_sequence::type_id::create(
            "no_restart_sequence");
        no_restart_sequence.set_refill_profile(no_restart_profile);
        no_restart_sequence.start(rx_no_restart_sequencer);
        if (no_restart_sequence.response == null ||
            no_restart_sequence.response.status != GQ_OK ||
            no_restart_sequence.response.committed_count != 2)
            `uvm_fatal("RESET_RX_OFF", "non-restarting RX start failed")

        // The engine must retain its own recovery profile value.
        profile.initial_post_count  = 1;
        profile.restart_after_reset = 0;
        profile.base_len            = 900;
        rx_sequence.set_refill_profile(null);
        profile = null;
        no_restart_profile.initial_post_count  = 7;
        no_restart_profile.restart_after_reset = 1;
        no_restart_sequence.set_refill_profile(null);
        no_restart_profile = null;

        old_tx_ring = tx_engine.ring_base();
        old_rx_ring = rx_engine.ring_base();
        if (!env_cfg.trigger_reset_asserted())
            `uvm_fatal("RESET_EVENT", "first reset assertion was rejected")
        if (env_cfg.trigger_reset_asserted())
            `uvm_fatal("RESET_EVENT", "duplicate reset assertion was accepted")
        if (env_cfg.trigger_reset_deasserted())
            `uvm_fatal("RESET_EVENT",
                       "release was accepted while assertion was pending")
        wait_for_disable_count(3);

        if (adapter.disable_order.size() != 3 ||
            adapter.disable_order[0] != "rx_5" ||
            adapter.disable_order[1] != "rx_6" ||
            adapter.disable_order[2] != "tx_7")
            `uvm_fatal("RESET_ORDER", "queues were not disabled by sparse key order")
        if (tx_engine.is_ready() || rx_engine.is_ready() ||
            rx_no_restart_engine.is_ready() ||
            tx_engine.outstanding_count() != 0 ||
            rx_engine.outstanding_count() != 0 ||
            rx_no_restart_engine.outstanding_count() != 0 ||
            tx_engine.head_seq() != 0 || tx_engine.tail_seq() != 0 ||
            rx_engine.head_seq() != 0 || rx_engine.tail_seq() != 0 ||
            rx_no_restart_engine.head_seq() != 0 ||
            rx_no_restart_engine.tail_seq() != 0 ||
            tx_engine.ring_base() != 0 || rx_engine.ring_base() != 0 ||
            rx_no_restart_engine.ring_base() != 0 ||
            tx_engine.status_addr() != 0 || rx_engine.status_addr() != 0 ||
            rx_no_restart_engine.status_addr() != 0 ||
            mem.ring_free_calls != 3)
            `uvm_fatal("RESET_ASSERT", "assertion did not clear queue resources")
        if (tx_engine.reset_epoch() != 1 || rx_engine.reset_epoch() != 1 ||
            rx_no_restart_engine.reset_epoch() != 1)
            `uvm_fatal("RESET_EPOCH", "first assertion did not advance epochs")

        reset_sequence = mailbox_tx_sequence::type_id::create("reset_sequence");
        reset_sequence.add_desc(make_tx("reset_tx", 9));
        reset_sequence.start(tx_sequencer);
        if (reset_sequence.response == null ||
            reset_sequence.response.status != GQ_ABORTED_BY_RESET ||
            reset_sequence.response.committed_count != 0 ||
            reset_sequence.response.reset_epoch != 1)
            `uvm_fatal("RESET_ABORT", "reset-period driver request did not abort")

        // Force the poll worker to observe reset while it is deasserted from
        // readiness. It must wait for the next ready epoch, not terminate.
        #25ns;

        if (!env_cfg.trigger_reset_deasserted())
            `uvm_fatal("RESET_EVENT", "first reset release was rejected")
        wait_for_configure_count(6);
        if (!tx_engine.is_ready() || !rx_engine.is_ready() ||
            !rx_no_restart_engine.is_ready() ||
            mem.ring_alloc_calls != 6 ||
            tx_engine.ring_base() == 0 || rx_engine.ring_base() == 0 ||
            tx_engine.head_seq() != 0 || tx_engine.tail_seq() != 0 ||
            tx_engine.outstanding_count() != 0 ||
            rx_engine.head_seq() != 0 || rx_engine.tail_seq() != 3 ||
            rx_engine.outstanding_count() != 3 ||
            rx_no_restart_engine.head_seq() != 0 ||
            rx_no_restart_engine.tail_seq() != 0 ||
            rx_no_restart_engine.outstanding_count() != 0 ||
            adapter.publish_count["rx_5"] != 2 ||
            adapter.publish_count["rx_6"] != 1)
            `uvm_fatal("RESET_RELEASE", "release did not rebuild queues/repost RX")
        if (old_tx_ring == 0 || old_rx_ring == 0)
            `uvm_fatal("RESET_RING", "old ring evidence was invalid")

        recovered_sequence = mailbox_tx_sequence::type_id::create(
            "recovered_sequence");
        recovered_sequence.add_desc(make_tx("recovered_tx", 10));
        recovered_sequence.start(tx_sequencer);
        if (recovered_sequence.response == null ||
            recovered_sequence.response.status != GQ_OK ||
            recovered_sequence.response.reset_epoch != 1)
            `uvm_fatal("RESET_WORKER", "post-reset TX submit failed")
        dut.complete_slot(tx_engine, 0, 32, 64);
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #1ns;
            if (collector.retired_srcids.size() == 1)
                break;
        end
        if (collector.retired_srcids.size() != 1 ||
            collector.retired_srcids[0] != 16'h700a)
            `uvm_fatal("RESET_WORKER",
                       "poll completion worker did not resume after reset")

        // Fill the entire recovered TX capacity through the real driver, then
        // prove that the next sequence remains blocked until reset advances
        // the epoch and returns exactly one aborted response.
        fill_sequence = mailbox_tx_sequence::type_id::create("fill_sequence");
        for (int unsigned i = 0; i < 32; i++)
            fill_sequence.add_desc(make_tx($sformatf("fill_tx_%0d", i),
                                           100 + i));
        fill_sequence.start(tx_sequencer);
        if (fill_sequence.response == null ||
            fill_sequence.response.status != GQ_OK ||
            fill_sequence.response.committed_count != 32)
            `uvm_fatal("RESET_BLOCKED", "could not fill recovered TX ring")
        blocked_sequence = mailbox_tx_sequence::type_id::create(
            "blocked_sequence");
        blocked_sequence.add_desc(make_tx("blocked_tx", 200));
        blocked_sequence_returned = 0;
        fork : blocked_driver_submit
            begin
                blocked_sequence.start(tx_sequencer);
                blocked_sequence_returned = 1;
            end
        join_none
        #5ns;
        if (blocked_sequence_returned)
            `uvm_fatal("RESET_BLOCKED",
                       "full-capacity driver submit did not block")
        if (!env_cfg.trigger_reset_asserted())
            `uvm_fatal("RESET_EVENT", "second reset assertion was rejected")
        wait_for_disable_count(6);
        for (int unsigned poll = 0; poll < 40; poll++) begin
            #1ns;
            if (blocked_sequence_returned)
                break;
        end
        if (!blocked_sequence_returned || blocked_sequence.response == null ||
            blocked_sequence.response.status != GQ_ABORTED_BY_RESET ||
            blocked_sequence.response.committed_count != 0 ||
            blocked_sequence.response.reset_epoch != 2)
            `uvm_fatal("RESET_BLOCKED",
                       "blocked driver submit was not reset-aborted")
        if (tx_engine.reset_epoch() != 2 || rx_engine.reset_epoch() != 2 ||
            rx_no_restart_engine.reset_epoch() != 2)
            `uvm_fatal("RESET_EPOCH", "second assertion did not advance epochs")

        #25ns;
        if (!env_cfg.trigger_reset_deasserted())
            `uvm_fatal("RESET_EVENT", "second reset release was rejected")
        wait_for_configure_count(9);
        if (tx_engine.tail_seq() != 0 || tx_engine.outstanding_count() != 0 ||
            rx_engine.tail_seq() != 3 || rx_engine.outstanding_count() != 3 ||
            rx_no_restart_engine.tail_seq() != 0 ||
            rx_no_restart_engine.outstanding_count() != 0 ||
            adapter.publish_count["rx_5"] != 3 ||
            adapter.publish_count["rx_6"] != 1)
            `uvm_fatal("RESET_RX_OFF",
                       "restart=false RX reposted during second release")

        new_no_restart_profile =
            gq_deterministic_refill_profile::type_id::create(
                "new_no_restart_profile");
        new_no_restart_profile.initial_post_count  = 2;
        new_no_restart_profile.low_watermark       = 1;
        new_no_restart_profile.high_watermark      = 3;
        new_no_restart_profile.restart_after_reset = 0;
        new_no_restart_profile.base_len            = 220;
        new_no_restart_sequence = mailbox_rx_start_sequence::type_id::create(
            "new_no_restart_sequence");
        new_no_restart_sequence.set_refill_profile(new_no_restart_profile);
        new_no_restart_sequence.start(rx_no_restart_sequencer);
        if (new_no_restart_sequence.response == null ||
            new_no_restart_sequence.response.status != GQ_OK ||
            new_no_restart_sequence.response.committed_count != 2 ||
            new_no_restart_sequence.response.reset_epoch != 2 ||
            rx_no_restart_engine.tail_seq() != 2 ||
            adapter.publish_count["rx_6"] != 2)
            `uvm_fatal("RESET_RX_OFF",
                       "restart=false RX did not accept a new startup")

        // Two real DUT retirements drive RX refill into a publish that only
        // same-queue disable may cancel. Reset must reach disable without
        // waiting on the submit path, then release each owned buffer once.
        adapter.block_publish_until_disable = 1;
        adapter.blocked_publish_key = "rx_5";
        adapter.hold_cancelled_publish_return = 1;
        adapter.publish_cancelled.reset();
        adapter.cancel_observed.reset();
        adapter.allow_cancelled_publish_return.reset();
        adapter.publish_entered.reset();
        adapter.publish_returned = 0;
        publish_count_before_cancel = adapter.publish_count["rx_5"];
        dut.complete_slot(rx_engine, 0, 32, 16);
        dut.complete_slot(rx_engine, 1, 32, 16);
        refill_publish_seen = 0;
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #1ns;
            if (adapter.publish_entered.is_on()) begin
                refill_publish_seen = 1;
                break;
            end
        end
        if (!refill_publish_seen)
            `uvm_fatal("RESET_REFILL", "refill did not enter blocked publish")
        mem.enforce_disable_before_desc_free = 1;
        mem.queue_disable_observed            = 0;
        mem.pre_disable_desc_free              = 0;
        lifetime_ring_free_before = mem.ring_free_calls;
        lifetime_desc_free_before = mem.descriptor_free_calls;
        if (!env_cfg.trigger_reset_asserted())
            `uvm_fatal("RESET_EVENT", "third reset assertion was rejected")
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (rx_engine.reset_epoch() == 3)
                break;
        end
        if (rx_engine.reset_epoch() != 3)
            `uvm_fatal("RESET_REFILL", "refill reset epoch did not advance")
        global_publish_request = gq_request::type_id::create(
            "global_publish_request");
        global_publish_request.add_desc(make_tx("global_publish_tx", 500));
        global_publish_response = gq_response::type_id::create(
            "global_publish_response");
        tx_engine.submit_batch(global_publish_request,
                               global_publish_response);
        if (global_publish_response.status != GQ_ABORTED_BY_RESET ||
            global_publish_response.committed_count != 0 ||
            global_publish_response.reset_epoch != 3 ||
            rx_no_restart_engine.reset_epoch() != 3 ||
            tx_engine.reset_epoch() != 3)
            `uvm_fatal("RESET_GLOBAL_PUBLISH",
                       "later queues stayed ready while the first reset teardown was blocked")
        adapter.cancel_observed.wait_on();
        #1ns;
        if (adapter.publish_returned || adapter.disable_calls != 7 ||
            mem.ring_free_calls != lifetime_ring_free_before ||
            mem.descriptor_free_calls != lifetime_desc_free_before ||
            mem.pre_quiesce_desc_free || mem.pre_quiesce_ring_free)
            `uvm_fatal("RESET_PUBLISH_LIFETIME",
                       "reset released publish resources before publish returned")
        adapter.allow_cancelled_publish_return.trigger();
        wait (adapter.publish_returned);
        wait (adapter.disable_calls == 9);
        if (!mem.publish_quiesced || mem.pre_quiesce_desc_free ||
            mem.pre_quiesce_ring_free)
            `uvm_fatal("RESET_PUBLISH_LIFETIME",
                       "reset resource release did not follow publish quiescence")
        if (mem.pre_disable_desc_free)
            `uvm_fatal("RESET_OWNERSHIP",
                       "reset freed a descriptor buffer before disabling its queue")
        if (adapter.cancelled_publish_count != 1)
            `uvm_fatal("RESET_PUBLISH_CANCEL",
                       "disable did not quiesce exactly one blocked publish")
        if (adapter.post_disable_publish ||
            adapter.publish_count["rx_5"] != publish_count_before_cancel)
            `uvm_fatal("RESET_PUBLISH_CANCEL",
                       "a canceled publish became visible after disable")
        if (rx_engine.outstanding_count() != 0 ||
            rx_no_restart_engine.outstanding_count() != 0 ||
            tx_engine.outstanding_count() != 0)
            `uvm_fatal("RESET_REFILL", "third reset left outstanding state")

        adapter.block_publish_until_disable = 0;
        adapter.blocked_publish_key = "";
        adapter.hold_cancelled_publish_return = 0;
        mem.enforce_publish_quiescence = 0;
        if (!env_cfg.trigger_reset_deasserted())
            `uvm_fatal("RESET_EVENT", "third reset release was rejected")
        wait_for_configure_count(12);
        if (!tx_engine.is_ready() || !rx_engine.is_ready() ||
            !rx_no_restart_engine.is_ready() ||
            adapter.publish_count["rx_5"] !=
                publish_count_before_cancel + 1)
            `uvm_fatal("RESET_PUBLISH_CANCEL",
                       "reset recovery did not follow publish quiescence")

        // A user TX publish can lose its lifecycle while the adapter call is
        // in flight. Reset must cancel the adapter, wait for that exact call
        // to return before releasing either allocation, and report the stale
        // submit as reset-aborted rather than committed.
        publish_reset_engine.initialize();
        publish_reset_adapter.block_publish_until_disable = 1;
        publish_reset_adapter.blocked_publish_key = "tx_23";
        publish_reset_adapter.hold_cancelled_publish_return = 1;
        publish_reset_adapter.publish_cancelled.reset();
        publish_reset_adapter.cancel_observed.reset();
        publish_reset_adapter.allow_cancelled_publish_return.reset();
        publish_reset_adapter.publish_entered.reset();
        publish_reset_adapter.publish_returned = 0;
        publish_reset_count_before =
            publish_reset_adapter.publish_count["tx_23"];
        publish_reset_request = gq_request::type_id::create(
            "publish_reset_request");
        publish_reset_request.add_desc(make_tx("publish_reset_tx", 502));
        publish_reset_response = gq_response::type_id::create(
            "publish_reset_response");
        publish_reset_submit_returned = 0;
        publish_reset_assert_returned = 0;
        fork : blocked_user_tx_publish
            begin
                publish_reset_engine.submit_batch(publish_reset_request,
                                                  publish_reset_response);
                publish_reset_submit_returned = 1;
            end
        join_none
        publish_reset_adapter.publish_entered.wait_on();
        publish_reset_ring_free_before = publish_reset_mem.ring_free_calls;
        publish_reset_desc_free_before =
            publish_reset_mem.descriptor_free_calls;
        fork : reset_cancels_user_tx_publish
            begin
                publish_reset_engine.assert_reset();
                publish_reset_assert_returned = 1;
            end
        join_none
        publish_reset_adapter.cancel_observed.wait_on();
        #1ns;
        if (publish_reset_submit_returned || publish_reset_assert_returned ||
            publish_reset_adapter.publish_returned ||
            publish_reset_mem.ring_free_calls !=
                publish_reset_ring_free_before ||
            publish_reset_mem.descriptor_free_calls !=
                publish_reset_desc_free_before ||
            publish_reset_mem.pre_quiesce_desc_free ||
            publish_reset_mem.pre_quiesce_ring_free)
            `uvm_fatal("RESET_PUBLISH_LIFETIME",
                       "runtime reset released TX resources before publish returned")
        publish_reset_adapter.allow_cancelled_publish_return.trigger();
        for (int unsigned poll = 0; poll < 200; poll++) begin
            #1ns;
            if (publish_reset_submit_returned &&
                publish_reset_assert_returned)
                break;
        end
        if (!publish_reset_submit_returned ||
            publish_reset_response.status != GQ_ABORTED_BY_RESET ||
            publish_reset_response.committed_count != 0 ||
            publish_reset_response.reset_epoch != 1)
            `uvm_fatal("RESET_PUBLISH_RESPONSE",
                       "stale TX publish did not return reset-aborted response")
        if (!publish_reset_assert_returned ||
            !publish_reset_adapter.publish_returned ||
            publish_reset_engine.reset_epoch() != 1 ||
            publish_reset_adapter.publish_count["tx_23"] !=
                publish_reset_count_before ||
            publish_reset_engine.ring_base() != 0 ||
            publish_reset_engine.outstanding_count() != 0 ||
            publish_reset_adapter.cancelled_publish_count != 1 ||
            publish_reset_mem.pre_quiesce_desc_free ||
            publish_reset_mem.pre_quiesce_ring_free ||
            publish_reset_mem.ring_free_calls !=
                publish_reset_ring_free_before + 1 ||
            publish_reset_mem.descriptor_free_calls !=
                publish_reset_desc_free_before + 1)
            `uvm_fatal("RESET_PUBLISH_LIFETIME",
                       "runtime reset did not quiesce and release TX exactly once")
        publish_reset_adapter.block_publish_until_disable = 0;
        publish_reset_adapter.blocked_publish_key = "";
        publish_reset_adapter.hold_cancelled_publish_return = 0;
        publish_reset_mem.enforce_publish_quiescence = 0;
        publish_reset_mem.leak_check(`__FILE__, `__LINE__);

        // Explicit final cleanup uses the same disable-first cancellation
        // path as runtime reset and must abort the active user request.
        adapter.block_publish_until_disable = 1;
        adapter.blocked_publish_key = "tx_7";
        adapter.hold_cancelled_publish_return = 1;
        adapter.publish_cancelled.reset();
        adapter.cancel_observed.reset();
        adapter.allow_cancelled_publish_return.reset();
        adapter.publish_entered.reset();
        adapter.publish_returned = 0;
        cancelled_count_before_cleanup = adapter.cancelled_publish_count;
        publish_count_before_cancel = adapter.publish_count["tx_7"];
        cleanup_publish_request = gq_request::type_id::create(
            "cleanup_publish_request");
        cleanup_publish_request.add_desc(make_tx("cleanup_publish_tx", 501));
        cleanup_publish_response = gq_response::type_id::create(
            "cleanup_publish_response");
        cleanup_publish_returned = 0;
        env_cleanup_returned = 0;
        fork : cleanup_blocked_publish
            begin
                tx_engine.submit_batch(cleanup_publish_request,
                                       cleanup_publish_response);
                cleanup_publish_returned = 1;
            end
        join_none
        adapter.publish_entered.wait_on();
        fork : cleanup_cancels_publish
            begin
                env.cleanup();
                env_cleanup_returned = 1;
            end
        join_none
        adapter.cancel_observed.wait_on();
        lifetime_ring_free_before = mem.ring_free_calls;
        lifetime_desc_free_before = mem.descriptor_free_calls;
        #1ns;
        if (cleanup_publish_returned || env_cleanup_returned ||
            adapter.publish_returned ||
            mem.ring_free_calls != lifetime_ring_free_before ||
            mem.descriptor_free_calls != lifetime_desc_free_before ||
            mem.pre_quiesce_desc_free || mem.pre_quiesce_ring_free)
            `uvm_fatal("RESET_PUBLISH_LIFETIME",
                       "cleanup released publish resources before publish returned")
        adapter.allow_cancelled_publish_return.trigger();
        for (int unsigned poll = 0; poll < 200; poll++) begin
            #1ns;
            if (cleanup_publish_returned && env_cleanup_returned)
                break;
        end
        if (!cleanup_publish_returned ||
            cleanup_publish_response.status != GQ_ABORTED_BY_RESET)
            `uvm_fatal("RESET_PUBLISH_CANCEL",
                       "blocked publish request was not cleanup-aborted")
        if (!env_cleanup_returned || adapter.cancelled_publish_count !=
            cancelled_count_before_cleanup + 1)
            `uvm_fatal("RESET_PUBLISH_CANCEL",
                       "cleanup did not quiesce exactly one blocked publish")
        if (adapter.post_disable_publish ||
            adapter.publish_count["tx_7"] != publish_count_before_cancel)
            `uvm_fatal("RESET_PUBLISH_CANCEL",
                       "cleanup-canceled publish became visible after disable")
        if (tx_engine.ring_base() != 0 || tx_engine.outstanding_count() != 0)
            `uvm_fatal("RESET_PUBLISH_CANCEL",
                       "cleanup freed or retained the wrong publish resources")
        adapter.block_publish_until_disable = 0;
        adapter.blocked_publish_key = "";
        adapter.hold_cancelled_publish_return = 0;
        mem.enforce_publish_quiescence = 0;
        mem.leak_check(`__FILE__, `__LINE__);

        irq_engine.initialize();
        irq_desc = make_tx("irq_reset_pending_desc", 12);
        irq_request = gq_request::type_id::create("irq_reset_pending_request");
        irq_request.add_desc(irq_desc);
        irq_response = gq_response::type_id::create(
            "irq_reset_pending_response");
        irq_engine.submit_batch(irq_request, irq_response);
        if (irq_response.status != GQ_OK || irq_response.reset_epoch != 0)
            `uvm_fatal("RESET_IRQ", "pre-reset IRQ submit failed")
        irq_worker_returned = 0;
        fork : blocked_irq_worker
            begin
                irq_engine.run_completion_worker();
                irq_worker_returned = 1;
            end
        join_none
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (irq_adapter.wait_irq_calls == 1)
                break;
        end
        if (irq_adapter.wait_irq_calls != 1)
            `uvm_fatal("RESET_IRQ", "IRQ worker did not enter wait_irq")
        irq_reset_start = $time;
        irq_engine.assert_reset();
        if (($time - irq_reset_start) >= (irq_cfg.completion_timeout / 2))
            `uvm_fatal("RESET_IRQ_CANCEL",
                       "reset waited for the old IRQ timeout instead of cancelling it")
        if (irq_worker_returned || irq_engine.is_ready() ||
            irq_engine.reset_epoch() != 1)
            `uvm_fatal("RESET_IRQ", "IRQ worker did not wait across reset")
        if (irq_adapter.ack_irq_calls != 0 ||
            irq_completion.query_calls != 0)
            `uvm_fatal("RESET_IRQ",
                       "reset IRQ cancellation was queried or acknowledged")

        // Release before the old epoch's bounded wait can time out. A new
        // completion/IRQ must be consumed only by a new-epoch waiter; an old
        // waiter that survives reset will otherwise ack without draining.
        irq_engine.release_reset();
        irq_desc = make_tx("irq_recovered_desc", 13);
        irq_request = gq_request::type_id::create("irq_recovered_request");
        irq_request.add_desc(irq_desc);
        irq_response = gq_response::type_id::create("irq_recovered_response");
        irq_engine.submit_batch(irq_request, irq_response);
        if (irq_response.status != GQ_OK || irq_response.reset_epoch != 1)
            `uvm_fatal("RESET_IRQ", "post-reset IRQ submit failed")
        irq_dut.complete_slot(irq_engine, 0, 32, 64);
        irq_adapter.trigger_irq(GQ_TX, 19);
        for (int unsigned poll = 0; poll < 40; poll++) begin
            #1ns;
            if (irq_collector.retired_srcids.size() == 1)
                break;
        end
        if (irq_collector.retired_srcids.size() != 1) begin
            if (irq_adapter.ack_irq_calls == 1 &&
                irq_engine.outstanding_count() == 1)
                `uvm_fatal("RESET_IRQ_STALE",
                           "old epoch waiter acknowledged the new epoch IRQ without draining")
            `uvm_fatal("RESET_IRQ", "IRQ worker did not drain after reset")
        end
        if (irq_collector.retired_srcids[0] != 16'h700d ||
            irq_adapter.ack_irq_calls != 1)
            `uvm_fatal("RESET_IRQ", "post-reset IRQ was not acknowledged exactly once")
        // Once ACK ownership wins the completion boundary, reset must publish
        // its new epoch immediately without disabling/freeing resources until
        // the external ACK has returned.
        irq_adapter.ack_delay = 50ns;
        irq_adapter.ack_entered.reset();
        irq_desc = make_tx("irq_delayed_ack_desc", 14);
        irq_request = gq_request::type_id::create("irq_delayed_ack_request");
        irq_request.add_desc(irq_desc);
        irq_response = gq_response::type_id::create(
            "irq_delayed_ack_response");
        irq_engine.submit_batch(irq_request, irq_response);
        if (irq_response.status != GQ_OK || irq_response.reset_epoch != 1)
            `uvm_fatal("RESET_IRQ_ACK_GATE", "delayed ACK submit failed")
        for (int unsigned poll = 0; poll < 40; poll++) begin
            #1ns;
            if (irq_adapter.wait_irq_calls >= 3)
                break;
        end
        if (irq_adapter.wait_irq_calls < 3)
            `uvm_fatal("RESET_IRQ_ACK_GATE",
                       "IRQ worker did not arm for delayed ACK work")
        irq_dut.complete_slot(irq_engine, 1, 32, 64);
        disable_calls_before_delayed_ack = irq_adapter.disable_calls;
        irq_adapter.trigger_irq(GQ_TX, 19);
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (irq_adapter.ack_entered.is_on())
                break;
        end
        if (!irq_adapter.ack_entered.is_on())
            `uvm_fatal("RESET_IRQ_ACK_GATE", "IRQ did not enter delayed ACK")

        delayed_ack_reset_returned = 0;
        fork : delayed_ack_reset
            begin
                irq_engine.assert_reset();
                delayed_ack_reset_returned = 1;
            end
        join_none
        #1ns;
        if (irq_engine.reset_epoch() != 2 || irq_engine.is_ready())
            `uvm_fatal("RESET_IRQ_ACK_GATE",
                       "delayed ACK blocked reset epoch/ready publication")
        if (delayed_ack_reset_returned ||
            irq_adapter.disable_calls != disable_calls_before_delayed_ack ||
            irq_engine.ring_base() == 0)
            `uvm_fatal("RESET_IRQ_ACK_GATE",
                       "reset teardown crossed an in-flight ACK")
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #1ns;
            if (delayed_ack_reset_returned)
                break;
        end
        if (!delayed_ack_reset_returned || irq_adapter.ack_irq_calls != 2 ||
            irq_adapter.disable_calls !=
                disable_calls_before_delayed_ack + 1 ||
            irq_completion.query_calls != 1 ||
            irq_engine.outstanding_count() != 0 ||
            irq_engine.ring_base() != 0 ||
            irq_collector.retired_srcids.size() != 1)
            `uvm_fatal("RESET_IRQ_ACK_GATE",
                       "reset did not quiesce delayed ACK before teardown")
        irq_adapter.ack_delay = 0;
        irq_engine.cleanup();
        #(irq_cfg.completion_timeout + 5ns);
        if (!irq_worker_returned)
            `uvm_fatal("RESET_IRQ", "blocked IRQ worker survived cleanup")
        if (irq_adapter.ack_irq_calls != 2)
            `uvm_fatal("RESET_IRQ", "cleanup IRQ timeout was acknowledged")
        irq_mem.leak_check(`__FILE__, `__LINE__);

        stale_engine.initialize();
        stale_desc = make_tx("stale_desc", 11);
        stale_request = gq_request::type_id::create("stale_request");
        stale_request.add_desc(stale_desc);
        stale_response = gq_response::type_id::create("stale_response");
        stale_engine.submit_batch(stale_request, stale_response);
        if (stale_response.status != GQ_OK)
            `uvm_fatal("RESET_STALE", "stale-query setup submit failed")
        stale_dut.complete_slot(stale_engine, 0, 32, 64);
        stale_query_seen     = 0;
        stale_drain_returned = 0;
        stale_reset_returned = 0;
        fork : stale_query_race
            begin
                stale_engine.drain_completed();
                stale_drain_returned = 1;
            end
        join_none
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (stale_engine.completion_query_returned_event.is_on()) begin
                stale_query_seen = 1;
                break;
            end
        end
        if (!stale_query_seen)
            `uvm_fatal("RESET_STALE",
                       "completion query did not reach protected race seam")
        fork : stale_assert
            begin
                stale_engine.assert_reset();
                stale_reset_returned = 1;
            end
        join_none
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (stale_engine.reset_epoch() == 1)
                break;
        end
        if (stale_engine.reset_epoch() != 1)
            `uvm_fatal("RESET_STALE", "reset did not advance during query")
        stale_engine.allow_completion_return.trigger();
        for (int unsigned poll = 0; poll < 40; poll++) begin
            #1ns;
            if (stale_drain_returned && stale_reset_returned)
                break;
        end
        if (!stale_drain_returned || !stale_reset_returned)
            `uvm_fatal("RESET_STALE", "query/reset race did not quiesce")
        if (stale_collector.retired_srcids.size() != 0 ||
            stale_engine.outstanding_count() != 0)
            `uvm_fatal("RESET_STALE",
                       "stale completion reached analysis or retired state")

        stale_engine.release_reset();
        stale_desc = make_tx("commit_window_desc", 12);
        stale_request = gq_request::type_id::create("commit_window_request");
        stale_request.add_desc(stale_desc);
        stale_response = gq_response::type_id::create("commit_window_response");
        stale_engine.submit_batch(stale_request, stale_response);
        if (stale_response.status != GQ_OK ||
            stale_response.reset_epoch != 1)
            `uvm_fatal("RESET_COMMIT", "commit-window setup submit failed")
        stale_dut.complete_slot(stale_engine, 0, 32, 64);
        stale_engine.pause_after_validation = 1;
        stale_engine.completion_query_returned_event.reset();
        stale_engine.allow_completion_return.trigger();
        commit_drain_returned = 0;
        commit_reset_returned = 0;
        fork : completion_commit_window
            begin
                stale_engine.drain_completed();
                commit_drain_returned = 1;
            end
        join_none
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (stale_engine.completion_validated_event.is_on())
                break;
        end
        if (!stale_engine.completion_validated_event.is_on())
            `uvm_fatal("RESET_COMMIT",
                       "completion did not pause after initial validation")
        fork : commit_window_assert
            begin
                stale_engine.assert_reset();
                commit_reset_returned = 1;
            end
        join_none
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (stale_engine.reset_epoch() == 2)
                break;
        end
        if (stale_engine.reset_epoch() != 2)
            `uvm_fatal("RESET_COMMIT",
                       "assertion did not enter validated completion window")
        stale_engine.allow_completion_commit.trigger();
        for (int unsigned poll = 0; poll < 40; poll++) begin
            #1ns;
            if (commit_drain_returned && commit_reset_returned)
                break;
        end
        if (!commit_drain_returned || !commit_reset_returned ||
            stale_collector.retired_srcids.size() != 0 ||
            stale_engine.outstanding_count() != 0)
            `uvm_fatal("RESET_COMMIT",
                       "validated stale completion crossed reset boundary")

        stale_engine.release_reset();
        cleanup_fill_request = gq_request::type_id::create(
            "cleanup_fill_request");
        for (int unsigned i = 0; i < 32; i++)
            cleanup_fill_request.add_desc(
                make_tx($sformatf("cleanup_fill_%0d", i), 300 + i));
        cleanup_fill_response = gq_response::type_id::create(
            "cleanup_fill_response");
        stale_engine.submit_batch(cleanup_fill_request,
                                  cleanup_fill_response);
        if (cleanup_fill_response.status != GQ_OK ||
            cleanup_fill_response.committed_count != 32)
            `uvm_fatal("RESET_CLEANUP", "cleanup ring fill failed")
        cleanup_blocked_request = gq_request::type_id::create(
            "cleanup_blocked_request");
        cleanup_blocked_request.add_desc(make_tx("cleanup_blocked", 400));
        cleanup_blocked_response = gq_response::type_id::create(
            "cleanup_blocked_response");
        cleanup_blocked_returned = 0;
        cleanup_call_returned    = 0;
        fork : cleanup_capacity_wait
            begin
                stale_engine.submit_batch(cleanup_blocked_request,
                                          cleanup_blocked_response);
                cleanup_blocked_returned = 1;
            end
        join_none
        #2ns;
        if (cleanup_blocked_returned)
            `uvm_fatal("RESET_CLEANUP",
                       "cleanup capacity request did not block")
        fork : cleanup_call
            begin
                stale_engine.cleanup();
                cleanup_call_returned = 1;
            end
        join_none
        for (int unsigned poll = 0; poll < 40; poll++) begin
            #1ns;
            if (cleanup_blocked_returned && cleanup_call_returned)
                break;
        end
        if (!cleanup_blocked_returned || !cleanup_call_returned ||
            cleanup_blocked_response.status != GQ_ABORTED_BY_RESET ||
            cleanup_blocked_response.committed_count != 0 ||
            cleanup_blocked_response.reset_epoch != 3 ||
            stale_engine.is_ready() || stale_engine.ring_base() != 0)
            `uvm_fatal("RESET_CLEANUP",
                       "cleanup did not abort blocked capacity request")
        stale_mem.leak_check(`__FILE__, `__LINE__);

        // External disable may be timed, but shutdown publication must let a
        // real completion drain observe not-ready without waiting for it.
        stale_engine.initialize();
        stale_adapter.disable_delay = 50ns;
        stale_adapter.disable_entered.reset();
        disable_cleanup_returned = 0;
        disable_drain_returned = 0;
        fork : delayed_disable_cleanup
            begin
                stale_engine.cleanup();
                disable_cleanup_returned = 1;
            end
        join_none
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (stale_adapter.disable_entered.is_on())
                break;
        end
        if (!stale_adapter.disable_entered.is_on())
            `uvm_fatal("RESET_DISABLE_LOCK",
                       "cleanup did not enter delayed disable")
        fork : drain_during_disable
            begin
                stale_engine.drain_completed();
                disable_drain_returned = 1;
            end
        join_none
        #1ns;
        if (!disable_drain_returned)
            `uvm_fatal("RESET_DISABLE_LOCK",
                       "delayed disable retained completion serialization")
        if (disable_cleanup_returned)
            `uvm_fatal("RESET_DISABLE_LOCK",
                       "cleanup returned before delayed disable completed")
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #1ns;
            if (disable_cleanup_returned)
                break;
        end
        if (!disable_cleanup_returned || stale_engine.ring_base() != 0)
            `uvm_fatal("RESET_DISABLE_LOCK",
                       "delayed disable cleanup did not complete")
        stale_adapter.disable_delay = 0;
        stale_mem.leak_check(`__FILE__, `__LINE__);

        // Reset release must not retain either serialization lock across a
        // timed configure. Concurrent cleanup owns shutdown immediately, then
        // joins release and tears down the ring that configure actually made.
        stale_engine.initialize();
        stale_engine.assert_reset();
        configure_calls_before_race = stale_adapter.configure_calls;
        disable_calls_before_configure_race = stale_adapter.disable_calls;
        stale_adapter.configure_delay = 50ns;
        stale_adapter.configure_entered.reset();
        configure_release_returned = 0;
        configure_cleanup_returned = 0;
        configure_probe_returned = 0;
        fork : delayed_configure_release
            begin
                stale_engine.release_reset();
                configure_release_returned = 1;
            end
        join_none
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (stale_adapter.configure_entered.is_on())
                break;
        end
        if (!stale_adapter.configure_entered.is_on())
            `uvm_fatal("RESET_CONFIG_LOCK",
                       "reset release did not enter delayed configure")
        fork : configure_serialization_probe
            begin
                stale_engine.probe_serialization_locks_for_test();
                configure_probe_returned = 1;
            end
        join_none
        fork : cleanup_during_configure
            begin
                stale_engine.cleanup();
                configure_cleanup_returned = 1;
            end
        join_none
        #1ns;
        if (!configure_probe_returned)
            `uvm_fatal("RESET_CONFIG_LOCK",
                       "delayed configure retained engine serialization locks")
        if (configure_release_returned || configure_cleanup_returned)
            `uvm_fatal("RESET_CONFIG_JOIN",
                       "release or cleanup returned before configure completed")
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #1ns;
            if (configure_release_returned && configure_cleanup_returned)
                break;
        end
        if (!configure_release_returned || !configure_cleanup_returned ||
            stale_engine.is_ready() || stale_engine.ring_base() != 0 ||
            stale_adapter.configure_calls != configure_calls_before_race + 1 ||
            stale_adapter.disable_calls !=
                disable_calls_before_configure_race + 1)
            `uvm_fatal("RESET_CONFIG_JOIN",
                       "cleanup did not adopt and tear down the configured ring")
        stale_adapter.configure_delay = 0;
        stale_mem.leak_check(`__FILE__, `__LINE__);

        // Every cleanup caller joins the same teardown. A later call must not
        // return merely because the owner already published shutdown.
        stale_engine.initialize();
        stale_adapter.disable_delay = 50ns;
        stale_adapter.disable_entered.reset();
        disable_calls_before_cleanup_join = stale_adapter.disable_calls;
        configure_calls_before_cleanup_join = stale_adapter.configure_calls;
        cleanup_owner_returned = 0;
        cleanup_joiner_returned = 0;
        cleanup_initialize_returned = 0;
        fork : cleanup_join_owner
            begin
                stale_engine.cleanup();
                cleanup_owner_returned = 1;
            end
        join_none
        for (int unsigned poll = 0; poll < 20; poll++) begin
            #1ns;
            if (stale_adapter.disable_entered.is_on())
                break;
        end
        if (!stale_adapter.disable_entered.is_on())
            `uvm_fatal("RESET_CLEANUP_JOIN",
                       "cleanup owner did not enter delayed disable")
        fork : cleanup_join_waiter
            begin
                stale_engine.cleanup();
                cleanup_joiner_returned = 1;
            end
        join_none
        fork : initialize_during_cleanup
            begin
                stale_engine.initialize();
                cleanup_initialize_returned = 1;
            end
        join_none
        #1ns;
        if (cleanup_owner_returned || cleanup_joiner_returned ||
            cleanup_initialize_returned)
            `uvm_fatal("RESET_CLEANUP_JOIN",
                       "cleanup joiner returned before shared teardown completed")
        for (int unsigned poll = 0; poll < 100; poll++) begin
            #1ns;
            if (cleanup_owner_returned && cleanup_joiner_returned &&
                cleanup_initialize_returned)
                break;
        end
        if (!cleanup_owner_returned || !cleanup_joiner_returned ||
            !cleanup_initialize_returned || stale_engine.is_ready() ||
            stale_engine.ring_base() != 0 ||
            stale_adapter.disable_calls !=
                disable_calls_before_cleanup_join + 1 ||
            stale_adapter.configure_calls !=
                configure_calls_before_cleanup_join)
            `uvm_fatal("RESET_CLEANUP_JOIN",
                       "cleanup joiners did not preserve one terminal teardown")
        stale_adapter.disable_delay = 0;
        stale_mem.leak_check(`__FILE__, `__LINE__);

        // Cleanup must cancel a reset-release RX repost without returning
        // before release_reset has committed its final lifecycle state.
        repost_engine.initialize();
        repost_profile = gq_deterministic_refill_profile::type_id::create(
            "repost_profile");
        repost_profile.initial_post_count  = 1;
        repost_profile.low_watermark       = 0;
        repost_profile.high_watermark      = 1;
        repost_profile.restart_after_reset = 1;
        repost_profile.base_len            = 64;
        repost_start_request = gq_request::type_id::create(
            "repost_start_request");
        repost_start_request.kind = GQ_START_RX;
        repost_start_request.set_refill_profile(repost_profile);
        repost_start_response = gq_response::type_id::create(
            "repost_start_response");
        repost_engine.start_rx(repost_start_request, repost_start_response);
        if (repost_start_response.status != GQ_OK ||
            repost_adapter.publish_count["rx_22"] != 1)
            `uvm_fatal("RESET_REPOST_CLEANUP",
                       "standalone RX startup did not publish")
        repost_engine.assert_reset();
        repost_adapter.block_publish_until_disable = 1;
        repost_adapter.blocked_publish_key = "rx_22";
        repost_adapter.publish_cancelled.reset();
        repost_adapter.publish_entered.reset();
        repost_publish_count_before = repost_adapter.publish_count["rx_22"];
        repost_disable_count_before = repost_adapter.disable_calls;
        repost_release_returned = 0;
        repost_cleanup_returned = 0;
        fork : blocked_reset_repost
            begin
                repost_engine.release_reset();
                repost_release_returned = 1;
            end
        join_none
        repost_adapter.publish_entered.wait_on();
        fork : cleanup_cancels_reset_repost
            begin
                repost_engine.cleanup();
                repost_cleanup_returned = 1;
            end
        join_none
        wait (repost_release_returned && repost_cleanup_returned);
        repost_engine.configuration_done_for_test(repost_configuration_done);
        if (!repost_configuration_done)
            `uvm_fatal("RESET_REPOST_CLEANUP",
                       "cleanup returned before reset release completed")
        if (repost_adapter.cancelled_publish_count != 1 ||
            repost_adapter.disable_calls != repost_disable_count_before + 1)
            `uvm_fatal("RESET_REPOST_CLEANUP",
                       "cleanup did not disable exactly once for blocked repost")
        if (repost_adapter.post_disable_publish ||
            repost_adapter.publish_count["rx_22"] !=
                repost_publish_count_before)
            `uvm_fatal("RESET_REPOST_CLEANUP",
                       "cleanup-canceled reset repost became visible")
        if (repost_engine.ring_base() != 0 ||
            repost_engine.outstanding_count() != 0)
            `uvm_fatal("RESET_REPOST_CLEANUP",
                       "cleanup retained reset repost resources")
        repost_adapter.block_publish_until_disable = 0;
        repost_adapter.blocked_publish_key = "";
        repost_mem.leak_check(`__FILE__, `__LINE__);

        disable reset_test_watchdog;
        phase.drop_objection(this);
    endtask
endclass

`endif
