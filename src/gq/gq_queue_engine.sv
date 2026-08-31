`ifndef GQ_QUEUE_ENGINE_SV
`define GQ_QUEUE_ENGINE_SV

class gq_publish_operation;
    gq_logical_seq_t old_tail;
    gq_logical_seq_t new_tail;
    gq_raw_ptr_t raw_tail;
    longint unsigned request_epoch;
    bit allow_during_reset;
    uvm_event done;

    function new(string name = "gq_publish_operation");
        old_tail = 0;
        new_tail = 0;
        raw_tail = 0;
        request_epoch = 0;
        allow_during_reset = 0;
        done = new({name, "_done"});
    endfunction
endclass

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
    protected bit reset_requested_value;
    protected bit shutdown_requested;
    protected longint unsigned reset_epoch_value;
    protected uvm_event ready_event;
    protected uvm_event worker_state_event;
    protected uvm_event new_work_event;
    protected uvm_event completion_deadline_state_event;
    protected uvm_event active_completion_wait_cancel;
    protected uvm_event active_completion_wait_done;
    protected uvm_event active_completion_ack_done;
    protected uvm_event reset_completion_wait_cancel;
    protected uvm_event reset_completion_wait_done;
    protected uvm_event reset_completion_ack_done;
    protected uvm_event reset_finish_done;
    protected bit reset_finish_started;
    protected uvm_event configuration_done;
    protected bit configuration_in_progress;
    protected uvm_event cleanup_done;
    protected bit cleanup_in_progress;
    protected bit publish_in_progress;
    protected uvm_event active_publish_done;
    protected semaphore user_request_ordering;
    protected semaphore submit_serialization;
    protected semaphore completion_serialization;
    protected semaphore completion_commit_boundary;
    protected semaphore state_lock;
    protected gq_desc_base outstanding[gq_logical_seq_t];
    protected bit outstanding_ids[int];
    protected time outstanding_since[gq_logical_seq_t];
    protected bit outstanding_published[gq_logical_seq_t];
    protected bit oldest_timeout_reported;
    protected bit settlement_reserved;
    protected longint unsigned settlement_reserved_epoch;
    protected gq_logical_seq_t settlement_reserved_head;
    protected gq_logical_seq_t logical_head_seq;
    protected gq_logical_seq_t logical_tail_seq;
    protected gq_refill_profile refill_profile;
    protected bit rx_started;
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
        reset_requested_value = 0;
        shutdown_requested    = 0;
        reset_epoch_value     = 0;
        ready_event       = new({name, "_ready"});
        worker_state_event = new({name, "_worker_state"});
        new_work_event    = new({name, "_new_work"});
        completion_deadline_state_event = new(
            {name, "_completion_deadline_state"});
        active_completion_wait_cancel = null;
        active_completion_wait_done = null;
        active_completion_ack_done = null;
        reset_completion_wait_cancel = null;
        reset_completion_wait_done = null;
        reset_completion_ack_done = null;
        reset_finish_done = null;
        reset_finish_started = 0;
        configuration_done = null;
        configuration_in_progress = 0;
        cleanup_done = null;
        cleanup_in_progress = 0;
        publish_in_progress = 0;
        active_publish_done = null;
        user_request_ordering = new(1);
        submit_serialization = new(1);
        completion_serialization = new(1);
        completion_commit_boundary = new(1);
        state_lock        = new(1);
        logical_head_seq  = 0;
        logical_tail_seq  = 0;
        oldest_timeout_reported = 0;
        settlement_reserved = 0;
        settlement_reserved_epoch = 0;
        settlement_reserved_head = 0;
        refill_profile    = null;
        rx_started        = 0;
        space_available   = new({name, "_space_available"});
        completion_ap     = new("completion_ap", this);
        wait_policy       = null;
    endfunction

    // Return newly configured resources as local ownership. The lifecycle
    // owner publishes them under state_lock after the timed adapter call so a
    // concurrent cleanup can adopt and tear down the exact configured ring.
    protected task allocate_and_configure_ring(
        output gq_addr_t new_ring_base,
        output gq_addr_t new_status_addr,
        output longint unsigned new_ring_bytes);
        string reason;
        longint unsigned max_value;
        longint unsigned desc_bytes;

        max_value = '1;
        if (!checked_ring_size(cfg.depth, cfg.desc_size, cfg.status_area_size,
                               desc_bytes, new_ring_bytes, reason))
            `uvm_fatal("GQ_RING_SIZE", reason)

        new_ring_base = mem.alloc(int'(new_ring_bytes), cfg.alignment,
                                  `__FILE__, `__LINE__);
        if (new_ring_base == '1)
            `uvm_fatal("GQ_RING_ALLOC", $sformatf(
                "failed to allocate %0d bytes", new_ring_bytes))
        if (new_ring_base > (max_value - desc_bytes)) begin
            mem.free(new_ring_base, `__FILE__, `__LINE__);
            `uvm_fatal("GQ_RING_ADDR", "status address overflows 64 bits")
        end
        new_status_addr = new_ring_base + desc_bytes;

        if (wait_policy == null) begin
            if (cfg.wait_mode == GQ_POLL)
                wait_policy = gq_poll_wait_policy::type_id::create(
                    "poll_wait_policy");
            else
                wait_policy = gq_irq_wait_policy::type_id::create(
                    "irq_wait_policy");
        end
        adapter.configure_queue(cfg.role, cfg.queue_id, new_ring_base,
                                cfg.depth, cfg.desc_size);
    endtask

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
        bit initialize_owner;
        bit initialize_valid;
        longint unsigned initialize_epoch;
        gq_addr_t new_ring_base;
        gq_addr_t new_status_addr;
        longint unsigned new_ring_bytes;
        uvm_event initialize_done;

        initialize_owner = 0;
        state_lock.get(1);
        if (ready_value) begin
            state_lock.put(1);
            return;
        end
        if (cleanup_in_progress) begin
            // A concurrent initialize joins terminal cleanup instead of
            // reopening the queue while its old hardware state is disabling.
            initialize_done = cleanup_done;
        end else if (configuration_in_progress) begin
            initialize_done = configuration_done;
        end else begin
            configuration_in_progress = 1;
            configuration_done = new({get_name(), "_configuration_done"});
            initialize_done = configuration_done;
            initialize_owner = 1;
            shutdown_requested = 0;
            reset_requested_value = 1;
            ready_value = 0;
            ready_event.reset();
            initialize_epoch = reset_epoch_value;
        end
        state_lock.put(1);
        if (!initialize_owner) begin
            initialize_done.wait_on();
            return;
        end
        if (cfg == null)
            `uvm_fatal("GQ_ENGINE_CFG", "queue configuration must not be null")
        if (!cfg.validate(reason)) begin
            `uvm_fatal("GQ_ENGINE_CFG", reason)
            // A catcher may demote the fatal in a directed negative test.
            // Close the initialization rendezvous without programming or
            // allocating anything so all joiners observe the same failure.
            state_lock.get(1);
            if (configuration_in_progress &&
                configuration_done == initialize_done) begin
                configuration_in_progress = 0;
                if (!shutdown_requested)
                    reset_requested_value = 0;
            end
            state_lock.put(1);
            worker_state_event.trigger();
            initialize_done.trigger();
            return;
        end
        if (mem == null)
            `uvm_fatal("GQ_ENGINE_CFG", "host memory API must not be null")
        if (adapter == null)
            `uvm_fatal("GQ_ENGINE_CFG", "hardware adapter must not be null")
        if (cfg.ptr_codec == null)
            `uvm_fatal("GQ_ENGINE_CFG", "pointer codec must not be null")
        allocate_and_configure_ring(new_ring_base, new_status_addr,
                                    new_ring_bytes);
        state_lock.get(1);
        ring_base_value   = new_ring_base;
        status_addr_value = new_status_addr;
        ring_bytes_value  = new_ring_bytes;
        allocated         = 1;
        configured        = 1;
        initialize_valid = !shutdown_requested &&
                           reset_epoch_value == initialize_epoch;
        if (initialize_valid) begin
            logical_head_seq = cfg.initial_logical_seq;
            logical_tail_seq = cfg.initial_logical_seq;
            reset_requested_value = 0;
            ready_value = 1;
            check_state_invariants("initialize");
        end
        configuration_in_progress = 0;
        state_lock.put(1);
        if (initialize_valid)
            ready_event.trigger();
        worker_state_event.trigger();
        completion_deadline_state_event.trigger();
        initialize_done.trigger();
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

    protected function void release_attempted(
        input gq_desc_base descs[$], int unsigned attempted_count);
        for (int unsigned i = 0; i < attempted_count; i++) begin
            if (descs[i] != null)
                descs[i].release_owned();
        end
    endfunction

    protected function void release_generated(input gq_desc_base descs[$]);
        foreach (descs[i]) begin
            if (descs[i] != null)
                descs[i].release_owned();
        end
    endfunction

    protected function void initialize_response(ref gq_response response,
                                                input string response_name);
        if (response == null)
            response = gq_response::type_id::create(response_name);
        response.status          = GQ_RESOURCE_ERROR;
        response.committed_count = 0;
        response.reset_epoch     = reset_epoch_value;
    endfunction

    protected function void abort_response_by_reset(ref gq_response response);
        response.status          = GQ_ABORTED_BY_RESET;
        response.committed_count = 0;
        response.reset_epoch     = reset_epoch_value;
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
        if (outstanding.num() == 0) begin
            oldest_timeout_reported = 0;
            settlement_reserved = 0;
        end
        outstanding[seq] = desc;
        outstanding_ids[desc.get_inst_id()] = 1;
        outstanding_since[seq] = $time;
        outstanding_published[seq] = 0;
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
        outstanding_since.delete(seq);
        outstanding_published.delete(seq);
        logical_head_seq++;
        oldest_timeout_reported = 0;
        settlement_reserved = 0;
        check_state_invariants("completion retire");
    endfunction

    protected function string format_completion_diagnostic_state(
        input gq_role_e diagnostic_role,
        input int unsigned diagnostic_queue_id,
        input gq_logical_seq_t diagnostic_head,
        input gq_logical_seq_t diagnostic_tail,
        input int unsigned diagnostic_depth,
        input gq_addr_t diagnostic_ring_base,
        input gq_addr_t diagnostic_slot_addr,
        input byte descriptor_bytes[]);
        int unsigned diagnostic_slot;
        string descriptor_hex;
        bit [7:0] value;

        diagnostic_slot = int'(diagnostic_head % diagnostic_depth);
        descriptor_hex = "";
        foreach (descriptor_bytes[i]) begin
            if (i != 0)
                descriptor_hex = {descriptor_hex, " "};
            value = descriptor_bytes[i];
            descriptor_hex = {descriptor_hex, $sformatf("%02x", value)};
        end
        if (descriptor_bytes.size() == 0)
            descriptor_hex = "<none>";
        return $sformatf(
            "role=%s queue_id=%0d head=%0d tail=%0d slot=%0d phase=%0d ring_addr=0x%016h slot_addr=0x%016h descriptor=%s",
            diagnostic_role == GQ_TX ? "TX" : "RX",
            diagnostic_queue_id, diagnostic_head, diagnostic_tail,
            diagnostic_slot,
            gq_phase(diagnostic_head, diagnostic_depth),
            diagnostic_ring_base, diagnostic_slot_addr, descriptor_hex);
    endfunction

    // Caller holds completion_commit_boundary, but never state_lock. A submit
    // may extend the tail while the public memory callback runs, so retry the
    // read until the formatted head/tail/ring snapshot is stable.
    protected task capture_completion_diagnostic_state(
        input longint unsigned diagnostic_epoch,
        input gq_logical_seq_t diagnostic_head,
        input bit require_timeout_reservation,
        output bit diagnostic_current,
        output string diagnostic_state);
        gq_role_e diagnostic_role;
        int unsigned diagnostic_queue_id;
        int unsigned diagnostic_depth;
        int unsigned diagnostic_desc_size;
        gq_logical_seq_t diagnostic_tail;
        gq_addr_t diagnostic_ring_base;
        gq_addr_t diagnostic_slot_addr;
        int unsigned diagnostic_slot;
        byte descriptor_bytes[];
        bit base_current;
        bit tail_changed;

        diagnostic_current = 0;
        diagnostic_state = "";
        forever begin
            state_lock.get(1);
            diagnostic_current = ready_value && !reset_requested_value &&
                                 !shutdown_requested && allocated &&
                                 reset_epoch_value == diagnostic_epoch &&
                                 logical_head_seq == diagnostic_head &&
                                 logical_tail_seq > diagnostic_head &&
                                 (!require_timeout_reservation ||
                                  (oldest_timeout_reported &&
                                   outstanding_since.exists(
                                       diagnostic_head) &&
                                   outstanding_published.exists(
                                       diagnostic_head) &&
                                   outstanding_published[
                                       diagnostic_head]));
            if (diagnostic_current) begin
                diagnostic_role = cfg.role;
                diagnostic_queue_id = cfg.queue_id;
                diagnostic_depth = cfg.depth;
                diagnostic_desc_size = cfg.desc_size;
                diagnostic_tail = logical_tail_seq;
                diagnostic_ring_base = ring_base_value;
                diagnostic_slot = int'(
                    diagnostic_head % diagnostic_depth);
                diagnostic_slot_addr = diagnostic_ring_base +
                    (diagnostic_slot * diagnostic_desc_size);
            end
            state_lock.put(1);
            if (!diagnostic_current)
                return;

            descriptor_bytes = new[0];
            mem.read_mem(diagnostic_slot_addr, diagnostic_desc_size,
                         descriptor_bytes, `__FILE__, `__LINE__);

            state_lock.get(1);
            base_current = ready_value && !reset_requested_value &&
                           !shutdown_requested && allocated &&
                           reset_epoch_value == diagnostic_epoch &&
                           logical_head_seq == diagnostic_head &&
                           ring_base_value == diagnostic_ring_base &&
                           cfg.role == diagnostic_role &&
                           cfg.queue_id == diagnostic_queue_id &&
                           cfg.depth == diagnostic_depth &&
                           cfg.desc_size == diagnostic_desc_size &&
                           (!require_timeout_reservation ||
                            (oldest_timeout_reported &&
                             outstanding_since.exists(diagnostic_head) &&
                             outstanding_published.exists(diagnostic_head) &&
                             outstanding_published[diagnostic_head]));
            tail_changed = base_current &&
                           logical_tail_seq != diagnostic_tail;
            diagnostic_current = base_current && !tail_changed;
            state_lock.put(1);
            if (tail_changed)
                continue;
            if (!diagnostic_current)
                return;

            diagnostic_state = format_completion_diagnostic_state(
                diagnostic_role, diagnostic_queue_id, diagnostic_head,
                diagnostic_tail, diagnostic_depth, diagnostic_ring_base,
                diagnostic_slot_addr, descriptor_bytes);
            return;
        end
    endtask

    // The final deadline is engine-owned and independent of completion-query
    // validity or progress. Reserving under the lifecycle commit boundary
    // gives one report per oldest published logical sequence.
    protected task check_completion_deadline();
        bit deadline_violation;
        bit deadline_candidate;
        bit diagnostic_current;
        bit retry_deadline;
        bit settle_deadline;
        bit reservation_match;
        longint unsigned diagnostic_epoch;
        gq_logical_seq_t diagnostic_head;
        time diagnostic_timeout;
        string diagnostic_state;
        bit final_query_valid;
        int unsigned final_retired_count;

        forever begin
            deadline_violation = 0;
            retry_deadline = 0;
            settle_deadline = 0;
            reservation_match = 0;
            completion_commit_boundary.get(1);
            state_lock.get(1);
            deadline_candidate = ready_value && !reset_requested_value &&
                                 !shutdown_requested && allocated &&
                                 cfg.completion_timeout != 0 &&
                                 logical_tail_seq > logical_head_seq &&
                                 outstanding_since.exists(logical_head_seq) &&
                                 outstanding_published.exists(
                                     logical_head_seq) &&
                                 outstanding_published[logical_head_seq] &&
                                 !oldest_timeout_reported &&
                                 $time >=
                                     outstanding_since[logical_head_seq];
            if (deadline_candidate) begin
                reservation_match = settlement_reserved &&
                                    settlement_reserved_epoch == reset_epoch_value &&
                                    settlement_reserved_head == logical_head_seq;
                settle_deadline =
                    ($time - outstanding_since[logical_head_seq]) ==
                        cfg.completion_timeout &&
                    (!settlement_reserved ||
                     settlement_reserved_epoch != reset_epoch_value ||
                     settlement_reserved_head != logical_head_seq);
                deadline_violation =
                    ($time - outstanding_since[logical_head_seq]) >=
                        cfg.completion_timeout && !reservation_match;
                if (settle_deadline) begin
                    settlement_reserved = 1;
                    settlement_reserved_epoch = reset_epoch_value;
                    settlement_reserved_head = logical_head_seq;
                end
            end
            if (deadline_violation && !settle_deadline) begin
                oldest_timeout_reported = 1;
                diagnostic_epoch = reset_epoch_value;
                diagnostic_head = logical_head_seq;
                diagnostic_timeout = cfg.completion_timeout;
            end
            state_lock.put(1);

            // Give post-NBA completion writes in the inclusive deadline slot
            // a deterministic chance to drain without advancing simulation
            // time. The producer crosses one NBA barrier before committing,
            // so the checker crosses a second barrier before re-evaluating.
            // Remembering the exact epoch/head candidate bounds this zero-time
            // settlement to one pass; a lifecycle or head change earns a new
            // pass because it represents different outstanding work.
            if (settle_deadline) begin
                completion_commit_boundary.put(1);
                uvm_wait_for_nba_region();
                uvm_wait_for_nba_region();
                drain_completed_once(final_query_valid,
                                     final_retired_count, 0);

                // The inclusive deadline candidate gets exactly one final,
                // serialized query after NBA settlement. Revalidate the same
                // epoch/head under the lifecycle boundary before reserving a
                // timeout; retirement, reset, or cleanup wins cleanly.
                completion_commit_boundary.get(1);
                state_lock.get(1);
                deadline_violation = ready_value &&
                                     !reset_requested_value &&
                                     !shutdown_requested && allocated &&
                                     reset_epoch_value == settlement_reserved_epoch &&
                                     logical_head_seq == settlement_reserved_head &&
                                     cfg.completion_timeout != 0 &&
                                     logical_tail_seq > logical_head_seq &&
                                     outstanding_since.exists(
                                         logical_head_seq) &&
                                     outstanding_published.exists(
                                         logical_head_seq) &&
                                     outstanding_published[
                                         logical_head_seq] &&
                                     !oldest_timeout_reported &&
                                     ($time - outstanding_since[
                                         logical_head_seq]) >=
                                         cfg.completion_timeout;
                if (deadline_violation) begin
                    oldest_timeout_reported = 1;
                    diagnostic_epoch = reset_epoch_value;
                    diagnostic_head = logical_head_seq;
                    diagnostic_timeout = cfg.completion_timeout;
                end
                state_lock.put(1);
                if (!deadline_violation) begin
                    completion_commit_boundary.put(1);
                    return;
                end
            end

            if (deadline_violation) begin
                capture_completion_diagnostic_state(
                    diagnostic_epoch, diagnostic_head, 1,
                    diagnostic_current, diagnostic_state);
                if (diagnostic_current)
                    `uvm_error("GQ_COMPLETION_TIMEOUT", $sformatf(
                        "oldest outstanding completion exceeded timeout=%0t; %s",
                        diagnostic_timeout, diagnostic_state))
                else begin
                    state_lock.get(1);
                    if (ready_value && !reset_requested_value &&
                        !shutdown_requested &&
                        reset_epoch_value == diagnostic_epoch &&
                        logical_head_seq == diagnostic_head &&
                        oldest_timeout_reported) begin
                        oldest_timeout_reported = 0;
                        retry_deadline = 1;
                    end
                    state_lock.put(1);
                end
            end
            completion_commit_boundary.put(1);
            if (retry_deadline)
                completion_deadline_state_event.trigger();
            return;
        end
    endtask

    task drain_completed();
        bit query_valid;
        int unsigned retired_count;

        drain_completed_once(query_valid, retired_count, 1);
    endtask

    protected task drain_completed_once(
        output bit query_valid,
        output int unsigned retired_count,
        input bit check_deadline_after);
        gq_desc_base pending[$];
        gq_desc_base desc;
        gq_logical_seq_t query_head;
        gq_logical_seq_t current_outstanding;
        gq_addr_t query_ring_base;
        gq_addr_t query_status_addr;
        int unsigned count;
        bit diagnostic_current;
        bit protocol_violation;
        bit stale_completion;
        longint unsigned query_epoch;
        gq_logical_seq_t diagnostic_head;
        string diagnostic_state;

        query_valid = 0;
        retired_count = 0;
        completion_serialization.get(1);
        state_lock.get(1);
        if (!ready_value) begin
            state_lock.put(1);
            completion_serialization.put(1);
            return;
        end
        query_head = logical_head_seq;
        query_epoch = reset_epoch_value;
        query_ring_base = ring_base_value;
        query_status_addr = status_addr_value;
        for (gq_logical_seq_t seq = logical_head_seq;
             seq < logical_tail_seq; seq++)
            pending.push_back(outstanding[seq]);
        state_lock.put(1);

        cfg.completion_source.query_completed(
            mem, adapter, query_ring_base, query_status_addr, cfg.depth,
            cfg.desc_size, query_head, pending, query_valid, count);
        completion_query_returned();

        // Diagnostics and retirement share the lifecycle commit boundary.
        // Reset or cleanup may win while the external completion query is in
        // flight or while a verification seam is paused; revalidate and
        // reserve any one-shot timeout only after that boundary is acquired.
        completion_commit_entered();
        completion_commit_boundary.get(1);
        state_lock.get(1);
        current_outstanding = logical_tail_seq - logical_head_seq;
        stale_completion = !ready_value || reset_requested_value ||
                           shutdown_requested ||
                           reset_epoch_value != query_epoch;
        protocol_violation = !stale_completion &&
                             query_valid &&
                             (query_head != logical_head_seq ||
                              count > pending.size() ||
                              count > current_outstanding);
        diagnostic_head = logical_head_seq;
        state_lock.put(1);
        if (stale_completion) begin
            query_valid = 0;
            completion_commit_boundary.put(1);
            completion_serialization.put(1);
            return;
        end
        if (!query_valid) begin
            `uvm_warning("GQ_COMPLETION_QUERY",
                         "completion source returned an invalid query")
            completion_commit_boundary.put(1);
            completion_serialization.put(1);
            if (check_deadline_after)
                check_completion_deadline();
            return;
        end
        if (protocol_violation) begin
            query_valid = 0;
            capture_completion_diagnostic_state(
                query_epoch, diagnostic_head, 0,
                diagnostic_current, diagnostic_state);
            if (!diagnostic_current)
                diagnostic_state = "no current outstanding descriptor context";
            `uvm_error("GQ_COMPLETION_PROTOCOL", $sformatf(
                "completion count %0d exceeds pending=%0d/outstanding=%0d or query head changed; %s",
                count, pending.size(), current_outstanding,
                diagnostic_state))
            completion_commit_boundary.put(1);
            completion_serialization.put(1);
            return;
        end

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
            retired_count++;
        end
        if (retired_count != 0)
            space_available.trigger();
        completion_commit_boundary.put(1);
        completion_serialization.put(1);
        if (retired_count != 0)
            completion_deadline_state_event.trigger();
        if (retired_count != 0)
            refill_after_progress(retired_count);
        if (check_deadline_after)
            check_completion_deadline();
    endtask

    // Protected synchronization seam for completion sources that need to
    // rendezvous with external lifecycle control. Production behavior is a
    // zero-time no-op; tests may override it without exposing mutable state.
    protected virtual task completion_query_returned();
    endtask

    // Protected zero-time boundary seam. Overrides may pause before the final
    // epoch validation; mutable engine state remains inaccessible.
    protected virtual task completion_commit_entered();
    endtask

    task wait_and_drain_once();
        bit ready_snapshot;
        bit wait_registered;
        bit ack_required;
        bit query_valid;
        int unsigned retired_count;
        longint unsigned wait_epoch;
        gq_wakeup_e wakeup;
        uvm_event wait_cancel;
        uvm_event wait_done;
        uvm_event ack_done;
        uvm_event conflicting_done;

        if (wait_policy == null)
            `uvm_fatal("GQ_WAIT_POLICY", "completion wait policy is not initialized")
        wait_cancel = new({get_name(), "_active_wait_cancel"});
        wait_done = new({get_name(), "_active_wait_done"});
        ack_done = new({get_name(), "_active_ack_done"});
        wait_registered = 0;
        conflicting_done = null;
        state_lock.get(1);
        ready_snapshot = ready_value && !reset_requested_value &&
                         !shutdown_requested;
        wait_epoch = reset_epoch_value;
        if (ready_snapshot) begin
            if (active_completion_wait_done != null)
                conflicting_done = active_completion_wait_done;
            else if (active_completion_ack_done != null)
                conflicting_done = active_completion_ack_done;
            else begin
                active_completion_wait_cancel = wait_cancel;
                active_completion_wait_done = wait_done;
                wait_registered = 1;
            end
        end
        state_lock.put(1);
        if (!ready_snapshot)
            return;
        if (!wait_registered) begin
            // A public concurrent call does not start a second adapter wait.
            // Waiting on the persistent done event avoids a zero-time retry
            // loop without retaining an engine lock.
            conflicting_done.wait_on();
            return;
        end
        wakeup = GQ_WAKE_CANCELLED;
        if (new_work_event.is_on()) begin
            // Consume work published before this waiter armed without first
            // entering an adapter wait that is immediately discarded.
            wakeup = GQ_WAKE_NEW_WORK;
        end else begin
            // Run the race from an isolated child process so disable fork
            // cannot terminate waits belonging to another engine invocation.
            fork
                begin
                    fork
                        begin
                            wait_policy.wait_for_wakeup(
                                cfg, adapter, wait_cancel, new_work_event,
                                wakeup);
                        end
                        begin
                            wait_cancel.wait_on();
                        end
                    join_any
                    disable fork;
                end
            join
        end
        completion_commit_boundary.get(1);
        state_lock.get(1);
        if (active_completion_wait_cancel == wait_cancel &&
            active_completion_wait_done == wait_done) begin
            active_completion_wait_cancel = null;
            active_completion_wait_done = null;
        end
        ready_snapshot = ready_value && !reset_requested_value &&
                         !shutdown_requested &&
                         reset_epoch_value == wait_epoch;
        ack_required = ready_snapshot && wakeup == GQ_WAKE_IRQ;
        if (ack_required)
            active_completion_ack_done = ack_done;
        state_lock.put(1);
        completion_commit_boundary.put(1);
        wait_done.trigger();
        if (wakeup == GQ_WAKE_NEW_WORK)
            new_work_event.reset();
        if (!ready_snapshot)
            return;
        if (wakeup == GQ_WAKE_CANCELLED)
            return;
        if (wakeup == GQ_WAKE_NEW_WORK) begin
            // The worker loop immediately begins another wait at the restored
            // minimum interval. New work never bypasses that interval with an
            // immediate completion query.
            wait_policy.note_progress();
            return;
        end
        if (wakeup != GQ_WAKE_IRQ && wakeup != GQ_WAKE_WATCHDOG &&
            wakeup != GQ_WAKE_POLL)
            return;

        if (ack_required) begin
            // ACK ownership was committed under the reset boundary, but the
            // external timed operation itself retains no engine lock.
            adapter.ack_irq(cfg.role, cfg.queue_id);
            completion_commit_boundary.get(1);
            state_lock.get(1);
            if (active_completion_ack_done == ack_done)
                active_completion_ack_done = null;
            ready_snapshot = ready_value && !reset_requested_value &&
                             !shutdown_requested &&
                             reset_epoch_value == wait_epoch;
            state_lock.put(1);
            completion_commit_boundary.put(1);
            ack_done.trigger();
            if (!ready_snapshot)
                return;
        end
        drain_completed_once(query_valid, retired_count, 1);
        if (retired_count != 0)
            wait_policy.note_progress();
        else if (query_valid)
            wait_policy.note_idle();
    endtask

    // Lifecycle control captures these persistent handles with the state
    // transition, then quiesces external operations without retaining an
    // engine lock. A trigger that precedes wait_on remains observable.
    protected task quiesce_completion_activity(
        input uvm_event wait_cancel,
        input uvm_event wait_done,
        input uvm_event ack_done);
        if (wait_cancel != null)
            wait_cancel.trigger();
        if (wait_done != null)
            wait_done.wait_on();
        if (ack_done != null)
            ack_done.wait_on();
    endtask

    protected task run_completion_deadline_monitor();
        bit deadline_active;
        bit deadline_expired;
        bit shutdown_snapshot;
        time deadline_at;
        time remaining;

        forever begin
            // Reset and snapshot under the same state exclusion used by every
            // producer. A producer that has updated state but not yet
            // triggered the event may cause one redundant wake, never a lost
            // wake.
            state_lock.get(1);
            completion_deadline_state_event.reset();
            shutdown_snapshot = shutdown_requested;
            deadline_active = !shutdown_snapshot && ready_value &&
                              !reset_requested_value &&
                              cfg.completion_timeout != 0 &&
                              logical_tail_seq > logical_head_seq &&
                              outstanding_since.exists(logical_head_seq) &&
                              outstanding_published.exists(
                                  logical_head_seq) &&
                              outstanding_published[logical_head_seq] &&
                              !oldest_timeout_reported;
            if (deadline_active)
                deadline_at = outstanding_since[logical_head_seq] +
                              cfg.completion_timeout;
            state_lock.put(1);

            if (shutdown_snapshot)
                return;
            if (!deadline_active) begin
                completion_deadline_state_event.wait_on();
                continue;
            end
            if ($time >= deadline_at) begin
                check_completion_deadline();
                continue;
            end

            remaining = deadline_at - $time;
            deadline_expired = 0;
            // Isolate disable fork so it cannot terminate a completion query,
            // adapter wait, or another monitor invocation.
            fork
                begin
                    fork
                        begin
                            #(remaining);
                            deadline_expired = 1;
                        end
                        begin
                            completion_deadline_state_event.wait_on();
                        end
                    join_any
                    disable fork;
                end
            join
            if (deadline_expired)
                check_completion_deadline();
        end
    endtask

    task run_completion_worker();
        fork
            begin
                forever begin
                    bit worker_active;

                    wait_for_worker_ready(worker_active);
                    if (!worker_active)
                        break;
                    wait_and_drain_once();
                end
            end
            begin
                run_completion_deadline_monitor();
            end
        join
    endtask

    protected task wait_for_worker_ready(output bit worker_active);
        bit ready_snapshot;
        bit shutdown_snapshot;
        bit published_snapshot;
        bit progress_feedback_snapshot;

        worker_active = 0;
        forever begin
            state_lock.get(1);
            ready_snapshot    = ready_value;
            shutdown_snapshot = shutdown_requested;
            published_snapshot = cfg.role != GQ_TX ||
                (logical_tail_seq != logical_head_seq &&
                 outstanding_published.exists(logical_head_seq) &&
                 outstanding_published[logical_head_seq]);
            state_lock.put(1);
            if (shutdown_snapshot)
                return;
            if (ready_snapshot && published_snapshot) begin
                worker_active = 1;
                return;
            end
            if (ready_snapshot) begin
                // A TX queue without hardware-visible work has nothing to
                // query or acknowledge. The persistent event closes the
                // publish-versus-wait race without a zero-time retry loop.
                new_work_event.wait_on();
                new_work_event.reset();
                state_lock.get(1);
                progress_feedback_snapshot =
                    ready_value && !reset_requested_value &&
                    !shutdown_requested &&
                    logical_tail_seq != logical_head_seq &&
                    outstanding_published.exists(logical_head_seq) &&
                    outstanding_published[logical_head_seq];
                state_lock.put(1);
                if (progress_feedback_snapshot)
                    // The idle gate consumed the real publish wake, so it owns
                    // the same minimum-interval feedback as NEW_WORK returned
                    // by the active policy wait. Lifecycle-only wakes fail the
                    // locked readiness/published check and preserve backoff.
                    wait_policy.note_progress();
            end else begin
                worker_state_event.wait_on();
                worker_state_event.reset();
            end
        end
    endtask

    // Caller holds submit_serialization. No caller may hold state_lock or
    // completion_serialization while this task prepares descriptors.
    // ownership_transferred stays set after installation even when a later
    // epoch check aborts the response; reset cleanup then owns final release.
    protected task submit_desc_batch_locked(
        input gq_desc_base descs[$],
        inout gq_response response,
        input bit activate_rx,
        input gq_refill_profile activation_profile,
        input longint unsigned request_epoch,
        input bit allow_during_reset,
        output bit capacity_wait_required,
        output bit publish_wait_required,
        output uvm_event wait_publish_done,
        output gq_publish_operation publish_op,
        output bit ownership_transferred);
        int unsigned batch_size;
        int unsigned attempted_count;
        gq_logical_seq_t old_tail;
        gq_logical_seq_t new_tail;
        gq_logical_seq_t seq;
        gq_addr_t submit_ring_base;
        gq_addr_t slot_addr;
        gq_raw_ptr_t encoded_tail;
        gq_ptr_codec publish_codec;
        byte packed_data[];
        bit seen_ids[int];
        bit reservation_current;
        bit stale_request;

        capacity_wait_required = 0;
        publish_wait_required  = 0;
        wait_publish_done      = null;
        publish_op             = null;
        ownership_transferred  = 0;
        batch_size = descs.size();
        if (batch_size == 0 || batch_size > cfg.depth)
            return;
        foreach (descs[i]) begin
            if (descs[i] == null)
                return;
            if (!mark_request_id_seen(descs[i], seen_ids))
                return;
        end

        state_lock.get(1);
        stale_request = shutdown_requested ||
                        reset_epoch_value != request_epoch ||
                        (reset_requested_value && !allow_during_reset);
        if (stale_request || (!ready_value && !allow_during_reset)) begin
            if (stale_request)
                abort_response_by_reset(response);
            state_lock.put(1);
            return;
        end
        if (publish_in_progress) begin
            publish_wait_required = 1;
            wait_publish_done = active_publish_done;
            state_lock.put(1);
            return;
        end
        foreach (descs[i]) begin
            if (outstanding_ids.exists(descs[i].get_inst_id())) begin
                state_lock.put(1);
                return;
            end
        end
        if ((logical_tail_seq - logical_head_seq) + batch_size > cfg.depth) begin
            capacity_wait_required = 1;
            state_lock.put(1);
            return;
        end
        old_tail = logical_tail_seq;
        submit_ring_base = ring_base_value;
        publish_codec = cfg.ptr_codec;
        state_lock.put(1);

        new_tail        = old_tail + batch_size;
        attempted_count = 0;
        for (int unsigned i = 0; i < batch_size; i++) begin
            seq = old_tail + i;
            attempted_count = i + 1;
            descs[i].attach_mem(mem);
            if (!descs[i].prepare()) begin
                release_attempted(descs, attempted_count);
                if (activate_rx && cfg.role == GQ_RX &&
                    cfg.rx_slot_mode == GQ_RX_AUTO_RECYCLE)
                    `uvm_error("GQ_RX_AUTO_RECYCLE_ALLOC", $sformatf(
                        "queue_id=%0d could not prepare auto-recycle descriptor at logical sequence %0d",
                        cfg.queue_id, seq))
                return;
            end
            if (activate_rx && cfg.role == GQ_RX &&
                cfg.rx_slot_mode == GQ_RX_AUTO_RECYCLE &&
                descs[i].owned_allocation_count() != 0) begin
                release_attempted(descs, attempted_count);
                `uvm_error("GQ_RX_AUTO_RECYCLE_ALLOC", $sformatf(
                    "queue_id=%0d auto-recycle descriptor at logical sequence %0d owns a separate allocation",
                    cfg.queue_id, seq))
                return;
            end
            descs[i].mark_available(gq_phase(seq, cfg.depth));
            if (activate_rx && cfg.role == GQ_RX &&
                cfg.rx_slot_mode == GQ_RX_AUTO_RECYCLE) begin
                packed_data = new[cfg.desc_size];
            end else begin
                packed_data = new[0];
                descs[i].pack(packed_data);
                if (packed_data.size() != cfg.desc_size) begin
                    release_attempted(descs, attempted_count);
                    `uvm_fatal("GQ_PACK_SIZE", $sformatf(
                        "role=%s queue_id=%0d logical_seq=%0d expected=%0d actual=%0d",
                        cfg.role == GQ_TX ? "TX" : "RX", cfg.queue_id,
                        seq, cfg.desc_size, packed_data.size()))
                    return;
                end
            end
            slot_addr = submit_ring_base +
                        ((seq % cfg.depth) * cfg.desc_size);
            mem.write_mem(slot_addr, packed_data, `__FILE__, `__LINE__);
        end

        encoded_tail = publish_codec.encode_publish(
            old_tail, new_tail, cfg.depth);

        state_lock.get(1);
        stale_request = shutdown_requested ||
                        reset_epoch_value != request_epoch ||
                        (reset_requested_value && !allow_during_reset) ||
                        (!ready_value && !allow_during_reset);
        reservation_current = !stale_request && allocated && configured &&
                              ring_base_value == submit_ring_base &&
                              logical_tail_seq == old_tail &&
                              cfg.ptr_codec == publish_codec &&
                              !publish_in_progress &&
                              (logical_tail_seq - logical_head_seq) +
                                  batch_size <= cfg.depth;
        foreach (descs[i]) begin
            if (reservation_current &&
                outstanding_ids.exists(descs[i].get_inst_id()))
                reservation_current = 0;
        end
        if (!reservation_current) begin
            if (stale_request)
                abort_response_by_reset(response);
            state_lock.put(1);
            release_attempted(descs, attempted_count);
            return;
        end
        for (int unsigned i = 0; i < batch_size; i++)
            install_outstanding(old_tail + i, descs[i]);
        ownership_transferred = 1;
        logical_tail_seq = new_tail;
        if (activate_rx) begin
            refill_profile = activation_profile;
            rx_started     = 1;
        end
        publish_op = new($sformatf("%s_publish_%0d", get_name(), old_tail));
        publish_op.old_tail = old_tail;
        publish_op.new_tail = new_tail;
        publish_op.raw_tail = encoded_tail;
        publish_op.request_epoch = request_epoch;
        publish_op.allow_during_reset = allow_during_reset;
        publish_in_progress = 1;
        active_publish_done = publish_op.done;
        check_state_invariants("submit commit");
        state_lock.put(1);
    endtask

    protected task publish_and_complete(
        input gq_publish_operation publish_op,
        inout gq_response response);
        gq_logical_seq_t seq;
        bit operation_current;
        bit lifecycle_current;
        bit published_work;

        if (publish_op == null)
            return;
        published_work = 0;

        state_lock.get(1);
        operation_current = publish_in_progress &&
                            active_publish_done == publish_op.done;
        lifecycle_current = operation_current && !shutdown_requested &&
                            reset_epoch_value == publish_op.request_epoch &&
                            (!reset_requested_value ||
                             publish_op.allow_during_reset) &&
                            (ready_value || publish_op.allow_during_reset);
        if (!lifecycle_current) begin
            abort_response_by_reset(response);
            if (operation_current) begin
                publish_in_progress = 0;
                if (active_publish_done == publish_op.done)
                    active_publish_done = null;
            end
            state_lock.put(1);
            publish_op.done.trigger();
            return;
        end
        state_lock.put(1);

        adapter.publish(cfg.role, cfg.queue_id, publish_op.raw_tail);

        state_lock.get(1);
        operation_current = publish_in_progress &&
                            active_publish_done == publish_op.done;
        lifecycle_current = operation_current && !shutdown_requested &&
                            reset_epoch_value == publish_op.request_epoch &&
                            (!reset_requested_value ||
                             publish_op.allow_during_reset) &&
                            (ready_value || publish_op.allow_during_reset);
        // A completion cannot time out before the hardware has observed its
        // published tail. Entries retired while a timed publish was in flight
        // are intentionally skipped instead of recreating stale metadata.
        if (lifecycle_current) begin
            for (seq = publish_op.old_tail;
                 seq < publish_op.new_tail; seq++) begin
                if (outstanding.exists(seq)) begin
                    outstanding_since[seq] = $time;
                    outstanding_published[seq] = 1;
                end
            end
            if (logical_head_seq >= publish_op.old_tail &&
                logical_head_seq < publish_op.new_tail)
                oldest_timeout_reported = 0;
            response.status          = GQ_OK;
            response.committed_count = int'(publish_op.new_tail -
                                             publish_op.old_tail);
            response.reset_epoch     = publish_op.request_epoch;
            published_work = 1;
        end else
            abort_response_by_reset(response);
        if (operation_current) begin
            publish_in_progress = 0;
            if (active_publish_done == publish_op.done)
                active_publish_done = null;
        end
        state_lock.put(1);
        if (published_work) begin
            new_work_event.trigger();
            completion_deadline_state_event.trigger();
        end
        publish_op.done.trigger();
    endtask

    // User callers retain user_request_ordering across waits. Every retry
    // releases submit_serialization before waiting and revalidates lifecycle,
    // descriptor identity, capacity, and the current logical tail.
    protected task submit_desc_batch_ordered(
        input gq_desc_base descs[$],
        inout gq_response response,
        input bit activate_rx,
        input gq_refill_profile activation_profile,
        input longint unsigned request_epoch,
        input bit allow_during_reset,
        output gq_publish_operation publish_op,
        output bit ownership_transferred);
        bit capacity_wait_required;
        bit publish_wait_required;
        uvm_event wait_publish_done;

        publish_op = null;
        ownership_transferred = 0;
        forever begin
            submit_serialization.get(1);
            submit_desc_batch_locked(descs, response, activate_rx,
                                     activation_profile,
                                     request_epoch, allow_during_reset,
                                     capacity_wait_required,
                                     publish_wait_required,
                                     wait_publish_done,
                                     publish_op,
                                     ownership_transferred);
            submit_serialization.put(1);
            if (publish_wait_required) begin
                if (wait_publish_done != null && !wait_publish_done.is_on())
                    wait_publish_done.wait_on();
                continue;
            end
            if (!capacity_wait_required)
                return;
            space_available.wait_on();
            space_available.reset();
        end
    endtask

    task submit_batch(input gq_request request, inout gq_response response);
        gq_desc_base request_descs[$];
        gq_publish_operation publish_op;
        longint unsigned request_epoch;
        bit ownership_transferred;

        initialize_response(response, "submit_response");
        if (request == null || request.kind != GQ_SUBMIT)
            return;
        request_epoch = response.reset_epoch;
        if (reset_requested_value || shutdown_requested) begin
            abort_response_by_reset(response);
            return;
        end
        foreach (request.descs[i])
            request_descs.push_back(request.descs[i]);

        user_request_ordering.get(1);
        submit_desc_batch_ordered(request_descs, response, 0, null,
                                  request_epoch, 0, publish_op,
                                  ownership_transferred);
        user_request_ordering.put(1);
        publish_and_complete(publish_op, response);
    endtask

    task start_rx(input gq_request request, inout gq_response response);
        gq_refill_profile borrowed_profile;
        gq_refill_profile cloned_profile;
        gq_desc_base generated_descs[$];
        gq_desc_base desc;
        gq_publish_operation publish_op;
        gq_logical_seq_t first_seq;
        longint unsigned request_epoch;
        string reason;
        bit can_start;
        bit ownership_transferred;

        initialize_response(response, "start_rx_response");
        if (request == null || request.kind != GQ_START_RX ||
            cfg.role != GQ_RX)
            return;
        request_epoch = response.reset_epoch;
        if (reset_requested_value || shutdown_requested) begin
            abort_response_by_reset(response);
            return;
        end
        borrowed_profile = request.get_refill_profile();
        if (borrowed_profile == null)
            return;

        user_request_ordering.get(1);
        submit_serialization.get(1);
        state_lock.get(1);
        can_start = ready_value && !rx_started &&
                    !reset_requested_value && !shutdown_requested &&
                    reset_epoch_value == request_epoch;
        first_seq = logical_tail_seq;
        if (!can_start && (reset_requested_value || shutdown_requested ||
                           reset_epoch_value != request_epoch))
            abort_response_by_reset(response);
        state_lock.put(1);
        if (!can_start) begin
            submit_serialization.put(1);
            user_request_ordering.put(1);
            return;
        end

        cloned_profile = borrowed_profile.clone_profile();
        if (cloned_profile == null ||
            !cloned_profile.validate(cfg.depth, reason)) begin
            submit_serialization.put(1);
            user_request_ordering.put(1);
            return;
        end
        if (cfg.rx_slot_mode == GQ_RX_AUTO_RECYCLE &&
            cloned_profile.initial_post_count != cfg.depth - 1) begin
            `uvm_error("GQ_RX_AUTO_RECYCLE_ALLOC", $sformatf(
                "queue_id=%0d auto-recycle initial post count %0d must equal depth minus one (%0d)",
                cfg.queue_id, cloned_profile.initial_post_count,
                cfg.depth - 1))
            submit_serialization.put(1);
            user_request_ordering.put(1);
            return;
        end

        for (int unsigned i = 0;
             i < cloned_profile.initial_post_count; i++) begin
            desc = cloned_profile.create_desc(cfg.queue_id, first_seq + i);
            if (desc == null) begin
                release_generated(generated_descs);
                if (cfg.rx_slot_mode == GQ_RX_AUTO_RECYCLE)
                    `uvm_error("GQ_RX_AUTO_RECYCLE_ALLOC", $sformatf(
                        "queue_id=%0d could not create auto-recycle descriptor at logical sequence %0d",
                        cfg.queue_id, first_seq + i))
                submit_serialization.put(1);
                user_request_ordering.put(1);
                return;
            end
            generated_descs.push_back(desc);
        end

        // A zero-sized startup is a successful one-shot activation with no
        // tail publication. Only a later real DUT retirement can trigger refill.
        if (generated_descs.size() == 0) begin
            state_lock.get(1);
            if (!ready_value || rx_started || reset_requested_value ||
                shutdown_requested || reset_epoch_value != request_epoch) begin
                if (reset_requested_value || shutdown_requested ||
                    reset_epoch_value != request_epoch)
                    abort_response_by_reset(response);
                state_lock.put(1);
                submit_serialization.put(1);
                user_request_ordering.put(1);
                return;
            end
            refill_profile = cloned_profile;
            rx_started     = 1;
            state_lock.put(1);
            response.status      = GQ_OK;
            response.reset_epoch = request_epoch;
            submit_serialization.put(1);
            user_request_ordering.put(1);
            return;
        end

        submit_serialization.put(1);
        submit_desc_batch_ordered(generated_descs, response, 1,
                                  cloned_profile, request_epoch, 0, publish_op,
                                  ownership_transferred);
        user_request_ordering.put(1);
        publish_and_complete(publish_op, response);
        if (response.status != GQ_OK && !ownership_transferred)
            release_generated(generated_descs);
    endtask

    // Auto-recycle preserves the hardware ring and published tail. Each fresh
    // logical descriptor is prepared without the state lock, then installed as
    // hardware-visible only after lifecycle and tail revalidation.
    protected task recycle_after_progress(input int unsigned retired_count);
        gq_refill_profile active_profile;
        gq_desc_base desc;
        gq_logical_seq_t install_seq;
        longint unsigned recycle_epoch;
        bit recycle_active;
        bit duplicate_desc;
        bit recycled_work;

        if (retired_count == 0)
            return;

        recycled_work = 0;
        submit_serialization.get(1);
        state_lock.get(1);
        active_profile = refill_profile;
        recycle_epoch = reset_epoch_value;
        recycle_active = cfg.role == GQ_RX &&
                         cfg.rx_slot_mode == GQ_RX_AUTO_RECYCLE &&
                         ready_value && rx_started &&
                         active_profile != null &&
                         !reset_requested_value && !shutdown_requested;
        state_lock.put(1);

        for (int unsigned i = 0;
             recycle_active && i < retired_count; i++) begin
            state_lock.get(1);
            recycle_active = cfg.role == GQ_RX &&
                             cfg.rx_slot_mode == GQ_RX_AUTO_RECYCLE &&
                             ready_value && rx_started &&
                             refill_profile == active_profile &&
                             reset_epoch_value == recycle_epoch &&
                             !reset_requested_value && !shutdown_requested;
            install_seq = logical_tail_seq;
            state_lock.put(1);
            if (!recycle_active)
                break;

            desc = active_profile.create_desc(cfg.queue_id, install_seq);
            if (desc == null) begin
                `uvm_error("GQ_RX_AUTO_RECYCLE_ALLOC", $sformatf(
                    "queue_id=%0d could not create auto-recycle descriptor at logical sequence %0d",
                    cfg.queue_id, install_seq))
                break;
            end
            desc.attach_mem(mem);
            if (!desc.prepare()) begin
                desc.release_owned();
                `uvm_error("GQ_RX_AUTO_RECYCLE_ALLOC", $sformatf(
                    "queue_id=%0d could not prepare auto-recycle descriptor at logical sequence %0d",
                    cfg.queue_id, install_seq))
                break;
            end
            if (desc.owned_allocation_count() != 0) begin
                desc.release_owned();
                `uvm_error("GQ_RX_AUTO_RECYCLE_ALLOC", $sformatf(
                    "queue_id=%0d auto-recycle descriptor at logical sequence %0d owns a separate allocation",
                    cfg.queue_id, install_seq))
                break;
            end
            desc.mark_available(gq_phase(install_seq, cfg.depth));

            state_lock.get(1);
            recycle_active = ready_value && rx_started &&
                             refill_profile == active_profile &&
                             reset_epoch_value == recycle_epoch &&
                             !reset_requested_value && !shutdown_requested &&
                             logical_tail_seq == install_seq;
            duplicate_desc = recycle_active &&
                             outstanding_ids.exists(desc.get_inst_id());
            if (recycle_active && !duplicate_desc) begin
                install_outstanding(install_seq, desc);
                outstanding_published[install_seq] = 1;
                logical_tail_seq++;
                recycled_work = 1;
                check_state_invariants("auto-recycle commit");
            end
            state_lock.put(1);

            if (!recycle_active) begin
                desc.release_owned();
                break;
            end
            if (duplicate_desc) begin
                desc.release_owned();
                `uvm_error("GQ_RX_AUTO_RECYCLE_ALLOC", $sformatf(
                    "queue_id=%0d returned a duplicate auto-recycle descriptor at logical sequence %0d",
                    cfg.queue_id, install_seq))
                break;
            end
        end
        submit_serialization.put(1);
        if (recycled_work)
            completion_deadline_state_event.trigger();
    endtask

    // Called only after at least one descriptor was actually retired. It
    // deliberately acquires neither completion_serialization nor state_lock
    // across descriptor creation, preparation, or publication.
    protected task refill_after_progress(input int unsigned retired_count);
        gq_refill_profile active_profile;
        gq_desc_base generated_descs[$];
        gq_desc_base desc;
        gq_response response;
        gq_publish_operation publish_op;
        uvm_event wait_publish_done;
        gq_logical_seq_t posted;
        gq_logical_seq_t first_seq;
        int unsigned refill_count;
        bit capacity_wait_required;
        bit publish_wait_required;
        bit refill_active;
        bit refill_triggered;
        bit should_refill;
        bit ownership_transferred;
        longint unsigned refill_epoch;

        if (cfg.rx_slot_mode == GQ_RX_AUTO_RECYCLE) begin
            recycle_after_progress(retired_count);
            return;
        end

        state_lock.get(1);
        refill_active = cfg.role == GQ_RX && ready_value && rx_started &&
                        refill_profile != null && !reset_requested_value &&
                        !shutdown_requested;
        refill_epoch = reset_epoch_value;
        state_lock.put(1);
        if (!refill_active)
            return;
        refill_triggered = 0;

        forever begin
            generated_descs.delete();
            publish_op = null;
            wait_publish_done = null;
            ownership_transferred = 0;

            submit_serialization.get(1);
            state_lock.get(1);
            active_profile = refill_profile;
            should_refill  = cfg.role == GQ_RX && ready_value && rx_started &&
                             !reset_requested_value && !shutdown_requested &&
                             reset_epoch_value == refill_epoch &&
                             active_profile != null;
            if (should_refill && publish_in_progress)
                wait_publish_done = active_publish_done;
            if (should_refill && wait_publish_done == null) begin
                posted        = logical_tail_seq - logical_head_seq;
                first_seq     = logical_tail_seq;
                if (refill_triggered)
                    should_refill = posted < active_profile.high_watermark;
                else
                    should_refill = posted <= active_profile.low_watermark;
                if (should_refill &&
                    posted < active_profile.high_watermark) begin
                    refill_triggered = 1;
                    refill_count = int'(
                        active_profile.high_watermark - posted);
                    if (active_profile.max_refill_batch != 0 &&
                        refill_count > active_profile.max_refill_batch)
                        refill_count = active_profile.max_refill_batch;
                end else
                    should_refill = 0;
            end
            state_lock.put(1);

            if (wait_publish_done != null) begin
                submit_serialization.put(1);
                if (!wait_publish_done.is_on())
                    wait_publish_done.wait_on();
                continue;
            end

            if (!should_refill) begin
                submit_serialization.put(1);
                return;
            end

            for (int unsigned i = 0; i < refill_count; i++) begin
                desc = active_profile.create_desc(
                    cfg.queue_id, first_seq + i);
                if (desc == null) begin
                    release_generated(generated_descs);
                    `uvm_error("GQ_REFILL", $sformatf(
                        "role=RX queue_id=%0d could not create refill descriptor at logical sequence %0d",
                        cfg.queue_id, first_seq + i))
                    submit_serialization.put(1);
                    return;
                end
                generated_descs.push_back(desc);
            end

            initialize_response(response, "refill_response");
            submit_desc_batch_locked(generated_descs, response, 0, null,
                                     refill_epoch, 0,
                                     capacity_wait_required,
                                     publish_wait_required,
                                     wait_publish_done,
                                     publish_op,
                                     ownership_transferred);
            submit_serialization.put(1);

            if (publish_wait_required) begin
                release_generated(generated_descs);
                if (wait_publish_done != null &&
                    !wait_publish_done.is_on())
                    wait_publish_done.wait_on();
                continue;
            end
            if (capacity_wait_required) begin
                release_generated(generated_descs);
                space_available.wait_on();
                space_available.reset();
                continue;
            end

            publish_and_complete(publish_op, response);
            if (response.status != GQ_OK && !ownership_transferred) begin
                release_generated(generated_descs);
                if (response.status != GQ_ABORTED_BY_RESET)
                    `uvm_error("GQ_REFILL", $sformatf(
                        "role=RX queue_id=%0d failed to publish %0d refill descriptors after DUT progress",
                        cfg.queue_id, refill_count))
            end
            if (response.status != GQ_OK)
                return;
        end
    endtask

    // Caller has already made reset/shutdown visible and awakened capacity
    // waiters. The fixed quiesce order is submit -> completion -> state.
    protected task release_queue_resources(
        input bit preserve_restart_profile,
        input bit queue_already_disabled = 0);
        gq_logical_seq_t seq;
        gq_desc_base cleanup_descs[$];
        gq_refill_profile preserved_profile;
        bit release_configured;
        bit release_allocated;
        gq_addr_t release_ring_base;
        uvm_event release_publish_done;

        submit_serialization.get(1);
        completion_serialization.get(1);
        state_lock.get(1);
        release_publish_done = publish_in_progress ? active_publish_done : null;
        if (outstanding.first(seq)) begin
            do begin
                if (outstanding[seq] != null)
                    cleanup_descs.push_back(outstanding[seq]);
            end while (outstanding.next(seq));
        end
        outstanding.delete();
        outstanding_ids.delete();
        outstanding_since.delete();
        outstanding_published.delete();
        oldest_timeout_reported = 0;
        settlement_reserved = 0;
        logical_head_seq = cfg.initial_logical_seq;
        logical_tail_seq = cfg.initial_logical_seq;
        if (preserve_restart_profile && cfg.role == GQ_RX &&
            refill_profile != null && refill_profile.restart_after_reset)
            preserved_profile = refill_profile;
        else
            preserved_profile = null;
        refill_profile   = preserved_profile;
        rx_started       = 0;
        release_configured = configured;
        release_allocated = allocated;
        release_ring_base = ring_base_value;
        configured       = 0;
        allocated        = 0;
        ring_base_value   = 0;
        status_addr_value = 0;
        ring_bytes_value  = 0;
        check_state_invariants(preserve_restart_profile ?
                               "reset assert" : "cleanup");
        state_lock.put(1);
        completion_serialization.put(1);
        submit_serialization.put(1);
        completion_deadline_state_event.trigger();

        // Timed adapter work retains no engine lock. The queue remains
        // externally owned until disable completes, so descriptor and ring
        // release must stay after this call.
        if (release_configured && !queue_already_disabled)
            adapter.disable_queue(cfg.role, cfg.queue_id);
        if (release_publish_done != null && !release_publish_done.is_on())
            release_publish_done.wait_on();
        foreach (cleanup_descs[i])
            cleanup_descs[i].release_owned();
        if (release_allocated)
            mem.free(release_ring_base, `__FILE__, `__LINE__);
        ready_event.reset();
    endtask

    task begin_reset();
        bit accept_reset;
        uvm_event wait_cancel;

        completion_commit_boundary.get(1);
        state_lock.get(1);
        accept_reset = !shutdown_requested && !reset_requested_value &&
                       (ready_value || allocated || configured);
        if (accept_reset) begin
            reset_requested_value = 1;
            ready_value           = 0;
            reset_epoch_value++;
            settlement_reserved = 0;
            ready_event.reset();
            wait_cancel = active_completion_wait_cancel;
            reset_completion_wait_cancel = wait_cancel;
            reset_completion_wait_done = active_completion_wait_done;
            reset_completion_ack_done = active_completion_ack_done;
            reset_finish_done = new({get_name(), "_reset_finish_done"});
            reset_finish_started = 0;
        end
        state_lock.put(1);
        completion_commit_boundary.put(1);
        if (!accept_reset)
            return;

        // A waiter keeps user_request_ordering but has released submit. This
        // persistent wake makes it retry, observe the new epoch, and abort.
        space_available.trigger();
        worker_state_event.trigger();
        completion_deadline_state_event.trigger();
        if (wait_cancel != null)
            wait_cancel.trigger();
        new_work_event.trigger();
    endtask

    task finish_reset();
        bit finish_owner;
        uvm_event finish_done;
        uvm_event wait_cancel;
        uvm_event wait_done;
        uvm_event ack_done;

        finish_owner = 0;
        state_lock.get(1);
        finish_done = reset_finish_done;
        if (finish_done != null && !finish_done.is_on() &&
            !reset_finish_started) begin
            reset_finish_started = 1;
            finish_owner = 1;
            wait_cancel = reset_completion_wait_cancel;
            wait_done = reset_completion_wait_done;
            ack_done = reset_completion_ack_done;
        end
        state_lock.put(1);

        if (!finish_owner) begin
            if (finish_done != null && !finish_done.is_on())
                finish_done.wait_on();
            return;
        end

        quiesce_completion_activity(wait_cancel, wait_done, ack_done);
        release_queue_resources(1);
        finish_done.trigger();
    endtask

    task assert_reset();
        begin_reset();
        finish_reset();
    endtask

    task release_reset();
        gq_refill_profile recovery_profile;
        gq_desc_base generated_descs[$];
        gq_desc_base desc;
        gq_response response;
        gq_publish_operation publish_op;
        longint unsigned release_epoch;
        longint unsigned new_ring_bytes;
        gq_addr_t new_ring_base;
        gq_addr_t new_status_addr;
        bit ownership_transferred;
        bit release_allowed;
        bit release_owner;
        uvm_event release_done;

        release_owner = 0;
        state_lock.get(1);
        if (configuration_in_progress) begin
            release_done = configuration_done;
        end else begin
            release_allowed = reset_requested_value && !shutdown_requested &&
                              !allocated && !configured &&
                              (reset_finish_done == null ||
                               reset_finish_done.is_on());
            if (release_allowed) begin
                configuration_in_progress = 1;
                configuration_done = new(
                    {get_name(), "_reset_release_done"});
                release_done = configuration_done;
                release_owner = 1;
                release_epoch = reset_epoch_value;
                recovery_profile = refill_profile;
            end
        end
        state_lock.put(1);
        if (!release_owner) begin
            if (release_done != null && !release_done.is_on())
                release_done.wait_on();
            return;
        end

        allocate_and_configure_ring(new_ring_base, new_status_addr,
                                    new_ring_bytes);
        // Publish the configured ring even if shutdown won while the adapter
        // was running. Cleanup joins release_done and then detaches exactly
        // these resources; local ownership is never discarded.
        state_lock.get(1);
        ring_base_value = new_ring_base;
        status_addr_value = new_status_addr;
        ring_bytes_value = new_ring_bytes;
        allocated = 1;
        configured = 1;
        state_lock.put(1);

        if (cfg.role == GQ_RX && recovery_profile != null &&
            recovery_profile.restart_after_reset) begin
            for (int unsigned i = 0;
                 i < recovery_profile.initial_post_count; i++) begin
                desc = recovery_profile.create_desc(cfg.queue_id,
                    cfg.initial_logical_seq + gq_logical_seq_t'(i));
                if (desc == null) begin
                    release_generated(generated_descs);
                    generated_descs.delete();
                    `uvm_error("GQ_RESET_RX", $sformatf(
                        "role=RX queue_id=%0d could not recreate descriptor %0d",
                        cfg.queue_id, i))
                    state_lock.get(1);
                    refill_profile = null;
                    rx_started     = 0;
                    state_lock.put(1);
                    break;
                end
                generated_descs.push_back(desc);
            end

            if (generated_descs.size() == 0 &&
                recovery_profile.initial_post_count == 0) begin
                state_lock.get(1);
                if (!shutdown_requested && reset_requested_value &&
                    reset_epoch_value == release_epoch) begin
                    refill_profile = recovery_profile;
                    rx_started     = 1;
                end
                state_lock.put(1);
            end else if (generated_descs.size() ==
                recovery_profile.initial_post_count) begin
                initialize_response(response, "reset_rx_response");
                submit_desc_batch_ordered(generated_descs, response, 1,
                                          recovery_profile, release_epoch, 1,
                                          publish_op, ownership_transferred);
                publish_and_complete(publish_op, response);
                if (response.status != GQ_OK) begin
                    if (!ownership_transferred)
                        release_generated(generated_descs);
                    if (response.status != GQ_ABORTED_BY_RESET)
                        `uvm_error("GQ_RESET_RX", $sformatf(
                            "role=RX queue_id=%0d failed to repost %0d descriptors",
                            cfg.queue_id, generated_descs.size()))
                    state_lock.get(1);
                    refill_profile = null;
                    rx_started     = 0;
                    state_lock.put(1);
                end
            end
        end

        state_lock.get(1);
        if (!shutdown_requested && reset_requested_value &&
            reset_epoch_value == release_epoch) begin
            reset_requested_value = 0;
            ready_value           = 1;
            check_state_invariants("reset release");
        end
        release_allowed = ready_value;
        configuration_in_progress = 0;
        state_lock.put(1);
        if (release_allowed)
            ready_event.trigger();
        worker_state_event.trigger();
        completion_deadline_state_event.trigger();
        release_done.trigger();
    endtask

    task cleanup();
        bit cleanup_required;
        bit cleanup_owner;
        uvm_event wait_cancel;
        uvm_event wait_done;
        uvm_event ack_done;
        uvm_event reset_teardown_done;
        uvm_event configure_done;
        uvm_event configure_publish_done;
        uvm_event operation_done;
        bit configure_publish_disabled;

        cleanup_owner = 0;
        completion_commit_boundary.get(1);
        state_lock.get(1);
        if (cleanup_in_progress) begin
            operation_done = cleanup_done;
        end else begin
            cleanup_required = !shutdown_requested || ready_value ||
                               allocated || configured ||
                               outstanding.num() != 0 ||
                               configuration_in_progress ||
                               (reset_finish_done != null &&
                                !reset_finish_done.is_on());
            if (cleanup_required) begin
                cleanup_in_progress = 1;
                cleanup_done = new({get_name(), "_cleanup_done"});
                operation_done = cleanup_done;
                cleanup_owner = 1;
                if (!shutdown_requested)
                    reset_epoch_value++;
                settlement_reserved = 0;
                shutdown_requested    = 1;
                reset_requested_value = 1;
                ready_value           = 0;
                ready_event.reset();
                wait_cancel = active_completion_wait_cancel;
                wait_done = active_completion_wait_done;
                ack_done = active_completion_ack_done;
                if (reset_finish_done != null &&
                    !reset_finish_done.is_on())
                    reset_teardown_done = reset_finish_done;
                if (configuration_in_progress) begin
                    configure_done = configuration_done;
                    if (publish_in_progress)
                        configure_publish_done = active_publish_done;
                end
            end
        end
        state_lock.put(1);
        completion_commit_boundary.put(1);

        if (!cleanup_owner) begin
            if (operation_done != null && !operation_done.is_on())
                operation_done.wait_on();
            return;
        end

        space_available.trigger();
        worker_state_event.trigger();
        completion_deadline_state_event.trigger();
        if (wait_cancel != null)
            wait_cancel.trigger();
        new_work_event.trigger();
        quiesce_completion_activity(wait_cancel, wait_done, ack_done);
        if (reset_teardown_done != null)
            reset_teardown_done.wait_on();
        configure_publish_disabled = 0;
        if (configure_publish_done != null) begin
            adapter.disable_queue(cfg.role, cfg.queue_id);
            configure_publish_disabled = 1;
            if (!configure_publish_done.is_on())
                configure_publish_done.wait_on();
        end
        if (configure_done != null)
            configure_done.wait_on();
        if (cleanup_required)
            release_queue_resources(0, configure_publish_disabled);
        space_available.reset();
        state_lock.get(1);
        cleanup_in_progress = 0;
        state_lock.put(1);
        operation_done.trigger();
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

    function longint unsigned reset_epoch();
        return reset_epoch_value;
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
