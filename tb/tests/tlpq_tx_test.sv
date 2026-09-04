// tb/tests/tlpq_tx_test.sv: UVM 测试 tlpq_tx_test：验证对应队列组件的定向行为和接口契约。
`ifndef TLPQ_TX_TEST_SV
`define TLPQ_TX_TEST_SV

class tlpq_tx_test extends uvm_test;
    `uvm_component_utils(tlpq_tx_test)

    tlpq_mock_tx_adapter adapter;

    function new(string name = "tlpq_tx_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function pcie_tl_mem_tlp make_mem_write(
        string name, bit [15:0] requester_id, bit [9:0] tag,
        bit [31:0] address, input bit [31:0] payload_words[]);
        pcie_tl_mem_tlp request;

        request = pcie_tl_mem_tlp::type_id::create(name);
        request.kind = TLP_MEM_WR;
        request.fmt = FMT_3DW_WITH_DATA;
        request.type_f = TLP_TYPE_MEM_WR;
        request.length = payload_words.size();
        request.requester_id = requester_id;
        request.tag = tag;
        request.addr = {32'h0, address};
        request.first_be = 4'hf;
        request.last_be = 4'hf;
        request.is_64bit = 0;
        request.payload = new[payload_words.size() * 4];
        foreach (payload_words[i]) begin
            request.payload[i*4+0] = payload_words[i][31:24];
            request.payload[i*4+1] = payload_words[i][23:16];
            request.payload[i*4+2] = payload_words[i][15:8];
            request.payload[i*4+3] = payload_words[i][7:0];
        end
        return request;
    endfunction

    function void expect_success(
        string check_name, tlpq_tx_sequence tx_seq);
        if (!tx_seq.success || tx_seq.reason != "")
            `uvm_fatal("TLPQ_TX_SUCCESS", $sformatf(
                "%s failed success=%0b reason='%s'",
                check_name, tx_seq.success, tx_seq.reason))
    endfunction

    function void expect_failure_without_writes(
        string check_name, tlpq_channel_e channel,
        tlpq_tx_sequence tx_seq, int unsigned expected_waits);
        int channel_key;

        channel_key = int'(channel);
        if (tx_seq.success || tx_seq.reason == "")
            `uvm_fatal("TLPQ_TX_FAILURE", $sformatf(
                "%s did not return failure with a reason", check_name))
        if (adapter.ready_wait_count[channel_key] != expected_waits ||
            adapter.data_word[channel_key].size() != 0 ||
            adapter.keep_write[channel_key].size() != 0 ||
            adapter.tuser_write[channel_key].size() != 0 ||
            adapter.ctrl_write[channel_key].size() != 0 ||
            adapter.event_kind[channel_key].size() != expected_waits)
            `uvm_fatal("TLPQ_TX_ZERO_WRITE", $sformatf(
                {"%s waits=%0d data=%0d keep=%0d tuser=%0d ctrl=%0d; ",
                 "expected no writes"}, check_name,
                adapter.ready_wait_count[channel_key],
                adapter.data_word[channel_key].size(),
                adapter.keep_write[channel_key].size(),
                adapter.tuser_write[channel_key].size(),
                adapter.ctrl_write[channel_key].size()))
    endfunction

    function void expect_trace(
        string check_name, tlpq_channel_e channel,
        input bit [31:0] expected_words[],
        input int unsigned expected_indices[],
        input bit [15:0] expected_keep[],
        input bit [2:0] expected_tuser[],
        input tlpq_mock_tx_ctrl_t expected_ctrl[],
        input string expected_event_kind[],
        int unsigned expected_waits);
        int channel_key;

        channel_key = int'(channel);
        if (adapter.ready_wait_count[channel_key] != expected_waits)
            `uvm_fatal("TLPQ_TX_READY", $sformatf(
                "%s ready waits got %0d expected %0d", check_name,
                adapter.ready_wait_count[channel_key], expected_waits))
        if (adapter.data_word[channel_key].size() != expected_words.size() ||
            adapter.data_word_index[channel_key].size() !=
                expected_indices.size())
            `uvm_fatal("TLPQ_TX_DATA_SIZE", $sformatf(
                "%s data/index size mismatch", check_name))
        foreach (expected_words[i]) begin
            if (adapter.data_word[channel_key][i] !== expected_words[i] ||
                adapter.data_word_index[channel_key][i] != expected_indices[i])
                `uvm_fatal("TLPQ_TX_DATA", $sformatf(
                    {"%s write[%0d] got index=%0d data=0x%08h ",
                     "expected index=%0d data=0x%08h"}, check_name, i,
                    adapter.data_word_index[channel_key][i],
                    adapter.data_word[channel_key][i], expected_indices[i],
                    expected_words[i]))
        end
        if (adapter.keep_write[channel_key].size() != expected_keep.size())
            `uvm_fatal("TLPQ_TX_KEEP_SIZE", {check_name,
                " keep trace size mismatch"})
        foreach (expected_keep[i]) begin
            if (adapter.keep_write[channel_key][i] !== expected_keep[i])
                `uvm_fatal("TLPQ_TX_KEEP", $sformatf(
                    "%s keep[%0d] got 0x%04h expected 0x%04h",
                    check_name, i, adapter.keep_write[channel_key][i],
                    expected_keep[i]))
        end
        if (adapter.tuser_write[channel_key].size() !=
            expected_tuser.size())
            `uvm_fatal("TLPQ_TX_TUSER_SIZE", {check_name,
                " TUSER trace size mismatch"})
        foreach (expected_tuser[i]) begin
            if (adapter.tuser_write[channel_key][i] !== expected_tuser[i])
                `uvm_fatal("TLPQ_TX_TUSER", $sformatf(
                    "%s TUSER[%0d] got 0x%01h expected 0x%01h",
                    check_name, i, adapter.tuser_write[channel_key][i],
                    expected_tuser[i]))
        end
        if (adapter.ctrl_write[channel_key].size() != expected_ctrl.size())
            `uvm_fatal("TLPQ_TX_CTRL_SIZE", {check_name,
                " control trace size mismatch"})
        foreach (expected_ctrl[i]) begin
            if (adapter.ctrl_write[channel_key][i] != expected_ctrl[i])
                `uvm_fatal("TLPQ_TX_CTRL", $sformatf(
                    {"%s ctrl[%0d] got sop/eop/valid=%0b/%0b/%0b ",
                     "expected %0b/%0b/%0b"}, check_name, i,
                    adapter.ctrl_write[channel_key][i].sop,
                    adapter.ctrl_write[channel_key][i].eop,
                    adapter.ctrl_write[channel_key][i].valid,
                    expected_ctrl[i].sop, expected_ctrl[i].eop,
                    expected_ctrl[i].valid))
        end
        if (adapter.event_kind[channel_key].size() !=
            expected_event_kind.size())
            `uvm_fatal("TLPQ_TX_EVENT_SIZE", {check_name,
                " callback event trace size mismatch"})
        foreach (expected_event_kind[i]) begin
            if (adapter.event_kind[channel_key][i] != expected_event_kind[i])
                `uvm_fatal("TLPQ_TX_EVENT", $sformatf(
                    "%s event[%0d] got %s expected %s", check_name, i,
                    adapter.event_kind[channel_key][i],
                    expected_event_kind[i]))
        end
    endfunction

    task run_tx(
        string name, tlpq_channel_e channel, bit [2:0] host_id,
        pcie_tl_tlp tlp, time timeout, output tlpq_tx_sequence tx_seq);
        tx_seq = tlpq_tx_sequence::type_id::create(name);
        tx_seq.tx_adapter = adapter;
        tx_seq.channel = channel;
        tx_seq.host_id = host_id;
        tx_seq.tlp = tlp;
        tx_seq.ready_timeout = timeout;
        tx_seq.start(null);
    endtask

    // Mutation caught: changing the one-chunk keep or final control flags.
    task check_12_dword_host_trace();
        bit [31:0] payload[];
        bit [31:0] expected_words[];
        int unsigned expected_indices[];
        bit [15:0] expected_keep[];
        bit [2:0] expected_tuser[];
        tlpq_mock_tx_ctrl_t expected_ctrl[];
        string expected_event_kind[];
        tlpq_tx_sequence tx_seq;

        payload = '{32'h1000_0000, 32'h1000_0001, 32'h1000_0002,
                    32'h1000_0003, 32'h1000_0004, 32'h1000_0005,
                    32'h1000_0006, 32'h1000_0007};
        expected_words = '{32'h0000_0000, 32'h0000_1000,
                           32'h1234_56ff, 32'h4000_0008,
                           32'h1000_0000, 32'h1000_0001,
                           32'h1000_0002, 32'h1000_0003,
                           32'h1000_0004, 32'h1000_0005,
                           32'h1000_0006, 32'h1000_0007};
        expected_indices = '{0, 1, 2, 3, 4, 5, 6, 7,
                             8, 9, 10, 11};
        expected_keep = '{16'h0fff};
        expected_tuser = '{3'h5};
        expected_ctrl = '{{sop:1, eop:1, valid:1}};
        expected_event_kind = '{"WAIT", "DATA", "DATA", "DATA",
                                "DATA", "DATA", "DATA", "DATA",
                                "DATA", "DATA", "DATA", "DATA",
                                "DATA", "KEEP", "TUSER", "CTRL"};

        adapter.reset_channel(TLPQ_HOST);
        run_tx("host_12dw", TLPQ_HOST, 3'h5,
               make_mem_write("host_12dw_tlp", 16'h1234, 10'h056,
                              32'h0000_1000, payload),
               100ns, tx_seq);
        expect_success("12-DWORD Host", tx_seq);
        expect_trace("12-DWORD Host", TLPQ_HOST, expected_words,
                     expected_indices, expected_keep, expected_tuser,
                     expected_ctrl, expected_event_kind, 1);
        `uvm_info("TLPQ_TX_EVIDENCE",
            {"12DW HOST: words=[pad,addr,request,DW0,payload0..7] ",
             "indices=0..11 keep=0x0fff tuser=5 ctrl=1/1/1 waits=1"},
            UVM_LOW)
    endtask

    // Mutation caught: skipping DWORD 16 or failing to restart register index 0.
    task check_20_dword_switch_trace();
        bit [31:0] payload[];
        bit [31:0] expected_words[];
        int unsigned expected_indices[];
        bit [15:0] expected_keep[];
        bit [2:0] expected_tuser[];
        tlpq_mock_tx_ctrl_t expected_ctrl[];
        string expected_event_kind[];
        tlpq_tx_sequence tx_seq;

        payload = '{32'h2000_0000, 32'h2000_0001, 32'h2000_0002,
                    32'h2000_0003, 32'h2000_0004, 32'h2000_0005,
                    32'h2000_0006, 32'h2000_0007, 32'h2000_0008,
                    32'h2000_0009, 32'h2000_000a, 32'h2000_000b,
                    32'h2000_000c, 32'h2000_000d, 32'h2000_000e,
                    32'h2000_000f};
        expected_words = '{32'h0000_0000, 32'h0000_2000,
                           32'h5678_9aff, 32'h4000_0010,
                           32'h2000_0000, 32'h2000_0001,
                           32'h2000_0002, 32'h2000_0003,
                           32'h2000_0004, 32'h2000_0005,
                           32'h2000_0006, 32'h2000_0007,
                           32'h2000_0008, 32'h2000_0009,
                           32'h2000_000a, 32'h2000_000b,
                           32'h2000_000c, 32'h2000_000d,
                           32'h2000_000e, 32'h2000_000f};
        expected_indices = '{0, 1, 2, 3, 4, 5, 6, 7,
                             8, 9, 10, 11, 12, 13, 14, 15,
                             0, 1, 2, 3};
        expected_keep = '{16'hffff, 16'h000f};
        expected_tuser = '{3'h2, 3'h2};
        expected_ctrl = '{{sop:1, eop:0, valid:1},
                          '{sop:0, eop:1, valid:1}};
        expected_event_kind = '{"WAIT",
                                "DATA", "DATA", "DATA", "DATA",
                                "DATA", "DATA", "DATA", "DATA",
                                "DATA", "DATA", "DATA", "DATA",
                                "DATA", "DATA", "DATA", "DATA",
                                "KEEP", "TUSER", "CTRL", "WAIT",
                                "DATA", "DATA", "DATA", "DATA",
                                "KEEP", "TUSER", "CTRL"};

        adapter.reset_channel(TLPQ_SWITCH);
        run_tx("switch_20dw", TLPQ_SWITCH, 3'h2,
               make_mem_write("switch_20dw_tlp", 16'h5678, 10'h09a,
                              32'h0000_2000, payload),
               100ns, tx_seq);
        expect_success("20-DWORD Switch", tx_seq);
        expect_trace("20-DWORD Switch", TLPQ_SWITCH, expected_words,
                     expected_indices, expected_keep, expected_tuser,
                     expected_ctrl, expected_event_kind, 2);
        `uvm_info("TLPQ_TX_EVIDENCE",
            {"20DW SWITCH: source=0..19 contiguous; indices=0..15,0..3 ",
             "keep=0xffff,0x000f tuser=2,2 ctrl=1/0/1,0/1/1 waits=2"},
            UVM_LOW)
    endtask

    // Mutation caught: selecting one shared register/event stream for both channels.
    task check_channel_isolation();
        bit [31:0] payload[];
        bit [31:0] expected_words[];
        int unsigned expected_indices[];
        bit [15:0] expected_keep[];
        bit [2:0] expected_tuser[];
        tlpq_mock_tx_ctrl_t expected_ctrl[];
        string expected_event_kind[];
        tlpq_tx_sequence tx_seq;
        int switch_key;

        switch_key = int'(TLPQ_SWITCH);
        payload = '{32'h3000_0000, 32'h3000_0001, 32'h3000_0002,
                    32'h3000_0003, 32'h3000_0004, 32'h3000_0005,
                    32'h3000_0006, 32'h3000_0007};
        expected_words = '{32'h0000_0000, 32'h0000_3000,
                           32'h1111_11ff, 32'h4000_0008,
                           32'h3000_0000, 32'h3000_0001,
                           32'h3000_0002, 32'h3000_0003,
                           32'h3000_0004, 32'h3000_0005,
                           32'h3000_0006, 32'h3000_0007};
        expected_indices = '{0, 1, 2, 3, 4, 5, 6, 7,
                             8, 9, 10, 11};
        expected_keep = '{16'h0fff};
        expected_tuser = '{3'h1};
        expected_ctrl = '{{sop:1, eop:1, valid:1}};
        expected_event_kind = '{"WAIT", "DATA", "DATA", "DATA",
                                "DATA", "DATA", "DATA", "DATA",
                                "DATA", "DATA", "DATA", "DATA",
                                "DATA", "KEEP", "TUSER", "CTRL"};
        adapter.reset_channel(TLPQ_HOST);
        adapter.reset_channel(TLPQ_SWITCH);
        run_tx("isolated_host", TLPQ_HOST, 3'h1,
               make_mem_write("isolated_host_tlp", 16'h1111, 10'h011,
                              32'h0000_3000, payload),
               100ns, tx_seq);
        expect_success("isolated Host", tx_seq);
        expect_trace("isolated Host", TLPQ_HOST, expected_words,
                     expected_indices, expected_keep, expected_tuser,
                     expected_ctrl, expected_event_kind, 1);
        if (adapter.data_word[switch_key].size() != 0 ||
            adapter.keep_write[switch_key].size() != 0 ||
            adapter.tuser_write[switch_key].size() != 0 ||
            adapter.ctrl_write[switch_key].size() != 0 ||
            adapter.ready_wait_count[switch_key] != 0)
            `uvm_fatal("TLPQ_TX_ISOLATION",
                       "Host send changed the Switch callback stream")
        run_tx("isolated_switch", TLPQ_SWITCH, 3'h1,
               make_mem_write("isolated_switch_tlp", 16'h1111, 10'h011,
                              32'h0000_3000, payload),
               100ns, tx_seq);
        expect_success("isolated Switch", tx_seq);
        expect_trace("isolated Host after Switch", TLPQ_HOST, expected_words,
                     expected_indices, expected_keep, expected_tuser,
                     expected_ctrl, expected_event_kind, 1);
        expect_trace("isolated Switch", TLPQ_SWITCH, expected_words,
                     expected_indices, expected_keep, expected_tuser,
                     expected_ctrl, expected_event_kind, 1);
        `uvm_info("TLPQ_TX_EVIDENCE",
            {"CHANNEL ISOLATION: identical 12DW trace retained independently ",
             "for HOST and SWITCH callback streams"}, UVM_LOW)
    endtask

    // Mutation caught: removing the per-channel transaction lock allows the
    // second Host send to enter WAIT and commit while the first is paused.
    task check_same_channel_serialization();
        bit [31:0] first_payload[];
        bit [31:0] second_payload[];
        bit [31:0] expected_words[];
        int unsigned expected_indices[];
        bit [15:0] expected_keep[];
        bit [2:0] expected_tuser[];
        tlpq_mock_tx_ctrl_t expected_ctrl[];
        string expected_event_kind[];
        tlpq_tx_sequence first_seq;
        tlpq_tx_sequence second_seq;
        bit first_done;
        bit second_done;
        int host_key;

        host_key = int'(TLPQ_HOST);
        first_payload = '{32'ha0a0_0001};
        second_payload = '{32'hb0b0_0002};
        expected_words = '{32'h0000_0000, 32'h0000_6000,
                           32'haaaa_0aff, 32'h4000_0001,
                           32'ha0a0_0001,
                           32'h0000_0000, 32'h0000_7000,
                           32'hbbbb_0bff, 32'h4000_0001,
                           32'hb0b0_0002};
        expected_indices = '{0,1,2,3,4, 0,1,2,3,4};
        expected_keep = '{16'h001f, 16'h001f};
        expected_tuser = '{3'h1, 3'h2};
        expected_ctrl = '{{sop:1, eop:1, valid:1},
                          '{sop:1, eop:1, valid:1}};
        expected_event_kind = '{"WAIT", "DATA", "DATA", "DATA", "DATA",
                                "DATA", "KEEP", "TUSER", "CTRL",
                                "WAIT", "DATA", "DATA", "DATA", "DATA",
                                "DATA", "KEEP", "TUSER", "CTRL"};

        adapter.reset_channel(TLPQ_HOST);
        adapter.block_ready_wait(TLPQ_HOST, 1);
        first_done = 0;
        second_done = 0;
        fork
            begin
                run_tx("serialized_first", TLPQ_HOST, 3'h1,
                    make_mem_write("serialized_first_tlp", 16'haaaa,
                                   10'h00a, 32'h0000_6000,
                                   first_payload),
                    100ns, first_seq);
                first_done = 1;
            end
        join_none
        wait (adapter.ready_wait_count[host_key] == 1);
        fork
            begin
                run_tx("serialized_second", TLPQ_HOST, 3'h2,
                    make_mem_write("serialized_second_tlp", 16'hbbbb,
                                   10'h00b, 32'h0000_7000,
                                   second_payload),
                    100ns, second_seq);
                second_done = 1;
            end
        join_none
        #(1ns);
        if (adapter.ready_wait_count[host_key] != 1 ||
            adapter.data_word[host_key].size() != 0 ||
            adapter.ctrl_write[host_key].size() != 0 || second_done)
            `uvm_fatal("TLPQ_TX_SAME_CHANNEL_INTERLEAVE",
                {"second Host transaction entered the register stream while ",
                 "the first transaction was paused"})
        adapter.release_ready_wait(TLPQ_HOST);
        wait (first_done && second_done);
        expect_success("serialized first Host", first_seq);
        expect_success("serialized second Host", second_seq);
        expect_trace("same-channel serialized Host", TLPQ_HOST,
                     expected_words, expected_indices, expected_keep,
                     expected_tuser, expected_ctrl, expected_event_kind, 2);
    endtask

    // Mutation caught: replacing independent Host/Switch locks with one global
    // lock prevents Switch progress while a Host ready wait is blocked.
    task check_cross_channel_concurrency();
        bit [31:0] host_payload[];
        bit [31:0] switch_payload[];
        tlpq_tx_sequence host_seq;
        tlpq_tx_sequence switch_seq;
        bit host_done;
        bit switch_done;
        int host_key;
        int switch_key;

        host_key = int'(TLPQ_HOST);
        switch_key = int'(TLPQ_SWITCH);
        host_payload = '{32'hc0c0_0003};
        switch_payload = '{32'hd0d0_0004};
        adapter.reset_channel(TLPQ_HOST);
        adapter.reset_channel(TLPQ_SWITCH);
        adapter.block_ready_wait(TLPQ_HOST, 1);
        host_done = 0;
        switch_done = 0;
        fork
            begin
                run_tx("concurrent_host", TLPQ_HOST, 3'h3,
                    make_mem_write("concurrent_host_tlp", 16'hcccc,
                                   10'h00c, 32'h0000_8000,
                                   host_payload),
                    100ns, host_seq);
                host_done = 1;
            end
        join_none
        wait (adapter.ready_wait_count[host_key] == 1);
        fork
            begin
                run_tx("concurrent_switch", TLPQ_SWITCH, 3'h4,
                    make_mem_write("concurrent_switch_tlp", 16'hdddd,
                                   10'h00d, 32'h0000_9000,
                                   switch_payload),
                    100ns, switch_seq);
                switch_done = 1;
            end
        join_none
        #(1ns);
        if (!switch_done)
            `uvm_fatal("TLPQ_TX_CROSS_CHANNEL_BLOCK",
                "blocked Host transaction prevented Switch progress")
        if (host_done || adapter.data_word[host_key].size() != 0 ||
            !switch_seq.success ||
            adapter.ready_wait_count[switch_key] != 1 ||
            adapter.ctrl_write[switch_key].size() != 1)
            `uvm_fatal("TLPQ_TX_CROSS_CHANNEL_CONCURRENCY",
                "Switch did not complete independently of the blocked Host")
        adapter.release_ready_wait(TLPQ_HOST);
        wait (host_done);
        expect_success("concurrent Host", host_seq);
        expect_success("concurrent Switch", switch_seq);
    endtask

    // Mutation caught: writing data before the selected channel reports ready.
    task check_delayed_ready();
        bit [31:0] payload[];
        tlpq_tx_sequence tx_seq;
        time start_time;
        int host_key;

        host_key = int'(TLPQ_HOST);
        payload = '{32'h4000_0000, 32'h4000_0001, 32'h4000_0002,
                    32'h4000_0003, 32'h4000_0004, 32'h4000_0005,
                    32'h4000_0006, 32'h4000_0007};
        adapter.reset_channel(TLPQ_HOST);
        start_time = $time;
        adapter.set_ready_at(TLPQ_HOST, start_time + 70ns);
        fork
            run_tx("delayed_ready", TLPQ_HOST, 3'h6,
                   make_mem_write("delayed_ready_tlp", 16'h2222, 10'h022,
                                  32'h0000_4000, payload),
                   100ns, tx_seq);
        join_none
        #(69ns);
        if (adapter.data_word[host_key].size() != 0 ||
            adapter.keep_write[host_key].size() != 0 ||
            adapter.tuser_write[host_key].size() != 0 ||
            adapter.ctrl_write[host_key].size() != 0)
            `uvm_fatal("TLPQ_TX_EARLY_WRITE",
                       "TX callbacks wrote while ready was low")
        wait fork;
        expect_success("70 ns delayed ready", tx_seq);
        if (adapter.data_write_time[host_key].size() == 0 ||
            adapter.data_write_time[host_key][0] != start_time + 70ns)
            `uvm_fatal("TLPQ_TX_READY_TIME", $sformatf(
                "first write at %0t, expected %0t",
                adapter.data_write_time[host_key][0], start_time + 70ns))
        `uvm_info("TLPQ_TX_EVIDENCE",
            "DELAYED READY: zero writes through 69ns; first data write at 70ns",
            UVM_LOW)
    endtask

    // Mutation caught: continuing to data/keep/TUSER/control after ready timeout.
    task check_ready_timeout();
        bit [31:0] payload[];
        tlpq_tx_sequence tx_seq;

        payload = '{32'h5000_0000, 32'h5000_0001, 32'h5000_0002,
                    32'h5000_0003, 32'h5000_0004, 32'h5000_0005,
                    32'h5000_0006, 32'h5000_0007};
        adapter.reset_channel(TLPQ_SWITCH);
        adapter.set_force_timeout(TLPQ_SWITCH, 1);
        run_tx("ready_timeout", TLPQ_SWITCH, 3'h3,
               make_mem_write("ready_timeout_tlp", 16'h3333, 10'h033,
                              32'h0000_5000, payload),
               25ns, tx_seq);
        expect_failure_without_writes(
            "ready timeout", TLPQ_SWITCH, tx_seq, 1);
        `uvm_info("TLPQ_TX_EVIDENCE",
            {"READY TIMEOUT: one SWITCH wait expired at 25ns; ",
             "data/keep/tuser/control writes=0"}, UVM_LOW)
    endtask

    // Mutations caught: rolling back an already committed first chunk,
    // writing any part of a timed-out second chunk, reporting the wrong
    // source offset, or retaining the channel lock after failure.
    task check_second_chunk_timeout_contract();
        bit [31:0] payload[];
        bit [31:0] next_payload[];
        bit [31:0] expected_prefix[];
        tlpq_tx_sequence partial_seq;
        tlpq_tx_sequence next_seq;
        bit next_done;
        int host_key;

        host_key = int'(TLPQ_HOST);
        payload = '{32'h6000_0000, 32'h6000_0001, 32'h6000_0002,
                    32'h6000_0003, 32'h6000_0004, 32'h6000_0005,
                    32'h6000_0006, 32'h6000_0007, 32'h6000_0008,
                    32'h6000_0009, 32'h6000_000a, 32'h6000_000b,
                    32'h6000_000c, 32'h6000_000d, 32'h6000_000e,
                    32'h6000_000f};
        expected_prefix = '{32'h0000_0000, 32'h0000_a000,
                            32'heeee_0eff, 32'h4000_0010,
                            32'h6000_0000, 32'h6000_0001,
                            32'h6000_0002, 32'h6000_0003,
                            32'h6000_0004, 32'h6000_0005,
                            32'h6000_0006, 32'h6000_0007,
                            32'h6000_0008, 32'h6000_0009,
                            32'h6000_000a, 32'h6000_000b};
        adapter.reset_channel(TLPQ_HOST);
        adapter.script_ready_result(TLPQ_HOST, 1'b1);
        adapter.script_ready_result(TLPQ_HOST, 1'b0);
        run_tx("second_chunk_timeout", TLPQ_HOST, 3'h5,
               make_mem_write("second_chunk_timeout_tlp", 16'heeee,
                              10'h00e, 32'h0000_a000, payload),
               25ns, partial_seq);
        if (partial_seq.success ||
            partial_seq.reason !=
                "TLPQ TX channel 0 ready timeout at DWORD 16" ||
            adapter.ready_wait_count[host_key] != 2 ||
            adapter.data_word[host_key].size() != 16 ||
            adapter.keep_write[host_key].size() != 1 ||
            adapter.keep_write[host_key][0] != 16'hffff ||
            adapter.tuser_write[host_key].size() != 1 ||
            adapter.tuser_write[host_key][0] != 3'h5 ||
            adapter.ctrl_write[host_key].size() != 1 ||
            !adapter.ctrl_write[host_key][0].sop ||
            adapter.ctrl_write[host_key][0].eop ||
            !adapter.ctrl_write[host_key][0].valid)
            `uvm_fatal("TLPQ_TX_PARTIAL_TIMEOUT",
                "second-chunk timeout violated the committed-prefix contract")
        foreach (expected_prefix[i]) begin
            if (adapter.data_word[host_key][i] !== expected_prefix[i] ||
                adapter.data_word_index[host_key][i] != i)
                `uvm_fatal("TLPQ_TX_PARTIAL_PREFIX",
                    $sformatf("committed prefix DWORD[%0d] diverged", i))
        end
        if (adapter.event_kind[host_key].size() != 21 ||
            adapter.event_kind[host_key][19] != "CTRL" ||
            adapter.event_kind[host_key][20] != "WAIT")
            `uvm_fatal("TLPQ_TX_FAILED_CHUNK_WRITES",
                "failed second chunk performed callbacks after its ready wait")

        next_payload = '{32'h7000_0001};
        next_done = 0;
        fork
            begin
                run_tx("after_partial_timeout", TLPQ_HOST, 3'h6,
                    make_mem_write("after_partial_timeout_tlp", 16'hffff,
                                   10'h00f, 32'h0000_b000,
                                   next_payload),
                    25ns, next_seq);
                next_done = 1;
            end
            begin
                #(100ns);
                if (!next_done)
                    `uvm_fatal("TLPQ_TX_LOCK_RELEASE",
                        "channel lock remained held after second-chunk timeout")
            end
        join_any
        disable fork;
        expect_success("send after partial timeout", next_seq);
        if (adapter.event_kind[host_key][21] != "WAIT" ||
            adapter.data_word[host_key].size() != 21 ||
            adapter.keep_write[host_key].size() != 2 ||
            adapter.tuser_write[host_key].size() != 2 ||
            adapter.ctrl_write[host_key].size() != 2)
            `uvm_fatal("TLPQ_TX_POST_TIMEOUT_TRACE",
                "next transaction did not follow the failed wait cleanly")
    endtask

    // Mutation caught: invoking any register callback after encode rejects null.
    task check_encode_failure();
        tlpq_tx_sequence tx_seq;

        adapter.reset_channel(TLPQ_HOST);
        run_tx("null_encode", TLPQ_HOST, 3'h4, null, 100ns, tx_seq);
        expect_failure_without_writes(
            "null encode", TLPQ_HOST, tx_seq, 0);
        `uvm_info("TLPQ_TX_EVIDENCE",
            {"ENCODE FAILURE: null TLP failed before ready; ",
             "data/keep/tuser/control writes=0"}, UVM_LOW)
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        adapter = tlpq_mock_tx_adapter::type_id::create("adapter");
        check_12_dword_host_trace();
        check_20_dword_switch_trace();
        check_channel_isolation();
        check_same_channel_serialization();
        check_cross_channel_concurrency();
        check_delayed_ready();
        check_ready_timeout();
        check_second_chunk_timeout_contract();
        check_encode_failure();
        phase.drop_objection(this);
    endtask
endclass

`endif
