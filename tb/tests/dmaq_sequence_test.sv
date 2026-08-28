`ifndef DMAQ_SEQUENCE_TEST_SV
`define DMAQ_SEQUENCE_TEST_SV

class dmaq_wrong_adapter extends gq_hw_adapter;
    `uvm_object_utils(dmaq_wrong_adapter)

    function new(string name = "dmaq_wrong_adapter");
        super.new(name);
    endfunction

    virtual task configure_queue(gq_role_e role, int unsigned queue_id,
                                 gq_addr_t base, int unsigned depth,
                                 int unsigned desc_size);
    endtask
    virtual task disable_queue(gq_role_e role, int unsigned queue_id);
    endtask
    virtual task publish(gq_role_e role, int unsigned queue_id,
                         gq_raw_ptr_t raw_tail);
    endtask
    virtual task wait_irq(gq_role_e role, int unsigned queue_id);
    endtask
    virtual task ack_irq(gq_role_e role, int unsigned queue_id);
    endtask
endclass

class dmaq_reg_reject_catcher extends uvm_report_catcher;
    `uvm_object_utils(dmaq_reg_reject_catcher)

    int unsigned caught_errors;

    function new(string name = "dmaq_reg_reject_catcher");
        super.new(name);
        caught_errors = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR &&
            (get_id() == "DMAQ_REG_ROLE" || get_id() == "DMAQ_REG_SIZE" ||
             get_id() == "DMAQ_REG_PTR")) begin
            caught_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

class dmaq_sequence_test extends uvm_test;
    `uvm_component_utils(dmaq_sequence_test)

    host_mem_manager mem;

    function new(string name = "dmaq_sequence_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function dmaq_tx_desc make_desc(string name);
        dmaq_tx_desc desc;

        desc = dmaq_tx_desc::type_id::create(name);
        desc.operation = DMAQ_AF_TO_HOST;
        desc.source.role = DMAQ_ENDPOINT_AF;
        desc.source.address = 64'h0000_0000_1000_0000;
        desc.source.host_id = 16'h0102;
        desc.source.bdf_raw = 16'h0103;
        desc.destination.role = DMAQ_ENDPOINT_HOST;
        desc.destination.address = 64'h0000_0000_2000_0000;
        desc.destination.host_id = 16'h0405;
        desc.destination.bdf_raw = 16'h0406;
        desc.transfer_length = 64;
        if (!desc.prepare())
            `uvm_fatal("DMAQ_PREP", {name, " preparation failed"})
        desc.mark_available(1'b0);
        return desc;
    endfunction

    function void write_desc(gq_addr_t address, dmaq_tx_desc desc,
                             bit used);
        byte packed_data[];

        desc.pack(packed_data);
        if (used)
            packed_data[0] = byte'(DMAQ_DESC_AVAIL | DMAQ_DESC_USED);
        mem.write_mem(address, packed_data, `__FILE__, `__LINE__);
    endfunction

    function void expect_profile_reject(dmaq_env_cfg candidate,
                                        dmaq_mock_adapter candidate_adapter,
                                        dmaq_hw_cfg_t requested_hw_cfg,
                                        string label);
        dmaq_hw_cfg_t before_hw_cfg;
        string reason;

        before_hw_cfg = candidate_adapter.hw_cfg;
        if (candidate.add_dmaq(0, requested_hw_cfg, reason) || reason == "" ||
            candidate.queues.num() != 0 ||
            candidate_adapter.hw_cfg != before_hw_cfg)
            `uvm_fatal("DMAQ_PROFILE_REJECT", {label, " was not atomic"})
    endfunction

    task check_pointer_and_completion();
        dmaq_ptr_codec codec;
        dmaq_completion completion;
        dmaq_tx_desc first;
        dmaq_tx_desc second;
        dmaq_tx_desc third;
        dmaq_tx_desc pending[$];
        bit valid;
        int unsigned completed_count;
        byte corrupt[];
        gq_addr_t ring_base;

        codec = dmaq_ptr_codec::type_id::create("codec");
        if (codec.encode_publish(31, 32, 32) != 32'h0000_8000 ||
            codec.encode_publish(32, 33, 32) != 32'h0000_8001 ||
            codec.encode_publish(63, 64, 32) != 32'h0000_0000 ||
            codec.encode_publish(5, 6, 64)   != 32'h0000_0006 ||
            codec.encode_publish(63, 64, 64) != 32'h0000_8000)
            `uvm_fatal("DMAQ_PTR", "index/phase encoding diverged")

        ring_base = mem.alloc(3 * DMAQ_DESC_BYTES, 64,
                              `__FILE__, `__LINE__);
        if (ring_base == '1)
            `uvm_fatal("DMAQ_COMPLETION_SETUP", "ring allocation failed")
        first = make_desc("first");
        second = make_desc("second");
        third = make_desc("third");
        pending.push_back(first);
        pending.push_back(second);
        pending.push_back(third);
        write_desc(ring_base, first, 1);
        write_desc(ring_base + DMAQ_DESC_BYTES, second, 1);
        write_desc(ring_base + 2 * DMAQ_DESC_BYTES, third, 0);
        completion = dmaq_completion::type_id::create("completion");
        completion.query_completed(mem, null, ring_base, '0, 32,
                                   DMAQ_DESC_BYTES, 0, pending, valid,
                                   completed_count);
        if (!valid || completed_count != 2)
            `uvm_fatal("DMAQ_COMPLETION", "USED descriptors were not retired contiguously")

        mem.read_mem(ring_base, DMAQ_DESC_BYTES, corrupt,
                     `__FILE__, `__LINE__);
        corrupt[2] = corrupt[2] ^ 8'h01;
        mem.write_mem(ring_base, corrupt, `__FILE__, `__LINE__);
        completion.query_completed(mem, null, ring_base, '0, 32,
                                   DMAQ_DESC_BYTES, 0, pending, valid,
                                   completed_count);
        if (valid || completed_count != 0)
            `uvm_fatal("DMAQ_COMPLETION_STABLE",
                       "stable-field corruption retired a descriptor")
        mem.free(ring_base, `__FILE__, `__LINE__);
        mem.leak_check(`__FILE__, `__LINE__);
    endtask

    function void check_profile(dmaq_env_cfg cfg, int unsigned queue_id,
                                int unsigned expected_depth,
                                gq_logical_seq_t expected_initial,
                                time expected_poll, time expected_timeout);
        gq_queue_cfg queue_cfg;
        string key;

        key = gq_queue_key(GQ_TX, queue_id);
        if (!cfg.queues.exists(key) || cfg.queues[key] == null)
            `uvm_fatal("DMAQ_PROFILE_QUEUE", "DMAQ queue was not installed")
        queue_cfg = cfg.queues[key];
        if (queue_cfg.role != GQ_TX || queue_cfg.depth != expected_depth ||
            queue_cfg.initial_logical_seq != expected_initial ||
            queue_cfg.desc_size != DMAQ_DESC_BYTES ||
            queue_cfg.alignment != 64 || queue_cfg.status_area_size != 0 ||
            queue_cfg.wait_mode != GQ_POLL ||
            queue_cfg.poll_policy != GQ_POLL_FIXED ||
            queue_cfg.poll_min_interval != expected_poll ||
            queue_cfg.poll_max_interval != expected_poll ||
            queue_cfg.poll_backoff_factor != 1 ||
            queue_cfg.irq_watchdog_interval != 0 ||
            queue_cfg.completion_timeout != expected_timeout)
            `uvm_fatal("DMAQ_PROFILE", "DMAQ profile values diverged")
    endfunction

    task check_adapter();
        dmaq_mock_adapter adapter;
        dmaq_hw_cfg_t hw_cfg;
        dmaq_reg_reject_catcher reject_catcher;
        int unsigned configure_before;
        bit wait_returned;

        adapter = dmaq_mock_adapter::type_id::create("semantic_adapter");
        hw_cfg.queue_hid = 32'h89abcdef;
        hw_cfg.queue_bdf = 16'h1234;
        hw_cfg.msix_index = 16'h0055;
        hw_cfg.msix_valid = 1;
        adapter.hw_cfg = hw_cfg;
        adapter.configure_queue(GQ_TX, 7, 64'h0000_0001_2000_0000, 64,
                                DMAQ_DESC_BYTES);
        adapter.publish(GQ_TX, 7, 32'h0000_0006);
        adapter.disable_queue(GQ_TX, 7);
        if (adapter.trace.size() != 5 ||
            adapter.trace[0] != "RESET(queue=7)" ||
            adapter.trace[1] != "CONFIGURE(queue=7,base=0x0000000120000000,depth=64,size=32,hid=0x89abcdef,bdf=0x1234,msix=0x0055,valid=1)" ||
            adapter.trace[2] != "ENABLE(queue=7)" ||
            adapter.trace[3] != "PUBLISH(queue=7,tail=0x0006)" ||
            adapter.trace[4] != "DISABLE(queue=7)")
            `uvm_fatal("DMAQ_TRACE", "semantic callback trace diverged")
        configure_before = adapter.configure_count[7];
        reject_catcher = dmaq_reg_reject_catcher::type_id::create(
            "reject_catcher");
        uvm_report_cb::add(null, reject_catcher);
        adapter.configure_queue(GQ_RX, 7, '0, 64, DMAQ_DESC_BYTES);
        adapter.configure_queue(GQ_TX, 7, '0, 64, 16);
        adapter.configure_queue(GQ_TX, 7, '0, 64, 64);
        adapter.publish(GQ_TX, 7, 32'h0001_0006);
        uvm_report_cb::delete(null, reject_catcher);
        if (adapter.configure_count[7] != configure_before ||
            adapter.publish_count[7] != 1 || reject_catcher.caught_errors != 4)
            `uvm_fatal("DMAQ_ADAPTER_VALIDATE",
                       "invalid adapter request reached a semantic callback")

        adapter.reset_dmaq(7);
        wait_returned = 0;
        fork
            begin
                adapter.wait_irq(GQ_TX, 7);
                wait_returned = 1;
            end
        join_none
        #1ns;
        if (wait_returned)
            `uvm_fatal("DMAQ_IRQ_CANCEL", "IRQ wait did not block before cancellation")
        adapter.disable_queue(GQ_TX, 7);
        #1ns;
        if (!wait_returned)
            `uvm_fatal("DMAQ_IRQ_CANCEL", "disable did not cancel a blocked IRQ wait")

        adapter.reset_dmaq(7);
        wait_returned = 0;
        fork
            begin
                adapter.wait_irq(GQ_TX, 7);
                wait_returned = 1;
            end
        join_none
        #1ns;
        adapter.trigger_irq(7);
        #1ns;
        adapter.ack_irq(GQ_TX, 7);
        if (!wait_returned || adapter.wait_irq_count[7] != 2 ||
            adapter.ack_irq_count[7] != 1 || adapter.irq_events[7].is_on())
            `uvm_fatal("DMAQ_IRQ", "IRQ delegation was not persistent and acknowledged")
    endtask

    function void build_phase(uvm_phase phase);
        dmaq_env_cfg default_cfg;
        dmaq_env_cfg custom_cfg;
        dmaq_env_cfg duplicate_cfg;
        dmaq_env_cfg null_cfg;
        dmaq_env_cfg wrong_cfg;
        dmaq_env_cfg rejected_cfg;
        dmaq_mock_adapter default_adapter;
        dmaq_mock_adapter custom_adapter;
        dmaq_mock_adapter duplicate_adapter;
        dmaq_mock_adapter rejected_adapter;
        dmaq_wrong_adapter wrong_adapter;
        dmaq_hw_cfg_t hw_cfg;
        dmaq_hw_cfg_t distinct_hw_cfg;
        string reason;
        int unsigned queue_count;

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_2000_0000,
                        64'h0000_0001_20ff_ffff, MODE_LINEAR, 16);
        hw_cfg.queue_hid = 32'h01020304;
        hw_cfg.queue_bdf = 16'h0506;
        hw_cfg.msix_index = 16'h0708;
        hw_cfg.msix_valid = 1;
        distinct_hw_cfg.queue_hid = 32'h89abcdef;
        distinct_hw_cfg.queue_bdf = 16'h1234;
        distinct_hw_cfg.msix_index = 16'h0055;
        distinct_hw_cfg.msix_valid = 1;

        default_cfg = dmaq_env_cfg::type_id::create("default_cfg");
        default_adapter = dmaq_mock_adapter::type_id::create("default_adapter");
        default_cfg.mem = mem;
        default_cfg.adapter = default_adapter;
        if (!default_cfg.add_dmaq(0, hw_cfg, reason))
            `uvm_fatal("DMAQ_PROFILE_DEFAULT", reason)
        check_profile(default_cfg, 0, 32, 31, 10ns, 500ns);

        custom_cfg = dmaq_env_cfg::type_id::create("custom_cfg");
        custom_adapter = dmaq_mock_adapter::type_id::create("custom_adapter");
        custom_cfg.mem = mem;
        custom_cfg.adapter = custom_adapter;
        custom_cfg.depth = 64;
        custom_cfg.initial_logical_seq = 5;
        custom_cfg.poll_interval = 25ns;
        custom_cfg.completion_timeout = 750ns;
        if (!custom_cfg.add_dmaq(0, hw_cfg, reason))
            `uvm_fatal("DMAQ_PROFILE_CUSTOM", reason)
        check_profile(custom_cfg, 0, 64, 5, 25ns, 750ns);

        rejected_cfg = dmaq_env_cfg::type_id::create("depth_zero_cfg");
        rejected_adapter = dmaq_mock_adapter::type_id::create("depth_zero_adapter");
        rejected_cfg.mem = mem;
        rejected_cfg.adapter = rejected_adapter;
        rejected_cfg.depth = 0;
        expect_profile_reject(rejected_cfg, rejected_adapter, hw_cfg,
                              "depth zero");
        rejected_cfg = dmaq_env_cfg::type_id::create("depth_one_cfg");
        rejected_adapter = dmaq_mock_adapter::type_id::create("depth_one_adapter");
        rejected_cfg.mem = mem;
        rejected_cfg.adapter = rejected_adapter;
        rejected_cfg.depth = 1;
        expect_profile_reject(rejected_cfg, rejected_adapter, hw_cfg,
                              "depth one");
        rejected_cfg = dmaq_env_cfg::type_id::create("depth_48_cfg");
        rejected_adapter = dmaq_mock_adapter::type_id::create("depth_48_adapter");
        rejected_cfg.mem = mem;
        rejected_cfg.adapter = rejected_adapter;
        rejected_cfg.depth = 48;
        expect_profile_reject(rejected_cfg, rejected_adapter, hw_cfg,
                              "depth 48");
        rejected_cfg = dmaq_env_cfg::type_id::create("depth_65536_cfg");
        rejected_adapter = dmaq_mock_adapter::type_id::create("depth_65536_adapter");
        rejected_cfg.mem = mem;
        rejected_cfg.adapter = rejected_adapter;
        rejected_cfg.depth = 65536;
        expect_profile_reject(rejected_cfg, rejected_adapter, hw_cfg,
                              "depth 65536");
        rejected_cfg = dmaq_env_cfg::type_id::create("initial_cfg");
        rejected_adapter = dmaq_mock_adapter::type_id::create("initial_adapter");
        rejected_cfg.mem = mem;
        rejected_cfg.adapter = rejected_adapter;
        rejected_cfg.initial_logical_seq = rejected_cfg.depth;
        expect_profile_reject(rejected_cfg, rejected_adapter, hw_cfg,
                              "initial sequence at depth");
        rejected_cfg = dmaq_env_cfg::type_id::create("poll_zero_cfg");
        rejected_adapter = dmaq_mock_adapter::type_id::create("poll_zero_adapter");
        rejected_cfg.mem = mem;
        rejected_cfg.adapter = rejected_adapter;
        rejected_cfg.poll_interval = 0;
        expect_profile_reject(rejected_cfg, rejected_adapter, hw_cfg,
                              "zero poll interval");
        rejected_cfg = dmaq_env_cfg::type_id::create("timeout_equal_cfg");
        rejected_adapter = dmaq_mock_adapter::type_id::create("timeout_equal_adapter");
        rejected_cfg.mem = mem;
        rejected_cfg.adapter = rejected_adapter;
        rejected_cfg.completion_timeout = rejected_cfg.poll_interval;
        expect_profile_reject(rejected_cfg, rejected_adapter, hw_cfg,
                              "timeout equal poll interval");
        rejected_cfg = dmaq_env_cfg::type_id::create("timeout_below_cfg");
        rejected_adapter = dmaq_mock_adapter::type_id::create("timeout_below_adapter");
        rejected_cfg.mem = mem;
        rejected_cfg.adapter = rejected_adapter;
        rejected_cfg.completion_timeout = 5ns;
        expect_profile_reject(rejected_cfg, rejected_adapter, hw_cfg,
                              "timeout below poll interval");

        null_cfg = dmaq_env_cfg::type_id::create("null_cfg");
        null_cfg.mem = mem;
        if (null_cfg.add_dmaq(0, hw_cfg, reason) || reason == "" ||
            null_cfg.queues.num() != 0)
            `uvm_fatal("DMAQ_PROFILE_NULL", "null adapter rejection was not atomic")
        wrong_cfg = dmaq_env_cfg::type_id::create("wrong_cfg");
        wrong_adapter = dmaq_wrong_adapter::type_id::create("wrong_adapter");
        wrong_cfg.mem = mem;
        wrong_cfg.adapter = wrong_adapter;
        if (wrong_cfg.add_dmaq(0, hw_cfg, reason) || reason == "" ||
            wrong_cfg.queues.num() != 0)
            `uvm_fatal("DMAQ_PROFILE_WRONG", "wrong adapter rejection was not atomic")

        duplicate_cfg = dmaq_env_cfg::type_id::create("duplicate_cfg");
        duplicate_adapter = dmaq_mock_adapter::type_id::create("duplicate_adapter");
        duplicate_cfg.mem = mem;
        duplicate_cfg.adapter = duplicate_adapter;
        if (!duplicate_cfg.add_dmaq(0, hw_cfg, reason))
            `uvm_fatal("DMAQ_PROFILE_DUPLICATE", reason)
        queue_count = duplicate_cfg.queues.num();
        if (duplicate_cfg.add_dmaq(0, distinct_hw_cfg, reason) || reason == "" ||
            duplicate_cfg.queues.num() != queue_count ||
            duplicate_adapter.hw_cfg != hw_cfg)
            `uvm_fatal("DMAQ_PROFILE_DUPLICATE", "duplicate request changed state")
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        check_pointer_and_completion();
        check_adapter();
        phase.drop_objection(this);
    endtask
endclass

`endif
