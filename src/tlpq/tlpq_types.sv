`ifndef TLPQ_TYPES_SV
`define TLPQ_TYPES_SV

localparam int unsigned TLPQ_DEPTH        = 32;
localparam int unsigned TLPQ_DESC_BYTES   = 16;
localparam int unsigned TLPQ_BUFFER_BYTES = 128;

localparam bit [15:0] TLPQ_DESC_AVAIL = 16'h0001;
localparam bit [15:0] TLPQ_DESC_USED  = 16'h0002;

localparam int unsigned TLPQ_HOST_QUEUE_ID   = 0;
localparam int unsigned TLPQ_SWITCH_QUEUE_ID = 1;

typedef enum bit { TLPQ_HOST, TLPQ_SWITCH } tlpq_channel_e;

typedef struct packed {
    bit [3:0] host_id;
    bit [3:0] tlp_type;
    bit [7:0] primary_bus;
    bit [7:0] secondary_bus;
    bit [7:0] subordinate_bus;
} tlpq_route_metadata_t;

`endif
