// src/msgq/msgq_types.sv: MSGQ 类型和格式配置枚举以及 EMP 几何参数常量。
`ifndef MSGQ_TYPES_SV
`define MSGQ_TYPES_SV

localparam int unsigned MSGQ_MAC_AGE_DEPTH       = 128;
localparam int unsigned MSGQ_MAC_AGE_ENTRY_BYTES = 16;
localparam int unsigned MSGQ_1588_EMP_DEPTH      = 32;
localparam int unsigned MSGQ_1588_LINUX_DEPTH    = 128;
localparam int unsigned MSGQ_1588_ENTRY_BYTES    = 8;

typedef enum int { MSGQ_MAC_AGE, MSGQ_1588, MSGQ_FSE, MSGQ_IACL,
                   MSGQ_EACL, MSGQ_VDPA, MSGQ_NOTIFY } msgq_kind_e;
typedef enum bit { MSGQ_PROFILE_EMP_ACTIVE,
                   MSGQ_PROFILE_LINUX_HEADER } msgq_format_profile_e;

`endif
