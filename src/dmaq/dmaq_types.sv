`ifndef DMAQ_TYPES_SV
`define DMAQ_TYPES_SV

localparam int unsigned DMAQ_DEFAULT_DEPTH = 32;
localparam gq_logical_seq_t DMAQ_DEFAULT_INITIAL_LOGICAL_SEQ = 31;
localparam int unsigned DMAQ_DESC_BYTES = 32;
localparam time DMAQ_DEFAULT_POLL_INTERVAL = 10ns;
localparam time DMAQ_DEFAULT_COMPLETION_TIMEOUT = 500ns;
localparam bit [15:0] DMAQ_DESC_AVAIL = 16'h0001;
localparam bit [15:0] DMAQ_DESC_USED  = 16'h0002;

typedef enum int {DMAQ_AF_TO_HOST, DMAQ_HOST_TO_AF, DMAQ_HOST_TO_HOST}
    dmaq_operation_e;
typedef enum bit {DMAQ_ENDPOINT_AF, DMAQ_ENDPOINT_HOST}
    dmaq_endpoint_role_e;
typedef enum int {DMAQ_RESULT_OK, DMAQ_RESULT_SUBMIT_ERROR,
                  DMAQ_RESULT_TIMEOUT} dmaq_result_status_e;

typedef struct packed {
    dmaq_endpoint_role_e role;
    gq_addr_t            address;
    bit [15:0]           host_id;
    bit [15:0]           bdf_raw;
} dmaq_endpoint_t;

typedef struct packed {
    bit [31:0] queue_hid;
    bit [15:0] queue_bdf;
    bit [15:0] msix_index;
    bit        msix_valid;
} dmaq_hw_cfg_t;

function automatic bit [15:0] dmaq_ep_bdf(bit [3:0] function_number,
                                           bit [7:0] vf_number,
                                           bit vf_valid);
    return {3'b000, vf_valid, vf_number, function_number};
endfunction

function automatic bit [15:0] dmaq_switch_bdf(bit [15:0] raw_bdf);
    return raw_bdf;
endfunction

`endif
