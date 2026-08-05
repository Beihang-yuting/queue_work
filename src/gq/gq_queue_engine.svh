`ifndef GQ_QUEUE_ENGINE_SVH
`define GQ_QUEUE_ENGINE_SVH

class gq_queue_engine extends uvm_component;
    `uvm_component_utils(gq_queue_engine)

    protected gq_queue_cfg cfg;
    protected host_mem_api mem;
    protected gq_hw_adapter adapter;
    protected gq_wait_policy wait_policy;
    protected gq_addr_t ring_base_value;
    protected gq_addr_t status_addr_value;
    protected longint unsigned ring_bytes_value;
    protected bit allocated;
    protected bit configured;
    protected bit ready_value;
    protected uvm_event ready_event;
    protected semaphore submit_serialization;
    protected semaphore completion_serialization;
    protected semaphore state_lock;
    protected gq_desc_base outstanding[gq_logical_seq_t];
    protected bit outstanding_ids[int];
    protected gq_logical_seq_t logical_head_seq;
    protected gq_logical_seq_t logical_tail_seq;
    protected uvm_event space_available;
    uvm_analysis_port #(gq_desc_base) completion_ap;

    function new(string name = "gq_queue_engine", uvm_component parent = null);
        super.new(name, parent);
        ring_base_value   = 0;
        status_addr_value = 0;
        ring_bytes_value  = 0;
        allocated         = 0;
        configured        = 0;
        ready_value       = 0;
        ready_event       = new({name, "_ready"});
        submit_serialization = new(1);
        completion_serialization = new(1);
        state_lock        = new(1);
        logical_head_seq  = 0;
        logical_tail_seq  = 0;
        space_available   = new({name, "_space_available"});
        completion_ap     = new("completion_ap", this);
        wait_policy       = null;
    endfunction

    static function bit checked_ring_size(
        input int unsigned depth,
        input int unsigned desc_size,
        input int unsigned status_area_size,
        output longint unsigned descriptor_bytes,
        output longint unsigned ring_bytes,
        output string reason);
        longint unsigned max_value;

        descriptor_bytes = 0;
        ring_bytes       = 0;
        max_value        = '1;

        if (depth == 0 || desc_size == 0) begin
            reason = "ring depth and descriptor size must be non-zero";
            return 0;
        end

        descriptor_bytes = depth;
        if (descriptor_bytes > (max_value / desc_size)) begin
            reason = "descriptor ring size overflows 64 bits";
            return 0;
        end
        descriptor_bytes = descriptor_bytes * desc_size;

        if (status_area_size > (max_value - descriptor_bytes)) begin
            reason = "ring plus status area overflows 64 bits";
            return 0;
        end
        ring_bytes = descriptor_bytes + status_area_size;

        if (ring_bytes > 64'h0000_0000_ffff_ffff) begin
            reason = $sformatf("ring size %0d is outside allocator range", ring_bytes);
            return 0;
        end

        reason = "";
        return 1;
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(gq_queue_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal("GQ_ENGINE_CFG", {get_full_name(), ": missing queue configuration"})
        if (!uvm_config_db#(host_mem_api)::get(this, "", "mem", mem))
            `uvm_fatal("GQ_ENGINE_CFG", {get_full_name(), ": missing host memory API"})
        if (!uvm_config_db#(gq_hw_adapter)::get(this, "", "adapter", adapter))
            `uvm_fatal("GQ_ENGINE_CFG", {get_full_name(), ": missing hardware adapter"})
    endfunction

    task initialize();
        string reason;
        longint unsigned max_value;
        longint unsigned desc_bytes;

        state_lock.get(1);
        if (ready_value) begin
            state_lock.put(1);
            return;
        end
        state_lock.put(1);
        if (cfg == null)
            `uvm_fatal("GQ_ENGINE_CFG", "queue configuration must not be null")
        if (!cfg.validate(reason))
            `uvm_fatal("GQ_ENGINE_CFG", reason)
        if (mem == null)
            `uvm_fatal("GQ_ENGINE_CFG", "host memory API must not be null")
        if (adapter == null)
            `uvm_fatal("GQ_ENGINE_CFG", "hardware adapter must not be null")
        if (cfg.ptr_codec == null)
            `uvm_fatal("GQ_ENGINE_CFG", "pointer codec must not be null")

        if (cfg.wait_mode == GQ_POLL)
            wait_policy = gq_poll_wait_policy::type_id::create(
                "poll_wait_policy");
        else
            wait_policy = gq_irq_wait_policy::type_id::create(
                "irq_wait_policy");

        max_value = '1;
        if (!checked_ring_size(cfg.depth, cfg.desc_size, cfg.status_area_size,
                               desc_bytes, ring_bytes_value, reason))
            `uvm_fatal("GQ_RING_SIZE", reason)

        ring_base_value = mem.alloc(int'(ring_bytes_value), cfg.alignment,
                                    `__FILE__, `__LINE__);
        if (ring_base_value == '1)
            `uvm_fatal("GQ_RING_ALLOC", $sformatf("failed to allocate %0d bytes",
                                                   ring_bytes_value))
        allocated = 1;

        if (ring_base_value > (max_value - desc_bytes)) begin
            mem.free(ring_base_value, `__FILE__, `__LINE__);
            allocated = 0;
            ring_base_value = 0;
            `uvm_fatal("GQ_RING_ADDR", "status address overflows 64 bits")
        end
        status_addr_value = ring_base_value + desc_bytes;

        adapter.configure_queue(cfg.role, cfg.queue_id, ring_base_value,
                                cfg.depth, cfg.desc_size);
        state_lock.get(1);
        configured  = 1;
        ready_value = 1;
        check_state_invariants("initialize");
        state_lock.put(1);
        ready_event.trigger();
    endtask

    task wait_ready();
        bit ready_snapshot;

        forever begin
            state_lock.get(1);
            ready_snapshot = ready_value;
            state_lock.put(1);
            if (ready_snapshot)
                return;
            ready_event.wait_on();
        end
    endtask

    protected function void release_attempted(gq_request request,
                                              int unsigned attempted_count);
        for (int unsigned i = 0; i < attempted_count; i++) begin
            if (request.descs[i] != null)
                request.descs[i].release_owned();
        end
    endfunction

    protected virtual function bit mark_request_id_seen(
        gq_desc_base desc, ref bit seen_ids[int]);
        int id;

        id = desc.get_inst_id();
        if (seen_ids.exists(id))
            return 0;
        seen_ids[id] = 1;
        return 1;
    endfunction

    // Caller holds state_lock.
    protected virtual function void audit_outstanding_entry(
        string transition_name, gq_logical_seq_t seq, gq_desc_base desc);
        int id;

        if (desc == null) begin
            `uvm_fatal("GQ_STATE", $sformatf(
                "%s: null outstanding handle at logical sequence %0d",
                transition_name, seq))
            return;
        end
        id = desc.get_inst_id();
        if (!outstanding_ids.exists(id))
            `uvm_fatal("GQ_STATE", $sformatf(
                "%s: outstanding handle id %0d is not indexed",
                transition_name, id))
    endfunction

    // Caller holds state_lock. This full audit is linear in the outstanding
    // count and is reserved for explicit debug or verification paths.
    protected function void audit_state_invariants(string transition_name);
        gq_logical_seq_t seq;

        if (outstanding.first(seq)) begin
            do begin
                audit_outstanding_entry(transition_name, seq, outstanding[seq]);
            end while (outstanding.next(seq));
        end
    endfunction

    // Caller holds state_lock after any head/tail/outstanding transition.
    protected function void check_state_invariants(string transition_name);
        gq_logical_seq_t count;

        if (logical_tail_seq < logical_head_seq)
            `uvm_fatal("GQ_STATE", $sformatf("%s: tail %0d precedes head %0d",
                                               transition_name, logical_tail_seq,
                                               logical_head_seq))
        count = logical_tail_seq - logical_head_seq;
        if (count > cfg.depth || outstanding.num() != count ||
            outstanding_ids.num() != outstanding.num())
            `uvm_fatal("GQ_STATE", $sformatf(
                "%s: outstanding handles=%0d ids=%0d logical count=%0d depth=%0d",
                transition_name, outstanding.num(), outstanding_ids.num(),
                count, cfg.depth))
    endfunction

    // Caller holds state_lock. Handle and ID-index mutations must stay paired;
    // completion retirement must remove both before advancing the logical head.
    protected function void install_outstanding(gq_logical_seq_t seq,
                                                gq_desc_base desc);
        outstanding[seq] = desc;
        outstanding_ids[desc.get_inst_id()] = 1;
    endfunction

    // Caller holds state_lock. Handle and ID-index deletion, then head
    // advancement, form one atomic retirement transition.
    protected function void retire_outstanding(gq_logical_seq_t seq,
                                               gq_desc_base desc);
        if (seq != logical_head_seq || !outstanding.exists(seq) ||
            outstanding[seq] != desc)
            `uvm_fatal("GQ_STATE", $sformatf(
                "retire mismatch at logical sequence %0d (head=%0d)",
                seq, logical_head_seq))

        outstanding.delete(seq);
        outstanding_ids.delete(desc.get_inst_id());
        logical_head_seq++;
        check_state_invariants("completion retire");
    endfunction

    task drain_completed();
        gq_desc_base pending[$];
        gq_desc_base desc;
        gq_logical_seq_t query_head;
        gq_logical_seq_t current_outstanding;
        int unsigned count;
        bit retired_any;
        bit protocol_violation;

        completion_serialization.get(1);
        state_lock.get(1);
        if (!ready_value) begin
            state_lock.put(1);
            completion_serialization.put(1);
            return;
        end
        query_head = logical_head_seq;
        for (gq_logical_seq_t seq = logical_head_seq;
             seq < logical_tail_seq; seq++)
            pending.push_back(outstanding[seq]);
        state_lock.put(1);

        count = cfg.completion_source.completed_count(
            mem, ring_base_value, status_addr_value, cfg.depth, cfg.desc_size,
            query_head, pending);
        state_lock.get(1);
        current_outstanding = logical_tail_seq - logical_head_seq;
        protocol_violation = query_head != logical_head_seq ||
                             count > pending.size() ||
                             count > current_outstanding;
        state_lock.put(1);
        if (protocol_violation) begin
            `uvm_error("GQ_COMPLETION_PROTOCOL", $sformatf(
                "completion count %0d exceeds pending=%0d/outstanding=%0d or query head changed",
                count, pending.size(), current_outstanding))
            completion_serialization.put(1);
            return;
        end

        retired_any = 0;
        for (int unsigned i = 0; i < count; i++) begin
            desc = pending[i];
            if (!desc.parse_completion()) begin
                `uvm_error("GQ_COMPLETION_PARSE", $sformatf(
                    "completion parse failed at logical sequence %0d",
                    query_head + i))
                break;
            end
            // Analysis delivery is synchronous: subscribers see the parsed
            // descriptor while owned allocations are still valid. Ownership
            // is released immediately after write() returns, before the
            // handle and ID index are atomically retired under state_lock.
            completion_ap.write(desc);
            desc.release_owned();

            state_lock.get(1);
            retire_outstanding(query_head + i, desc);
            state_lock.put(1);
            retired_any = 1;
        end
        if (retired_any)
            space_available.trigger();
        completion_serialization.put(1);
    endtask

    task wait_and_drain_once();
        bit ready_snapshot;

        if (wait_policy == null)
            `uvm_fatal("GQ_WAIT_POLICY", "completion wait policy is not initialized")
        wait_policy.wait_for_wakeup(cfg, adapter);
        state_lock.get(1);
        ready_snapshot = ready_value;
        state_lock.put(1);
        if (!ready_snapshot)
            return;
        drain_completed();
    endtask

    task run_completion_worker();
        wait_ready();
        forever begin
            wait_and_drain_once();
            if (!is_ready())
                return;
        end
    endtask

    task submit_batch(input gq_request request, inout gq_response response);
        int unsigned batch_size;
        int unsigned attempted_count;
        gq_logical_seq_t old_tail;
        gq_logical_seq_t new_tail;
        gq_logical_seq_t seq;
        gq_raw_ptr_t raw_tail;
        gq_addr_t slot_addr;
        byte packed_data[];
        bit seen_ids[int];

        if (response == null)
            response = gq_response::type_id::create("submit_response");
        response.status          = GQ_RESOURCE_ERROR;
        response.committed_count = 0;
        response.reset_epoch     = 0;

        if (request == null || request.kind != GQ_SUBMIT)
            return;
        batch_size = request.size();
        if (batch_size == 0 || batch_size > cfg.depth)
            return;
        foreach (request.descs[i]) begin
            if (request.descs[i] == null)
                return;
            if (!mark_request_id_seen(request.descs[i], seen_ids))
                return;
        end

        submit_serialization.get(1);
        forever begin
            state_lock.get(1);
            if (!ready_value) begin
                state_lock.put(1);
                submit_serialization.put(1);
                return;
            end
            foreach (request.descs[i]) begin
                if (outstanding_ids.exists(request.descs[i].get_inst_id())) begin
                    state_lock.put(1);
                    submit_serialization.put(1);
                    return;
                end
            end
            if ((logical_tail_seq - logical_head_seq) + batch_size <= cfg.depth) begin
                old_tail = logical_tail_seq;
                state_lock.put(1);
                break;
            end
            state_lock.put(1);
            space_available.wait_on();
            space_available.reset();
        end

        new_tail        = old_tail + batch_size;
        attempted_count = 0;
        for (int unsigned i = 0; i < batch_size; i++) begin
            seq = old_tail + i;
            attempted_count = i + 1;
            request.descs[i].attach_mem(mem);
            if (!request.descs[i].prepare()) begin
                release_attempted(request, attempted_count);
                submit_serialization.put(1);
                return;
            end
            request.descs[i].mark_available(gq_phase(seq, cfg.depth));
            packed_data = new[0];
            request.descs[i].pack(packed_data);
            if (packed_data.size() != cfg.desc_size) begin
                release_attempted(request, attempted_count);
                submit_serialization.put(1);
                `uvm_fatal("GQ_PACK_SIZE", $sformatf(
                    "role=%s queue_id=%0d logical_seq=%0d expected=%0d actual=%0d",
                    cfg.role == GQ_TX ? "TX" : "RX", cfg.queue_id, seq,
                    cfg.desc_size, packed_data.size()))
                return;
            end
            slot_addr = ring_base_value + ((seq % cfg.depth) * cfg.desc_size);
            mem.write_mem(slot_addr, packed_data, `__FILE__, `__LINE__);
        end

        state_lock.get(1);
        for (int unsigned i = 0; i < batch_size; i++)
            install_outstanding(old_tail + i, request.descs[i]);
        logical_tail_seq = new_tail;
        check_state_invariants("submit commit");
        state_lock.put(1);
        raw_tail = cfg.ptr_codec.encode_publish(old_tail, new_tail, cfg.depth);
        adapter.publish(cfg.role, cfg.queue_id, raw_tail);
        response.status          = GQ_OK;
        response.committed_count = int'(batch_size);
        submit_serialization.put(1);
    endtask

    task cleanup();
        gq_logical_seq_t seq;
        gq_desc_base cleanup_descs[$];

        completion_serialization.get(1);
        state_lock.get(1);
        if (outstanding.first(seq)) begin
            do begin
                if (outstanding[seq] != null)
                    cleanup_descs.push_back(outstanding[seq]);
            end while (outstanding.next(seq));
        end
        outstanding.delete();
        outstanding_ids.delete();
        ready_value      = 0;
        logical_head_seq = 0;
        logical_tail_seq = 0;
        check_state_invariants("cleanup");
        state_lock.put(1);

        foreach (cleanup_descs[i])
            cleanup_descs[i].release_owned();
        if (configured) begin
            adapter.disable_queue(cfg.role, cfg.queue_id);
            configured = 0;
        end
        if (allocated) begin
            mem.free(ring_base_value, `__FILE__, `__LINE__);
            allocated = 0;
        end
        ring_base_value   = 0;
        status_addr_value = 0;
        ring_bytes_value  = 0;
        wait_policy       = null;
        ready_event.reset();
        space_available.reset();
        completion_serialization.put(1);
    endtask

    function gq_addr_t ring_base();
        return ring_base_value;
    endfunction

    function gq_addr_t status_addr();
        return status_addr_value;
    endfunction

    function longint unsigned ring_size();
        return ring_bytes_value;
    endfunction

    function bit is_ready();
        return ready_value;
    endfunction

    // Verification hook: acquires no mutable access and proves that timed
    // adapter operations never retain the engine state lock.
    protected task probe_state_lock();
        state_lock.get(1);
        state_lock.put(1);
    endtask

    function gq_logical_seq_t head_seq();
        return logical_head_seq;
    endfunction

    function gq_logical_seq_t tail_seq();
        return logical_tail_seq;
    endfunction

    function int unsigned outstanding_count();
        return int'(logical_tail_seq - logical_head_seq);
    endfunction

    function gq_desc_base get_outstanding(gq_logical_seq_t seq);
        if (!outstanding.exists(seq))
            return null;
        return outstanding[seq];
    endfunction
endclass

`endif
