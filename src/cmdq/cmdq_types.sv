// src/cmdq/cmdq_types.sv: CMDQ 常量、目的端 ID、结果状态和硬件元数据类型。
`ifndef CMDQ_TYPES_SV
`define CMDQ_TYPES_SV

localparam int unsigned CMDQ_DEPTH        = 32;
localparam int unsigned CMDQ_DESC_BYTES   = 32;
localparam int unsigned CMDQ_BUFFER_BYTES = 256;

localparam bit [15:0] CMDQ_DESC_AVAIL = 16'h0001;
localparam bit [15:0] CMDQ_DESC_USED  = 16'h0002;
localparam bit [15:0] CMDQ_DST_FSE    = 16'h0002;
localparam bit [15:0] CMDQ_DST_PSTAT  = 16'h0003;

typedef enum int { CMDQ_RESULT_OK, CMDQ_RESULT_SUBMIT_ERROR,
                   CMDQ_RESULT_TIMEOUT, CMDQ_RESULT_PARSE_ERROR }
                 cmdq_result_status_e;

typedef struct packed {
    bit [7:0]  host_id;
    bit [15:0] function_id;
    bit [15:0] msix_index;
    bit        msix_valid;
} cmdq_hw_cfg_t;

`endif
