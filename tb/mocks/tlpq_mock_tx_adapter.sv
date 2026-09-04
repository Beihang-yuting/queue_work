// tb/mocks/tlpq_mock_tx_adapter.sv: 记录分块回调、ready 等待和控制标志的 TLPQ 发送模拟适配器。
`ifndef TLPQ_MOCK_TX_ADAPTER_SV
`define TLPQ_MOCK_TX_ADAPTER_SV

typedef struct {
    bit sop;
    bit eop;
    bit valid;
} tlpq_mock_tx_ctrl_t;

class tlpq_mock_tx_adapter extends tlpq_tx_reg_adapter;
    `uvm_object_utils(tlpq_mock_tx_adapter)

    int unsigned ready_wait_count[int];
    time ready_wait_time[int][$];
    bit ready_result_script[int][$];
    int unsigned blocked_wait_ordinal[int];
    uvm_event ready_wait_entered[int];
    uvm_event ready_wait_release[int];
    string event_kind[int][$];
    time ready_at[int];
    bit force_timeout[int];
    int unsigned data_word_index[int][$];
    bit [31:0] data_word[int][$];
    time data_write_time[int][$];
    bit [15:0] keep_write[int][$];
    bit [2:0] tuser_write[int][$];
    tlpq_mock_tx_ctrl_t ctrl_write[int][$];

    function new(string name = "tlpq_mock_tx_adapter");
        super.new(name);
        ready_wait_entered[int'(TLPQ_HOST)] =
            new("host_ready_wait_entered");
        ready_wait_entered[int'(TLPQ_SWITCH)] =
            new("switch_ready_wait_entered");
        ready_wait_release[int'(TLPQ_HOST)] =
            new("host_ready_wait_release");
        ready_wait_release[int'(TLPQ_SWITCH)] =
            new("switch_ready_wait_release");
    endfunction

    function void reset_channel(tlpq_channel_e channel);
        int channel_key;

        channel_key = int'(channel);
        ready_wait_count[channel_key] = 0;
        ready_wait_time[channel_key].delete();
        ready_result_script[channel_key].delete();
        blocked_wait_ordinal[channel_key] = 0;
        ready_wait_entered[channel_key].reset();
        ready_wait_release[channel_key].reset();
        event_kind[channel_key].delete();
        data_word_index[channel_key].delete();
        data_word[channel_key].delete();
        data_write_time[channel_key].delete();
        keep_write[channel_key].delete();
        tuser_write[channel_key].delete();
        ctrl_write[channel_key].delete();
        ready_at[channel_key] = $time;
        force_timeout[channel_key] = 0;
    endfunction

    function void set_ready_at(tlpq_channel_e channel, time at_time);
        int channel_key;

        channel_key = int'(channel);
        ready_at[channel_key] = at_time;
        force_timeout[channel_key] = 0;
    endfunction

    function void set_force_timeout(tlpq_channel_e channel, bit enable);
        force_timeout[int'(channel)] = enable;
    endfunction

    function void script_ready_result(tlpq_channel_e channel, bit ready);
        ready_result_script[int'(channel)].push_back(ready);
    endfunction

    function void block_ready_wait(tlpq_channel_e channel,
                                   int unsigned wait_ordinal);
        int channel_key;

        channel_key = int'(channel);
        blocked_wait_ordinal[channel_key] = wait_ordinal;
        ready_wait_release[channel_key].reset();
    endfunction

    function void release_ready_wait(tlpq_channel_e channel);
        ready_wait_release[int'(channel)].trigger();
    endfunction

    virtual task wait_tlpq_tx_ready(
        tlpq_channel_e channel, time timeout, output bit ready);
        int channel_key;
        int unsigned wait_ordinal;
        time delay_to_ready;

        channel_key = int'(channel);
        ready_wait_count[channel_key]++;
        wait_ordinal = ready_wait_count[channel_key];
        ready_wait_time[channel_key].push_back($time);
        event_kind[channel_key].push_back("WAIT");
        ready_wait_entered[channel_key].trigger();
        if (blocked_wait_ordinal.exists(channel_key) &&
            blocked_wait_ordinal[channel_key] == wait_ordinal)
            ready_wait_release[channel_key].wait_trigger();
        if (ready_result_script[channel_key].size() != 0) begin
            ready = ready_result_script[channel_key].pop_front();
            if (!ready)
                #(timeout);
            return;
        end
        if (force_timeout.exists(channel_key) &&
            force_timeout[channel_key]) begin
            #(timeout);
            ready = 0;
            return;
        end
        if (!ready_at.exists(channel_key) || $time >= ready_at[channel_key]) begin
            ready = 1;
            return;
        end
        delay_to_ready = ready_at[channel_key] - $time;
        if (delay_to_ready > timeout) begin
            #(timeout);
            ready = 0;
            return;
        end
        #(delay_to_ready);
        ready = 1;
    endtask

    virtual task write_tlpq_tx_data(
        tlpq_channel_e channel, int unsigned word_index, bit [31:0] data);
        int channel_key;

        channel_key = int'(channel);
        data_word_index[channel_key].push_back(word_index);
        data_word[channel_key].push_back(data);
        data_write_time[channel_key].push_back($time);
        event_kind[channel_key].push_back("DATA");
    endtask

    virtual task write_tlpq_tx_keep(
        tlpq_channel_e channel, bit [15:0] keep);
        keep_write[int'(channel)].push_back(keep);
        event_kind[int'(channel)].push_back("KEEP");
    endtask

    virtual task write_tlpq_tx_tuser(
        tlpq_channel_e channel, bit [2:0] host_id);
        tuser_write[int'(channel)].push_back(host_id);
        event_kind[int'(channel)].push_back("TUSER");
    endtask

    virtual task write_tlpq_tx_ctrl(
        tlpq_channel_e channel, bit sop, bit eop, bit valid);
        tlpq_mock_tx_ctrl_t ctrl;

        ctrl.sop = sop;
        ctrl.eop = eop;
        ctrl.valid = valid;
        ctrl_write[int'(channel)].push_back(ctrl);
        event_kind[int'(channel)].push_back("CTRL");
    endtask
endclass

`endif
