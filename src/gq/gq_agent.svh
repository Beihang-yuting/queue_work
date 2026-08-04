`ifndef GQ_AGENT_SVH
`define GQ_AGENT_SVH

class gq_queue_agent extends uvm_agent;
    `uvm_component_utils(gq_queue_agent)

    gq_queue_engine engine;

    function new(string name = "gq_queue_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        gq_queue_cfg cfg;
        host_mem_api mem;
        gq_hw_adapter adapter;

        super.build_phase(phase);
        if (!uvm_config_db#(gq_queue_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal("GQ_AGENT_CFG", {get_full_name(), ": missing queue configuration"})
        if (!uvm_config_db#(host_mem_api)::get(this, "", "mem", mem))
            `uvm_fatal("GQ_AGENT_CFG", {get_full_name(), ": missing host memory API"})
        if (!uvm_config_db#(gq_hw_adapter)::get(this, "", "adapter", adapter))
            `uvm_fatal("GQ_AGENT_CFG", {get_full_name(), ": missing hardware adapter"})

        uvm_config_db#(gq_queue_cfg)::set(this, "engine", "cfg", cfg);
        uvm_config_db#(host_mem_api)::set(this, "engine", "mem", mem);
        uvm_config_db#(gq_hw_adapter)::set(this, "engine", "adapter", adapter);
        engine = gq_queue_engine::type_id::create("engine", this);
    endfunction
endclass

`endif
