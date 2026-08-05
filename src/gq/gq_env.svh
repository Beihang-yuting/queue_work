`ifndef GQ_ENV_SVH
`define GQ_ENV_SVH

class gq_env extends uvm_env;
    `uvm_component_utils(gq_env)

    protected gq_env_cfg cfg;
    protected gq_queue_agent agents[string];
    protected gq_reset_controller reset_controller;

    function new(string name = "gq_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        string key;
        string reason;

        super.build_phase(phase);
        if (!uvm_config_db#(gq_env_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal("GQ_ENV_CFG", {get_full_name(), ": missing environment configuration"})
        if (!cfg.validate(reason))
            `uvm_fatal("GQ_ENV_CFG", reason)

        reset_controller = gq_reset_controller::type_id::create(
            "reset_controller", this);
        reset_controller.cfg = cfg;

        if (cfg.queues.first(key)) begin
            do begin
                uvm_config_db#(gq_queue_cfg)::set(this, key, "cfg", cfg.queues[key]);
                uvm_config_db#(host_mem_api)::set(this, key, "mem", cfg.mem);
                uvm_config_db#(gq_hw_adapter)::set(this, key, "adapter", cfg.adapter);
                agents[key] = gq_queue_agent::type_id::create(key, this);
            end while (cfg.queues.next(key));
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        string key;

        super.connect_phase(phase);
        if (agents.first(key)) begin
            do begin
                reset_controller.register_engine(key, agents[key].engine);
            end while (agents.next(key));
        end
    endfunction

    task run_phase(uvm_phase phase);
        string key;

        phase.raise_objection(this, "initialize sparse queue rings");
        if (agents.first(key)) begin
            do begin
                agents[key].engine.initialize();
            end while (agents.next(key));
        end
        cfg.env_ready.trigger();
        phase.drop_objection(this, "sparse queue rings initialized");
    endtask

    task cleanup();
        string key;

        if (agents.first(key)) begin
            do begin
                agents[key].engine.cleanup();
            end while (agents.next(key));
        end
    endtask

    function int unsigned agent_count();
        return agents.num();
    endfunction

    function bit has_agent(string key);
        return agents.exists(key);
    endfunction

    function longint unsigned ring_size(string key);
        if (!agents.exists(key))
            return 0;
        return agents[key].engine.ring_size();
    endfunction

    function gq_addr_t ring_base(string key);
        if (!agents.exists(key))
            return 0;
        return agents[key].engine.ring_base();
    endfunction

    function gq_addr_t status_addr(string key);
        if (!agents.exists(key))
            return 0;
        return agents[key].engine.status_addr();
    endfunction
endclass

`endif
