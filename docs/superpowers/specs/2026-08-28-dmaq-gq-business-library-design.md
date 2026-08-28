# DMAQ Reuse of the Generic Queue Library

**Date:** 2026-08-28
**Status:** Approved in design discussion; pending review of this written specification

## 1. Purpose

Add an independent `dmaq` SystemVerilog/UVM business library that reproduces
the DMA queue behavior visible in the EMP firmware while reusing the existing
generic queue lifecycle. The implementation covers the three EMP transfer
operations, exact descriptor layout, bit-15 phase wrap, polling completion,
timeout behavior, reset/cleanup, and a semantic register adapter.

The library must model only behavior established by the reference source. It
does not reproduce the EMP retry that writes an unchanged tail while waiting;
the approved contract publishes only when the logical tail advances.

## 2. Reference Sources

The design is based on:

- EMP DPU source archive on `10.11.10.53`:
  - path: `/home/ubuntu/Downloads/emp.zip`
  - SHA-256:
    `dbc70200efdab93a96522a5115c9b81059b01fc512d587026b9b69b9db130cae`
  - primary files: `emp/app/dpu/dmaq.c`, `dmaq.h`, `common.h`,
    `adapter.h`, `main.c`, and `register.h`
- Generic queue repository state:
  - branch: `feature/generic-queue-uvm`
  - design baseline: `32b4089504044643e9276069b5540a12a2db072e`
- Host-memory project:
  - URL: `https://github.com/Beihang-yuting/host_mem.git`
  - pinned commit:
    `3b9e000d5df4d10efbb3029f43605e0362e0caca`

The EMP archive contains a usable DMA descriptor and three synchronous transfer
paths, but its call to `dpu_setup_dmaq()` is commented out in `main.c`, its stop
function is compiled out, and it has no DMAQ IRQ handler. The UVM library treats
the descriptor and transfer behavior as the conformance source, supplies the
cleanup seam required by GQ, and labels IRQ support as an optional GQ extension
rather than an EMP-validated default.

## 3. Scope

### 3.1 In scope

- An independent `src/dmaq` package with no dependency on another business
  package.
- A depth-32 TX ring with exact 32-byte descriptors.
- EMP-compatible initial logical position 31 and first publication
  `16'h8000`.
- AF-to-Host, Host-to-AF, and Host-to-Host transfer operations.
- Explicit source/destination address, host ID, and raw BDF identity.
- EP and Switch helper functions for constructing the 16-bit BDF union value.
- Descriptor writeback completion through `USED`.
- Fixed polling every 10 ns and a 500 ns synchronous/final timeout.
- Optional IRQ, ACK, and watchdog behavior through existing GQ configuration.
- Reset, disable, late completion, cleanup, and leak-free lifetime behavior.
- Driver-conformance tests on `ubuntu@10.11.10.53` with VCS.

### 3.2 Out of scope

- Rewriting an unchanged tail while waiting for completion.
- Hard-coded DMAQ register addresses or a mandatory RAL/backdoor transport.
- Allocating, copying, or freeing source/destination business buffers.
- Inferring address validity or ownership from numeric address ranges.
- A scatter-gather list, chained DMA, partial transfer reporting, or byte-count
  completion not present in the EMP descriptor.
- Claiming the optional IRQ profile is exercised by the EMP DMAQ code.
- Enabling or modifying the EMP firmware itself.

## 4. Repository Structure and Dependencies

The new production and test surfaces are:

```text
src/dmaq/
|-- dmaq_pkg.sv
|-- dmaq_types.sv
|-- dmaq_tx_desc.sv
|-- dmaq_completion.sv
|-- dmaq_ptr_codec.sv
|-- dmaq_reg_adapter.sv
|-- dmaq_env.sv
`-- dmaq_sequences.sv

tb/
|-- dmaq_test_pkg.sv
|-- mocks/
|   |-- dmaq_mock_adapter.sv
|   `-- dmaq_mock_dut.sv
`-- tests/
    |-- dmaq_desc_test.sv
    |-- dmaq_sequence_test.sv
    `-- dmaq_driver_conformance_test.sv
```

Dependency direction is:

```text
host_mem -> gq -> dmaq
```

`dmaq_pkg` must not import Mailbox, MSGQ, CMDQ, TLPQ, or PCIe packages. The
Makefile and remote runner select `LIBS=dmaq TEST_SUITE=dmaq` independently.
All repository-owned HDL files use `.sv`; no `.svh` file is added.

## 5. Generic GQ Initial Logical Position

`gq_queue_cfg` gains:

```systemverilog
gq_logical_seq_t initial_logical_seq;
```

The default is zero. Validation requires `initial_logical_seq < depth` so the
configured starting point lies in the first physical ring epoch. Engine
initialization and every completed reset set both logical head and logical tail
to this value. Outstanding count remains zero because head equals tail.

Every existing business retains the default zero and therefore keeps its
current slot, pointer, diagnostic, and reset behavior. DMAQ sets the value to
`DMAQ_DEPTH-1`, which is 31. The existing physical slot expression
`logical_seq % depth` then selects slot 31 for the first descriptor. Advancing
from logical tail 31 to 32 produces index 0 with phase 1.

The extension applies consistently to submission, completion scanning,
diagnostics, timeout identity, reset state, and public head/tail accessors.

## 6. Public DMAQ Types

Constants are:

```systemverilog
localparam int unsigned DMAQ_DEPTH      = 32;
localparam int unsigned DMAQ_DESC_BYTES = 32;
localparam bit [15:0] DMAQ_DESC_AVAIL   = 16'h0001;
localparam bit [15:0] DMAQ_DESC_USED    = 16'h0002;
```

Operations and endpoint roles are:

```systemverilog
typedef enum int {
    DMAQ_AF_TO_HOST,
    DMAQ_HOST_TO_AF,
    DMAQ_HOST_TO_HOST
} dmaq_operation_e;

typedef enum bit {
    DMAQ_ENDPOINT_AF,
    DMAQ_ENDPOINT_HOST
} dmaq_endpoint_role_e;
```

A transaction endpoint carries a role, 64-bit address, 16-bit host ID, and the
raw 16-bit BDF union value. The role is transaction metadata and is not packed
into the hardware descriptor. Operation validation requires:

| Operation | Source role | Destination role |
| --- | --- | --- |
| `DMAQ_AF_TO_HOST` | AF | Host |
| `DMAQ_HOST_TO_AF` | Host | AF |
| `DMAQ_HOST_TO_HOST` | Host | Host |

The EP BDF helper packs function number in bits `[3:0]`, virtual-function
number in `[11:4]`, virtual-function-valid in bit 12, and clears bits `[15:13]`.
The Switch helper preserves the supplied 16-bit BDF. The descriptor stores only
the resulting raw value because the EMP wire union has no separate mode bit.

`dmaq_hw_cfg_t` carries semantic queue metadata required by a concrete adapter:
32-bit queue HID, 16-bit queue BDF, MSI-X index, and MSI-X-valid. No register
address is part of this type.

## 7. Exact Descriptor Contract

`dmaq_tx_desc` derives from `gq_desc_base` and uses this packed little-endian
layout:

| Offset | Size | Field |
| ---: | ---: | --- |
| `0x00` | 2 | flags |
| `0x02` | 2 | destination BDF raw |
| `0x04` | 2 | destination host ID |
| `0x06` | 2 | destination length |
| `0x08` | 8 | destination address |
| `0x10` | 8 | source address |
| `0x18` | 2 | source BDF raw |
| `0x1a` | 2 | source host ID |
| `0x1c` | 2 | source length |
| `0x1e` | 2 | reserved, always zero |

`prepare()` validates the endpoint-role pair and a transfer length in
`1..65535`. Source and destination lengths are identical. The descriptor owns
no business allocation; the source and destination addresses remain borrowed
from the caller.

`mark_available()` writes `AVAIL=1,USED=0`. `unpack()` permits only the flags
field to change and rejects mutation of BDF, host ID, length, address, or
reserved fields. `is_complete()` requires `USED=1`. `parse_completion()`
triggers a persistent descriptor completion event and returns no payload.

## 8. Pointer and Completion Strategies

`dmaq_ptr_codec` uses the existing generic index/phase codec with index bits
`[14:0]` and phase bit 15:

```text
raw[14:0] = logical_tail % 32
raw[15]   = (logical_tail / 32) & 1
raw[31:16]= 0
```

With initial head/tail 31, the first descriptor is slot 31 and the first
published tail is `16'h8000`. Subsequent publications are `16'h8001` through
`16'h801f`; the next wrap returns to `16'h0000`.

`dmaq_completion` derives from `gq_desc_writeback_completion`. It reads pending
descriptors in logical order and returns only a contiguous `USED` count. A
writeback with corrupted stable fields is not retired.

## 9. Environment and Register Adapter

The standard `dmaq_env_cfg::add_dmaq()` creates exactly one TX queue per
environment/adapter instance. It installs:

- depth 32 and descriptor size 32;
- `initial_logical_seq=31`;
- `dmaq_ptr_codec`;
- `dmaq_completion`;
- fixed Poll with min/max interval 10 ns;
- polling backoff factor 1;
- completion timeout 500 ns;
- no IRQ watchdog in the standard EMP profile.

A second queue is rejected before changing the existing queue or adapter
metadata. Multiple rings require independent environment/adapter instances or
a future explicitly queue-indexed hardware metadata design.

`dmaq_reg_adapter` exposes semantic callbacks:

```systemverilog
reset_dmaq(queue_id);
configure_dmaq_registers(queue_id, base, depth, desc_size, hw_cfg);
enable_dmaq(queue_id);
disable_dmaq(queue_id);
write_dmaq_tail(queue_id, tail);
wait_dmaq_irq(queue_id);
ack_dmaq_irq(queue_id);
```

Configuration order is reset, configure, enable. Publication rejects nonzero
upper tail bits and calls `write_dmaq_tail()` exactly once for each committed
logical-tail advance. Polling and timeout do not call it again. Disable is the
cancellation boundary for blocked register operations and cleanup.

Advanced users may build an explicit DMAQ `gq_queue_cfg` selecting IRQ plus a
nonzero watchdog while retaining the DMAQ pointer and completion strategies.
That path is a GQ extension and is tested separately from the standard EMP
profile.

## 10. Transfer Sequence and Result Semantics

`dmaq_transfer_sequence` submits exactly one descriptor and waits for its
persistent completion event. Public inputs are operation, source endpoint,
destination endpoint, transfer length, and completion timeout. The default
timeout is 500 ns.

Result status is one of:

- `DMAQ_RESULT_OK`: one descriptor committed and completed no later than the
  inclusive deadline;
- `DMAQ_RESULT_SUBMIT_ERROR`: validation or GQ submission failed;
- `DMAQ_RESULT_TIMEOUT`: completion was not observed by the inclusive deadline.

Deadline arbitration uses the same region-stable inclusive rule as CMDQ. A
late completion after sequence timeout remains owned by the engine and may be
retired normally. Timeout does not change head, tail, descriptor bytes, or
publish history. Reset and cleanup release engine ownership and unblock worker
activity without freeing caller-owned transfer buffers.

## 11. Verification

### 11.1 Directed descriptor tests

- Exact independent byte vectors for all three operations.
- EP and Switch BDF helper encodings.
- Length 1 and 65535 accepted; zero and 65536 rejected.
- Every stable field mutation rejected independently.
- `USED` completion event persists; no business allocation is owned.

### 11.2 Pointer and environment tests

- Initial head/tail 31 and outstanding zero.
- First slot 31 and first published tail `16'h8000`.
- Phase progression and wrap through the next `16'h0000`.
- Reset returns to 31 without affecting queues whose initial value is zero.
- Exact reset/configure/enable/disable callback ordering.
- Duplicate queue rejection and hardware metadata preservation.

### 11.3 Driver-conformance tests

- AF-to-Host, Host-to-AF, and Host-to-Host descriptor flows through a real GQ
  engine and a mock DMAQ device.
- Exactly one tail callback for each newly committed descriptor and no
  unchanged-tail write while waiting.
- Fixed 10 ns polling, completion before/at/after the 500 ns boundary, and
  deterministic result status.
- Optional IRQ, real/spurious IRQ ACK, watchdog query, reset race, blocked
  adapter operation cancellation, cleanup, and zero leaks.

### 11.4 Compatibility and static gates

- Independent DMAQ VCS package build.
- Existing GQ, Mailbox, MSGQ, CMDQ, and TLPQ non-SVT regressions on
  `ubuntu@10.11.10.53` through a Bash login shell.
- Recursive `.sv` layout enforcement and cross-business dependency scan.
- `git diff --check` and clean submodule pins.

## 12. Acceptance Criteria

DMAQ is complete for the established EMP capability when:

1. the exact descriptor and initial slot/tail behavior match this spec;
2. all three transfer operations complete through real GQ submission and
   writeback retirement;
3. no unchanged tail is written during completion waiting;
4. Poll, timeout, optional IRQ, reset, and cleanup tests have zero unexpected
   UVM warnings, errors, or fatals;
5. all existing business regressions remain green; and
6. documentation clearly distinguishes the EMP Poll default from optional GQ
   IRQ support.
