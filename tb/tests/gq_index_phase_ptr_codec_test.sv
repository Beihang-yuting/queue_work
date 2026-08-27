`ifndef GQ_INDEX_PHASE_PTR_CODEC_TEST_SV
`define GQ_INDEX_PHASE_PTR_CODEC_TEST_SV

class gq_index_phase_ptr_codec_test extends uvm_test;
    `uvm_component_utils(gq_index_phase_ptr_codec_test)

    function new(string name = "gq_index_phase_ptr_codec_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        gq_index_phase_ptr_codec codec;
        gq_index_phase_ptr_codec invalid_index_width;
        gq_index_phase_ptr_codec invalid_phase_before_index;
        gq_index_phase_ptr_codec invalid_phase_out_of_range;
        string reason;

        super.build_phase(phase);
        codec = new("codec", 15, 15);

        if (codec.encode_publish(0, 1, 32) != 32'h0000_0001)
            `uvm_error("PTR", "slot 1")
        if (codec.encode_publish(31, 32, 32) != 32'h0000_8000)
            `uvm_error("PTR", "first wrap")
        if (codec.encode_publish(63, 64, 32) != 32'h0000_0000)
            `uvm_error("PTR", "second wrap")
        if (codec.validate_depth(32768, reason) != 1)
            `uvm_error("PTR", reason)
        if (codec.validate_depth(65536, reason) != 0)
            `uvm_error("PTR", "index overflow accepted")

        invalid_index_width = new("invalid_index_width", 0, 15);
        if (invalid_index_width.validate_depth(32, reason) != 0)
            `uvm_error("PTR", "index_width=0 was accepted")

        invalid_phase_before_index = new("invalid_phase_before_index", 15, 14);
        if (invalid_phase_before_index.validate_depth(32, reason) != 0)
            `uvm_error("PTR", "phase_bit below index width was accepted")

        invalid_phase_out_of_range = new("invalid_phase_out_of_range", 15, 32);
        if (invalid_phase_out_of_range.validate_depth(32, reason) != 0)
            `uvm_error("PTR", "phase_bit outside raw pointer was accepted")
    endfunction
endclass

`endif
