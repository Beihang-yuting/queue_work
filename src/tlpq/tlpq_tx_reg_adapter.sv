`ifndef TLPQ_TX_REG_ADAPTER_SV
`define TLPQ_TX_REG_ADAPTER_SV

virtual class tlpq_tx_reg_adapter extends uvm_object;
    protected tlpq_packet_bridge packet_bridge;
    protected semaphore host_send_lock;
    protected semaphore switch_send_lock;

    function new(string name = "tlpq_tx_reg_adapter");
        super.new(name);
        packet_bridge = tlpq_packet_bridge::type_id::create(
            {name, "_packet_bridge"});
        host_send_lock = new(1);
        switch_send_lock = new(1);
    endfunction

    pure virtual task wait_tlpq_tx_ready(
        tlpq_channel_e channel, time timeout, output bit ready);

    pure virtual task write_tlpq_tx_data(
        tlpq_channel_e channel, int unsigned word_index, bit [31:0] data);

    pure virtual task write_tlpq_tx_keep(
        tlpq_channel_e channel, bit [15:0] keep);

    pure virtual task write_tlpq_tx_tuser(
        tlpq_channel_e channel, bit [2:0] host_id);

    pure virtual task write_tlpq_tx_ctrl(
        tlpq_channel_e channel, bit sop, bit eop, bit valid);

    protected task send_tlp_locked(
        tlpq_channel_e channel, bit [2:0] host_id,
        pcie_tl_tlp tlp, time ready_timeout,
        output bit success, output string reason);
        bit [31:0] dwords[];
        int unsigned source_index;
        int unsigned chunk_words;
        bit [15:0] keep;
        bit ready;

        success = 0;
        reason = "";
        if (packet_bridge == null) begin
            reason = "TLPQ TX packet bridge is not configured";
            return;
        end
        if (!packet_bridge.encode_tlp(tlp, dwords, reason)) begin
            if (reason == "")
                reason = "TLPQ TX packet encode failed";
            return;
        end

        source_index = 0;
        while (source_index < dwords.size()) begin
            chunk_words = dwords.size() - source_index;
            if (chunk_words > 16)
                chunk_words = 16;

            ready = 0;
            wait_tlpq_tx_ready(channel, ready_timeout, ready);
            if (!ready) begin
                reason = $sformatf(
                    "TLPQ TX channel %0d ready timeout at DWORD %0d",
                    int'(channel), source_index);
                return;
            end

            for (int unsigned word_index = 0;
                 word_index < chunk_words; word_index++)
                write_tlpq_tx_data(
                    channel, word_index, dwords[source_index + word_index]);

            keep = '0;
            for (int unsigned word_index = 0;
                 word_index < chunk_words; word_index++)
                keep[word_index] = 1'b1;
            write_tlpq_tx_keep(channel, keep);
            write_tlpq_tx_tuser(channel, host_id);
            write_tlpq_tx_ctrl(
                channel, source_index == 0,
                source_index + chunk_words == dwords.size(), 1'b1);
            source_index += chunk_words;
        end

        success = 1;
        reason = "";
    endtask

    task send_tlp(
        tlpq_channel_e channel, bit [2:0] host_id,
        pcie_tl_tlp tlp, time ready_timeout,
        output bit success, output string reason);
        semaphore send_lock;

        success = 0;
        reason = "";
        case (channel)
            TLPQ_HOST:   send_lock = host_send_lock;
            TLPQ_SWITCH: send_lock = switch_send_lock;
            default: begin
                reason = $sformatf("invalid TLPQ TX channel %0d",
                                   int'(channel));
                return;
            end
        endcase
        if (send_lock == null) begin
            reason = $sformatf("TLPQ TX channel %0d lock is not configured",
                               int'(channel));
            return;
        end

        // One channel's ready/data/keep/TUSER/control registers form one
        // transaction stream.  Hold its lock from encode through the final
        // control write, while the other channel remains independent.
        send_lock.get(1);
        send_tlp_locked(channel, host_id, tlp, ready_timeout,
                        success, reason);
        send_lock.put(1);
    endtask
endclass

`endif
