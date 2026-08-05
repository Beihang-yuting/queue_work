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

    function new(string name = "gq_queue_engine", uvm_component parent = null);
        super.new(name, parent);
        ring_base_value   = 0;
        status_addr_value = 0;
        ring_bytes_value  = 0;
        allocated         = 0;
        configured        = 0;
        ready_value       = 0;
        ready_event       = new({name, "_ready"});
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

    task cleanup();
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
        ready_event.reset();
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
endclass

`endif
