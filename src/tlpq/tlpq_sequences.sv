`ifndef TLPQ_SEQUENCES_SV
`define TLPQ_SEQUENCES_SV

class tlpq_rx_start_sequence extends uvm_sequence #(gq_request, gq_response);
    `uvm_object_utils(tlpq_rx_start_sequence)

    tlpq_channel_e channel;
    protected tlpq_refill_profile refill_profile;
    gq_response response;

    function new(string name = "tlpq_rx_start_sequence");
        super.new(name);
        channel = TLPQ_HOST;
        refill_profile = null;
        response = null;
    endfunction

    function void set_refill_profile(tlpq_refill_profile profile);
        refill_profile = profile;
    endfunction

    function tlpq_refill_profile get_refill_profile();
        return refill_profile;
    endfunction

    task body();
        gq_request request;

        request = gq_request::type_id::create(
            channel == TLPQ_HOST ? "host_start_request" :
                                   "switch_start_request");
        request.kind = GQ_START_RX;
        request.set_refill_profile(refill_profile);
        start_item(request);
        finish_item(request);
        get_response(response);
    endtask
endclass

class tlpq_dual_rx_start_sequence extends uvm_sequence;
    `uvm_object_utils(tlpq_dual_rx_start_sequence)

    gq_sequencer host_sequencer;
    gq_sequencer switch_sequencer;
    tlpq_refill_profile host_refill_profile;
    tlpq_refill_profile switch_refill_profile;
    gq_response host_response;
    gq_response switch_response;

    function new(string name = "tlpq_dual_rx_start_sequence");
        super.new(name);
        host_sequencer = null;
        switch_sequencer = null;
        host_refill_profile = null;
        switch_refill_profile = null;
        host_response = null;
        switch_response = null;
    endfunction

    function bit configure(
        tlpq_env_cfg env_cfg,
        gq_sequencer host_sequencer,
        gq_sequencer switch_sequencer,
        output string reason);
        if (env_cfg == null || host_sequencer == null ||
            switch_sequencer == null) begin
            reason = "dual RX start requires an environment and two sequencers";
            return 0;
        end
        if (host_sequencer == switch_sequencer) begin
            reason = "dual RX start requires distinct Host and Switch sequencers";
            return 0;
        end
        host_refill_profile = env_cfg.get_refill_profile(TLPQ_HOST);
        switch_refill_profile = env_cfg.get_refill_profile(TLPQ_SWITCH);
        if (host_refill_profile == null || switch_refill_profile == null) begin
            reason = "dual RX start requires Host and Switch refill profiles";
            return 0;
        end
        this.host_sequencer = host_sequencer;
        this.switch_sequencer = switch_sequencer;
        reason = "";
        return 1;
    endfunction

    task body();
        tlpq_rx_start_sequence host_start;
        tlpq_rx_start_sequence switch_start;

        host_response = null;
        switch_response = null;
        if (host_sequencer == null || switch_sequencer == null ||
            host_refill_profile == null || switch_refill_profile == null) begin
            `uvm_error("TLPQ_DUAL_START",
                       "dual RX start sequence is not configured")
            return;
        end

        host_start = tlpq_rx_start_sequence::type_id::create("host_start");
        host_start.channel = TLPQ_HOST;
        host_start.set_refill_profile(host_refill_profile);
        host_start.start(host_sequencer);
        host_response = host_start.response;

        switch_start = tlpq_rx_start_sequence::type_id::create(
            "switch_start");
        switch_start.channel = TLPQ_SWITCH;
        switch_start.set_refill_profile(switch_refill_profile);
        switch_start.start(switch_sequencer);
        switch_response = switch_start.response;
    endtask
endclass

`endif
