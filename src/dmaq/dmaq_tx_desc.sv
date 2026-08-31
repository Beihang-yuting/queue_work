`ifndef DMAQ_TX_DESC_SV
`define DMAQ_TX_DESC_SV

class dmaq_tx_desc extends gq_desc_base;
    `uvm_object_utils(dmaq_tx_desc)

    dmaq_operation_e operation;
    dmaq_endpoint_t  source;
    dmaq_endpoint_t  destination;
    int unsigned     transfer_length;
    bit [15:0]       flags;
    uvm_event        completion_event;

    protected bit              prepare_attempted;
    protected bit              prepared;
    protected dmaq_operation_e prepared_operation;
    protected dmaq_endpoint_t  prepared_source;
    protected dmaq_endpoint_t  prepared_destination;
    protected bit [15:0]       prepared_wire_length;
    protected bit [15:0]       prepared_reserved;

    function new(string name = "dmaq_tx_desc");
        super.new(name);
        operation = DMAQ_AF_TO_HOST;
        source = '0;
        destination = '0;
        transfer_length = 0;
        flags = 0;
        completion_event = new({name, "_completion_event"});
        prepare_attempted = 0;
        prepared = 0;
        prepared_operation = DMAQ_AF_TO_HOST;
        prepared_source = '0;
        prepared_destination = '0;
        prepared_wire_length = 0;
        prepared_reserved = 0;
    endfunction

    protected function bit valid_role_pair();
        case (operation)
            DMAQ_AF_TO_HOST:
                return source.role == DMAQ_ENDPOINT_AF &&
                       destination.role == DMAQ_ENDPOINT_HOST;
            DMAQ_HOST_TO_AF:
                return source.role == DMAQ_ENDPOINT_HOST &&
                       destination.role == DMAQ_ENDPOINT_AF;
            DMAQ_HOST_TO_HOST:
                return source.role == DMAQ_ENDPOINT_HOST &&
                       destination.role == DMAQ_ENDPOINT_HOST;
            default:
                return 0;
        endcase
    endfunction

    virtual function bit prepare();
        if (prepare_attempted)
            return 0;
        prepare_attempted = 1;
        if (!valid_role_pair() || transfer_length == 0 ||
            transfer_length > 16'hffff)
            return 0;

        flags = 0;
        prepared_operation = operation;
        prepared_source = source;
        prepared_destination = destination;
        prepared_wire_length = transfer_length[15:0];
        prepared_reserved = 0;
        prepared = 1;
        return 1;
    endfunction

    virtual function void mark_available(bit phase);
        flags = DMAQ_DESC_AVAIL;
    endfunction

    virtual function void pack(ref byte packed_data[]);
        bit [255:0] raw;

        raw = '0;
        raw[15:0] = flags;
        if (prepared) begin
            raw[31:16] = prepared_destination.bdf_raw;
            raw[47:32] = prepared_destination.host_id;
            raw[63:48] = prepared_wire_length;
            raw[127:64] = prepared_destination.address;
            raw[191:128] = prepared_source.address;
            raw[207:192] = prepared_source.bdf_raw;
            raw[223:208] = prepared_source.host_id;
            raw[239:224] = prepared_wire_length;
            raw[255:240] = prepared_reserved;
        end

        packed_data = new[DMAQ_DESC_BYTES];
        foreach (packed_data[i])
            packed_data[i] = raw[i * 8 +: 8];
    endfunction

    virtual function bit unpack(input byte packed_data[]);
        bit [255:0] raw;
        bit [15:0] decoded_flags;
        bit [15:0] decoded_destination_bdf;
        bit [15:0] decoded_destination_host_id;
        bit [15:0] decoded_destination_length;
        gq_addr_t decoded_destination_address;
        gq_addr_t decoded_source_address;
        bit [15:0] decoded_source_bdf;
        bit [15:0] decoded_source_host_id;
        bit [15:0] decoded_source_length;
        bit [15:0] decoded_reserved;

        if (!prepared || packed_data.size() != DMAQ_DESC_BYTES)
            return 0;

        raw = '0;
        foreach (packed_data[i])
            raw[i * 8 +: 8] = packed_data[i];
        decoded_flags = raw[15:0];
        decoded_destination_bdf = raw[31:16];
        decoded_destination_host_id = raw[47:32];
        decoded_destination_length = raw[63:48];
        decoded_destination_address = raw[127:64];
        decoded_source_address = raw[191:128];
        decoded_source_bdf = raw[207:192];
        decoded_source_host_id = raw[223:208];
        decoded_source_length = raw[239:224];
        decoded_reserved = raw[255:240];

        if (decoded_destination_bdf != prepared_destination.bdf_raw ||
            decoded_destination_host_id != prepared_destination.host_id ||
            decoded_destination_length != prepared_wire_length ||
            decoded_destination_address != prepared_destination.address ||
            decoded_source_address != prepared_source.address ||
            decoded_source_bdf != prepared_source.bdf_raw ||
            decoded_source_host_id != prepared_source.host_id ||
            decoded_source_length != prepared_wire_length ||
            decoded_reserved != prepared_reserved)
            return 0;

        flags = decoded_flags;
        return 1;
    endfunction

    virtual function bit is_complete(bit phase);
        return (flags & DMAQ_DESC_USED) != 0;
    endfunction

    virtual function bit parse_completion();
        if (!prepared || (flags & DMAQ_DESC_USED) == 0)
            return 0;
        completion_event.trigger();
        return 1;
    endfunction
endclass

`endif
