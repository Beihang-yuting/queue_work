`ifndef GQ_DESC_BASE_SVH
`define GQ_DESC_BASE_SVH

typedef struct {
    gq_addr_t   addr;
    host_mem_api allocator;
} gq_owned_allocation_t;

virtual class gq_desc_base extends uvm_sequence_item;
    host_mem_api mem;

    protected gq_owned_allocation_t owned_allocations[$];
    protected bit released;

    function new(string name = "gq_desc_base");
        super.new(name);
        mem      = null;
        released = 0;
    endfunction

    function void attach_mem(host_mem_api memory);
        mem = memory;
    endfunction

    function void set_mem(host_mem_api memory);
        attach_mem(memory);
    endfunction

    function gq_addr_t alloc_owned(int unsigned size, int unsigned align = 1);
        gq_addr_t addr;
        host_mem_api allocator;
        gq_owned_allocation_t owned;

        if (mem == null)
            return '1;

        allocator = mem;
        addr = allocator.alloc(size, align, `__FILE__, `__LINE__);
        if (addr != '1) begin
            owned.addr      = addr;
            owned.allocator = allocator;
            owned_allocations.push_back(owned);
            released = 0;
        end
        return addr;
    endfunction

    function void release_owned();
        if (released)
            return;

        foreach (owned_allocations[i])
            owned_allocations[i].allocator.free(owned_allocations[i].addr,
                                                `__FILE__, `__LINE__);
        owned_allocations.delete();
        released = 1;
    endfunction

    virtual function bit prepare();
        return 1;
    endfunction

    // Once an engine calls prepare(), this descriptor is one-shot even if a
    // later member makes the atomic batch roll back. Rollback releases owned
    // allocations; callers create a fresh descriptor instead of rearming it.

    virtual function void mark_available(bit phase);
    endfunction

    virtual function void pack(ref byte packed_data[]);
        packed_data = new[0];
    endfunction

    virtual function bit unpack(input byte packed_data[]);
        return 0;
    endfunction

    virtual function bit is_complete(bit phase);
        return 0;
    endfunction

    virtual function bit parse_completion();
        return 1;
    endfunction
endclass

`endif
