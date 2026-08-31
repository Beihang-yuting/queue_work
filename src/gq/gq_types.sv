`ifndef GQ_TYPES_SV
`define GQ_TYPES_SV

typedef bit [63:0] gq_addr_t;
typedef bit [31:0] gq_raw_ptr_t;
typedef longint unsigned gq_logical_seq_t;

typedef enum bit { GQ_TX, GQ_RX } gq_role_e;
typedef enum bit { GQ_POLL, GQ_IRQ } gq_wait_mode_e;
typedef enum bit { GQ_POLL_FIXED, GQ_POLL_ADAPTIVE } gq_poll_policy_e;
typedef enum bit { GQ_RX_EXPLICIT_REFILL, GQ_RX_AUTO_RECYCLE } gq_rx_slot_mode_e;
typedef enum bit { GQ_LITTLE_ENDIAN, GQ_BIG_ENDIAN } gq_byte_order_e;
typedef enum int { GQ_OK, GQ_RESOURCE_ERROR, GQ_ABORTED_BY_RESET } gq_status_e;
typedef enum int { GQ_WAKE_CANCELLED, GQ_WAKE_POLL, GQ_WAKE_IRQ,
                   GQ_WAKE_WATCHDOG, GQ_WAKE_NEW_WORK } gq_wakeup_e;

function automatic bit gq_is_pow2(int unsigned value);
    return value >= 2 && ((value & (value - 1)) == 0);
endfunction

function automatic bit gq_phase(gq_logical_seq_t seq, int unsigned depth);
    if (depth == 0)
        return 1;
    return ((seq / depth) & 1) == 0;
endfunction

function automatic string gq_queue_key(gq_role_e role, int unsigned queue_id);
    return $sformatf("%s_%0d", role == GQ_TX ? "tx" : "rx", queue_id);
endfunction

`endif
