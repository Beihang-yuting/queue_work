`ifndef GQ_ENV_SVH
`define GQ_ENV_SVH

class gq_env extends uvm_env;
    `uvm_component_utils(gq_env)

    protected gq_env_cfg cfg;
    protected gq_queue_agent agents[string];
    protected gq_reset_controller reset_controller;
    protected semaphore cleanup_lock;
    protected bit cleanup_started;
    protected uvm_event cleanup_done;
    protected bit finalization_started;
    protected uvm_event finalization_done;
    protected bit run_finalization_scheduled;
    protected uvm_phase run_finalization_phase;

    function new(string name = "gq_env", uvm_component parent = null);
        super.new(name, parent);
        cleanup_lock = new(1);
        cleanup_started = 0;
        cleanup_done = new({name, "_cleanup_done"});
        finalization_started = 0;
        finalization_done = new({name, "_finalization_done"});
        run_finalization_scheduled = 0;
        run_finalization_phase = null;
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

    // UVM runtime subphases named "shutdown" may execute at time zero, so
    // queue teardown cannot be attached to shutdown_phase. Instead, claim one
    // objection only when the top-level run phase is ready to end, launch the
    // timed idempotent finalizer in a child process, and release the objection
    // after every engine and the shared leak check have completed.
    function void phase_ready_to_end(uvm_phase phase);
        super.phase_ready_to_end(phase);
        if (phase.get_name() != "run" || run_finalization_scheduled)
            return;

        run_finalization_scheduled = 1;
        run_finalization_phase = phase;
        run_finalization_phase.raise_objection(
            this, "finalize sparse queue resources");
        fork
            begin
                cleanup_and_check_leaks();
                run_finalization_phase.drop_objection(
                    this, "sparse queue resources finalized");
            end
        join_none
    endfunction

    task cleanup();
        string key;
        bit cleanup_owner;

        cleanup_owner = 0;
        cleanup_lock.get(1);
        if (!cleanup_started) begin
            cleanup_started = 1;
            cleanup_owner = 1;
        end
        cleanup_lock.put(1);
        if (!cleanup_owner) begin
            if (!cleanup_done.is_on())
                cleanup_done.wait_on();
            return;
        end

        if (agents.first(key)) begin
            do begin
                agents[key].engine.cleanup();
            end while (agents.next(key));
        end
        cleanup_done.trigger();
    endtask

    // The environment, rather than any individual engine, owns the shared
    // memory leak check. This guarantees every sparse queue has disabled its
    // hardware and released descriptors/rings before the one global check.
    task cleanup_and_check_leaks();
        bit finalization_owner;

        finalization_owner = 0;
        cleanup_lock.get(1);
        if (!finalization_started) begin
            finalization_started = 1;
            finalization_owner = 1;
        end
        cleanup_lock.put(1);
        if (!finalization_owner) begin
            if (!finalization_done.is_on())
                finalization_done.wait_on();
            return;
        end

        cleanup();
        cfg.mem.leak_check(`__FILE__, `__LINE__);
        finalization_done.trigger();
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
