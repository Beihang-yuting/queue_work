`ifndef GQ_RESET_CONTROLLER_SVH
`define GQ_RESET_CONTROLLER_SVH

class gq_reset_controller extends uvm_component;
    `uvm_component_utils(gq_reset_controller)

    gq_env_cfg cfg;
    protected gq_queue_engine engines[string];

    function new(string name = "gq_reset_controller",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void register_engine(string key, gq_queue_engine engine);
        if (engine == null)
            `uvm_fatal("GQ_RESET_CFG", {"null engine for ", key})
        if (engines.exists(key))
            `uvm_fatal("GQ_RESET_CFG", {"duplicate engine ", key})
        engines[key] = engine;
    endfunction

    task run_phase(uvm_phase phase);
        string key;

        if (cfg == null)
            `uvm_fatal("GQ_RESET_CFG", "reset controller has no environment configuration")
        cfg.wait_ready();
        forever begin
            // wait_on observes an edge that was triggered before this task
            // started. Reset before processing so a later cycle can persist.
            cfg.reset_asserted.wait_on();
            cfg.reset_asserted.reset();
            if (engines.first(key)) begin
                do begin
                    engines[key].assert_reset();
                end while (engines.next(key));
            end

            cfg.reset_deasserted.wait_on();
            cfg.reset_deasserted.reset();
            if (engines.first(key)) begin
                do begin
                    engines[key].release_reset();
                end while (engines.next(key));
            end
        end
    endtask
endclass

`endif
