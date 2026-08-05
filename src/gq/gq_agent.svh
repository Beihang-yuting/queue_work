`ifndef GQ_AGENT_SVH
`define GQ_AGENT_SVH

class gq_sequencer extends uvm_sequencer #(gq_request, gq_response);
    `uvm_component_utils(gq_sequencer)

    function new(string name = "gq_sequencer", uvm_component parent = null);
        super.new(name, parent);
    endfunction
endclass

class gq_driver extends uvm_driver #(gq_request, gq_response);
    `uvm_component_utils(gq_driver)

    gq_queue_engine engine;

    function new(string name = "gq_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        gq_request request;
        gq_response response;

        engine.wait_ready();
        forever begin
            seq_item_port.get_next_item(request);
            response = gq_response::type_id::create("response");
            response.set_id_info(request);
            case (request.kind)
                GQ_SUBMIT:   engine.submit_batch(request, response);
                GQ_START_RX: engine.start_rx(request, response);
                default: begin
                    response.status          = GQ_RESOURCE_ERROR;
                    response.committed_count = 0;
                    response.reset_epoch     = 0;
                end
            endcase
            seq_item_port.item_done(response);
        end
    endtask
endclass

class gq_completion_worker extends uvm_component;
    `uvm_component_utils(gq_completion_worker)

    gq_queue_engine engine;

    function new(string name = "gq_completion_worker",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        if (engine == null)
            `uvm_fatal("GQ_WORKER_CFG", "completion worker has no queue engine")
        engine.run_completion_worker();
    endtask
endclass

class gq_queue_agent extends uvm_agent;
    `uvm_component_utils(gq_queue_agent)

    gq_queue_engine engine;
    gq_sequencer sequencer;
    gq_driver driver;
    gq_completion_worker completion_worker;

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
        sequencer = gq_sequencer::type_id::create("sequencer", this);
        driver    = gq_driver::type_id::create("driver", this);
        completion_worker = gq_completion_worker::type_id::create(
            "completion_worker", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        driver.engine = engine;
        completion_worker.engine = engine;
        driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
endclass

`endif
