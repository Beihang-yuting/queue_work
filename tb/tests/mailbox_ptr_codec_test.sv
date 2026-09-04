// tb/tests/mailbox_ptr_codec_test.sv: UVM 测试 mailbox_ptr_codec_test：验证对应队列组件的定向行为和接口契约。
`ifndef MAILBOX_PTR_CODEC_TEST_SV
`define MAILBOX_PTR_CODEC_TEST_SV

class mailbox_ptr_codec_test extends uvm_test;
    `uvm_component_utils(mailbox_ptr_codec_test)

    function new(string name = "mailbox_ptr_codec_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void expect_encoded(mailbox_ptr_codec codec,
                                 gq_logical_seq_t new_tail,
                                 int unsigned depth,
                                 gq_raw_ptr_t expected);
        gq_raw_ptr_t actual;

        actual = codec.encode_publish(new_tail, new_tail, depth);
        if (actual !== expected)
            `uvm_fatal("MAILBOX_PTR_ENCODE", $sformatf(
                "tail=%0d depth=%0d encoded=0x%08h expected=0x%08h",
                new_tail, depth, actual, expected))
    endfunction

    function void build_phase(uvm_phase phase);
        mailbox_ptr_codec codec;
        mailbox_ptr_codec installed_codec;
        mailbox_env_cfg env_cfg;
        gq_logical_seq_t completed_tail;
        string reason;

        super.build_phase(phase);
        codec = mailbox_ptr_codec::type_id::create("codec");

        expect_encoded(codec, 0,   256, 32'h0000_0000);
        expect_encoded(codec, 255, 256, 32'h0000_00ff);
        expect_encoded(codec, 256, 256, 32'h0000_8000);
        expect_encoded(codec, 511, 256, 32'h0000_80ff);
        expect_encoded(codec, 512, 256, 32'h0000_0000);

        if (!codec.decode_completion(32'h0000_8000, 255, 256,
                                     completed_tail) ||
            completed_tail != 256)
            `uvm_fatal("MAILBOX_PTR_DECODE",
                       "wrap pointer 0x8000 did not decode to logical tail 256")

        if (!codec.decode_completion(32'h0000_0000, 511, 256,
                                     completed_tail) ||
            completed_tail != 512)
            `uvm_fatal("MAILBOX_PTR_DECODE",
                       "second-wrap pointer 0x0000 did not decode to logical tail 512")

        if (codec.decode_completion(32'h0000_0100, 0, 256,
                                    completed_tail))
            `uvm_fatal("MAILBOX_PTR_DECODE",
                       "out-of-range ring index was accepted")

        env_cfg = mailbox_env_cfg::type_id::create("env_cfg");
        if (!$cast(installed_codec, env_cfg.ptr_codec) ||
            installed_codec == null)
            `uvm_fatal("MAILBOX_PTR_DEFAULT",
                       "mailbox environment did not install the hardware pointer codec")

        if (!env_cfg.add_rx(0, 32768, reason))
            `uvm_fatal("MAILBOX_DEPTH", {"depth 32768 was rejected: ", reason})
        if (env_cfg.add_tx(1, 65536, reason))
            `uvm_fatal("MAILBOX_DEPTH",
                       "depth 65536 was accepted even though bit 15 is the wrap bit")
    endfunction
endclass

`endif
