`ifndef GQ_QUEUE_ENGINE_SVH
`define GQ_QUEUE_ENGINE_SVH

class gq_queue_engine extends uvm_component;
    `uvm_component_utils(gq_queue_engine)

    protected gq_queue_cfg cfg;
    protected host_mem_api mem;
    protected gq_hw_adapter adapter;
    protected gq_addr_t ring_base_value;
    protected gq_addr_t status_addr_value;
    protected longint unsigned ring_bytes_value;
    protected bit allocated;
    protected bit configured;
    protected bit ready_value;
    protected uvm_event ready_event;
    protected semaphore submit_lock;
    protected gq_desc_base outstanding[gq_logical_seq_t];

    gq_logical_seq_t logical_head_seq;
    gq_logical_seq_t logical_tail_seq;
    uvm_event space_available;

    function new(string name = "gq_queue_engine", uvm_component parent = null);
        super.new(name, parent);
        ring_base_value   = 0;
        status_addr_value = 0;
        ring_bytes_value  = 0;
        allocated         = 0;
        configured        = 0;
        ready_value       = 0;
        ready_event       = new({name, "_ready"});
        submit_lock       = new(1);
        logical_head_seq  = 0;
        logical_tail_seq  = 0;
        space_available   = new({name, "_space_available"});
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

        if (ready_value)
            return;
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
        configured  = 1;
        ready_value = 1;
        ready_event.trigger();
    endtask

    task wait_ready();
        if (!ready_value)
            ready_event.wait_trigger();
    endtask

    protected function void release_attempted(gq_request request,
                                              int unsigned attempted_count);
        for (int unsigned i = 0; i < attempted_count; i++) begin
            if (request.descs[i] != null)
                request.descs[i].release_owned();
        end
    endfunction

    task submit_batch(input gq_request request, inout gq_response response);
        int unsigned batch_size;
        int unsigned attempted_count;
        gq_logical_seq_t old_tail;
        gq_logical_seq_t new_tail;
        gq_logical_seq_t seq;
        gq_raw_ptr_t raw_tail;
        gq_addr_t slot_addr;
        byte packed_data[];

        if (response == null)
            response = gq_response::type_id::create("submit_response");
        response.status          = GQ_RESOURCE_ERROR;
        response.committed_count = 0;
        response.reset_epoch     = 0;

        if (!ready_value || request == null || request.kind != GQ_SUBMIT)
            return;
        batch_size = request.size();
        if (batch_size == 0 || batch_size > cfg.depth)
            return;
        foreach (request.descs[i]) begin
            if (request.descs[i] == null)
                return;
        end

        forever begin
            submit_lock.get(1);
            if ((logical_tail_seq - logical_head_seq) + batch_size <= cfg.depth)
                break;
            submit_lock.put(1);
            space_available.wait_on();
            space_available.reset();
        end

        old_tail        = logical_tail_seq;
        new_tail        = old_tail + batch_size;
        attempted_count = 0;
        for (int unsigned i = 0; i < batch_size; i++) begin
            seq = old_tail + i;
            attempted_count = i + 1;
            request.descs[i].attach_mem(mem);
            if (!request.descs[i].prepare()) begin
                release_attempted(request, attempted_count);
                submit_lock.put(1);
                return;
            end
            request.descs[i].mark_available(gq_phase(seq, cfg.depth));
            packed_data = new[0];
            request.descs[i].pack(packed_data);
            if (packed_data.size() != cfg.desc_size) begin
                release_attempted(request, attempted_count);
                submit_lock.put(1);
                return;
            end
            slot_addr = ring_base_value + ((seq % cfg.depth) * cfg.desc_size);
            mem.write_mem(slot_addr, packed_data, `__FILE__, `__LINE__);
        end

        for (int unsigned i = 0; i < batch_size; i++)
            outstanding[old_tail + i] = request.descs[i];
        logical_tail_seq = new_tail;
        response.status          = GQ_OK;
        response.committed_count = int'(batch_size);
        raw_tail = cfg.ptr_codec.encode_publish(old_tail, new_tail, cfg.depth);
        adapter.publish(cfg.role, cfg.queue_id, raw_tail);
        submit_lock.put(1);
    endtask

    task cleanup();
        gq_logical_seq_t seq;

        if (outstanding.first(seq)) begin
            do begin
                if (outstanding[seq] != null)
                    outstanding[seq].release_owned();
            end while (outstanding.next(seq));
        end
        outstanding.delete();
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
        ready_value       = 0;
        logical_head_seq  = 0;
        logical_tail_seq  = 0;
        ready_event.reset();
        space_available.reset();
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
