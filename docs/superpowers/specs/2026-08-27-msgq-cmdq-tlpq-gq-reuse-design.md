# MSGQ, CMDQ, and TLPQ Reuse of the Generic Queue Library

**Date:** 2026-08-27  
**Status:** Approved in design discussion; pending review of this written specification

## 1. Purpose

Extend `queue_work` so the DPU MSGQ, CMDQ, and TLPQ businesses reuse the
generic queue library without putting protocol knowledge into `gq`. Each
business is a separate SystemVerilog library with its own directory, package,
descriptor or entry types, completion strategy, pointer codec, environment
configuration, sequences, and register adapter.

TLP packet objects and PCIe transaction-layer encoding come from the associated
`pcie_work` project. Host memory continues to come from the associated
`host_mem` project.

The implementation will be checked against the queue setup, producer/consumer,
completion, wrap, and teardown behavior in the real DPU driver sources, not
only against isolated class unit tests.

## 2. Reference Sources

The design is based on these fixed references:

- Linux DPU driver on `10.11.10.53`:
  - path: `/home/ubuntu/wn/icpu-kernel-driver`
  - branch: `lance_net_mailbox`
  - commit: `f2c9cd66b6e6b972055efe094b6277c5e362958d`
- EMP DPU source archive on `10.11.10.53`:
  - path: `/home/ubuntu/Downloads/emp.zip`
  - SHA-256:
    `dbc70200efdab93a96522a5115c9b81059b01fc512d587026b9b69b9db130cae`
- PCIe transaction-layer project:
  - URL: `https://github.com/Beihang-yuting/pcie_work.git`
  - branch: `main`
  - pinned commit: `94930e1d69e7a059cd794eb08c5b2e97aa93dc27`
- Host-memory project:
  - URL: `https://github.com/Beihang-yuting/host_mem.git`
  - existing pinned commit:
    `3b9e000d5df4d10efbb3029f43605e0362e0caca`

The active EMP timestamp handler uses a depth-32 queue. The Linux header also
contains an unused depth-128 timestamp declaration. Queue depth remains a
validated configuration value; the provided active-EMP conformance profile
defaults to 32, while a user may configure 128 for the Linux-header variant.

## 3. Scope

### 3.1 In scope

- Generic GQ support for asynchronous completion queries.
- Generic GQ support for explicit-refill and auto-recycle RX slot lifecycles.
- Fixed and adaptive polling, IRQ completion detection, and IRQ watchdog
  fallback.
- A generic descriptor-writeback completion implementation.
- A generic index-plus-phase pointer codec base.
- Separate `msgq`, `cmdq`, and `tlpq` libraries.
- Concrete MSGQ MAC-age and 1588 timestamp entry parsing.
- Raw and user-extensible MSGQ structures for message formats not established
  by the reference business code.
- Complete CMDQ descriptor submission and result-buffer completion.
- Complete Host RX and Switch RX TLPQ rings.
- The separate Host/Switch TLP register-transmit channel used to send TLPs.
- TLP object and codec reuse from `pcie_work`.
- Semantic register adapter interfaces with no hard-coded register addresses.
- Driver-conformance tests and regression on the VCS host.

### 3.2 Out of scope

- Guessing concrete FSE, IACL, EACL, vDPA, or notify MSGQ payload semantics
  where the reference code lacks a complete producer/consumer path.
- Duplicating PCIe TLP transaction classes or the standard TLP codec in this
  repository.
- A TLP request-response policy engine, PCIe enumeration policy, BAR model, or
  configuration-space emulator. Callers may use `pcie_work` for those layers.
- Hard-coded DPU register addresses or a mandatory RAL/backdoor/PCIe access
  mechanism.
- Modifying `host_mem` or `pcie_work` internals as part of this feature.
- Reproducing incidental busy-loop timing or source-code defects from the C
  driver when they are not part of the hardware protocol.

## 4. Repository and Library Structure

The repository structure will be:

```text
queue_work/
|-- host_mem/                 # existing Git submodule
|-- pcie_work/                # new Git submodule, main@94930e1d...
|-- src/
|   |-- gq/
|   |   |-- gq_pkg.sv
|   |   `-- ...
|   |-- mailbox/
|   |   |-- mailbox_pkg.sv
|   |   `-- ...
|   |-- msgq/
|   |   |-- msgq_pkg.sv
|   |   `-- ...
|   |-- cmdq/
|   |   |-- cmdq_pkg.sv
|   |   `-- ...
|   `-- tlpq/
|       |-- tlpq_pkg.sv
|       `-- ...
`-- tb/
    |-- gq/
    |-- mailbox/
    |-- msgq/
    |-- cmdq/
    `-- tlpq/
```

Every business has one public package and its own namespace. No business
package depends on another business package. The dependency direction is:

```text
host_mem --------------------> gq
   |                            |---> mailbox
   |                            |---> msgq
   |                            |---> cmdq
   `----> pcie_work             `---> tlpq
               `--------------------> tlpq
```

`pcie_work` is registered in `.gitmodules` like `host_mem`, using branch
`main`, with the repository gitlink pinned to the reference commit. The build
compiles only the `pcie_tl_vip` sources needed by `pcie_tl_pkg`; the unrelated
SVT integration subtree is not part of the queue regression.

Compilation order is:

1. `host_mem_pkg`
2. the standalone `pcie_work` helper packages and `pcie_tl_if`
3. `pcie_tl_pkg`
4. `gq_pkg`
5. the selected business packages
6. their test packages and testbench top

## 5. SystemVerilog File Policy

All SystemVerilog source files created or maintained by this repository use
the `.sv` suffix, including package-included class files and tests. No new
project-owned `.svh` file is introduced. Standard external includes such as
`uvm_macros.svh`, and files owned by an associated submodule, remain external
dependencies and are not renamed or copied.

## 6. Generic GQ Extensions

### 6.1 Asynchronous completion query

The existing completion function becomes a task so a completion source can
perform a timed RAL, PCIe, or other adapter read. Its conceptual interface is:

```systemverilog
virtual task query_completed(
    host_mem_api mem,
    gq_hw_adapter adapter,
    gq_addr_t ring_base,
    gq_addr_t status_addr,
    int unsigned depth,
    int unsigned desc_size,
    gq_logical_seq_t logical_head,
    input gq_desc_base pending[$],
    output bit valid,
    output int unsigned completed_count);
```

`valid=0` means the completion state could not be sampled. The engine reports
the query failure and retires no descriptor. A valid count must not exceed
either the pending snapshot or the current outstanding count.

The engine does not hold its lifecycle state lock across this task. It uses the
existing epoch and completion-commit boundaries to discard stale results if a
reset or cleanup wins while the query is in flight.

Existing memory-only completion strategies implement a zero-time task. The
mailbox public completion type remains available and derives from or delegates
to the generic descriptor-writeback implementation.

### 6.2 Generic descriptor-writeback completion

`gq_desc_writeback_completion.sv` contains the protocol-independent behavior
currently embodied by mailbox completion:

1. read each pending physical descriptor in logical order;
2. call the pending descriptor's `unpack()`;
3. call its `is_complete(phase)`;
4. stop at the first incomplete or invalid descriptor;
5. return the contiguous completed count.

Mailbox, CMDQ, and TLPQ reuse this implementation. Their descriptor classes
remain responsible for protocol-specific stable-field checking and completion
ownership flags.

### 6.3 Generic pointer base

`gq_index_phase_ptr_codec.sv` provides configurable index and phase bit
placement. The DPU mailbox, CMDQ, and TLPQ business codecs use a 15-bit index
and bit 15 phase:

```text
raw[14:0] = logical_tail % depth
raw[15]   = (logical_tail / depth) & 1
raw[31:16]= 0
```

Each business still exports its own pointer codec type so its validation and
public API remain in the business package without creating cross-business
dependencies.

### 6.4 RX slot lifecycle

`gq_queue_cfg` gains an RX slot lifecycle setting:

- `GQ_RX_EXPLICIT_REFILL`, the default, rewrites a replacement descriptor and
  publishes a new tail after completion.
- `GQ_RX_AUTO_RECYCLE` advances the logical receive window without rewriting
  the ring entry and without publishing another tail.

Explicit refill is used by mailbox and TLPQ. Auto-recycle is used by MSGQ.
CMDQ is a TX queue and is unaffected.

For auto-recycle, initial activation still registers `depth-1` receive entry
objects, clears their fixed-size slots, and publishes the initial tail. After
`N` entries complete, the engine:

1. parses and reports the `N` completed objects;
2. retires their logical sequences;
3. creates `N` fresh logical receive objects for the rotating sentinel slots;
4. marks the new logical objects as hardware-visible without a memory rewrite
   or adapter publish;
5. restores the outstanding window to `depth-1`.

The profile supplies the fresh objects. Auto-recycle entries cannot own
separate receive buffers.

### 6.5 Refill publication granularity

`gq_refill_profile` gains a maximum refill batch setting. Zero means no limit.
TLPQ sets the limit to one so a burst of completions produces the same
one-descriptor-at-a-time tail progression as the reference driver. The engine
continues refill iterations until the configured high watermark is restored.
Mailbox keeps its existing batched behavior unless explicitly configured
otherwise. MSGQ auto-recycle does not publish refill tails.

### 6.6 Completion detection and timing

Completion detection and completion interpretation are separate:

```text
fixed/adaptive polling or IRQ wakeup
                  |
                  v
descriptor USED or MSGQ current pointer query
```

Every queue independently selects polling or IRQ mode. Business defaults are:

| Business | Driver behavior | Library default | Also supported |
| --- | --- | --- | --- |
| MSGQ MAC-age/1588 | MSI-X | IRQ | Poll |
| CMDQ | synchronous USED polling | Adaptive Poll | IRQ |
| TLPQ Host/Switch | MSI-X | IRQ | Poll |
| Mailbox | existing configuration | unchanged | Poll/IRQ |

IRQ mode waits for an adapter interrupt. A real IRQ is acknowledged before the
completion query. An IRQ watchdog may perform a completion query without an
ACK when no interrupt arrives, allowing a lost IRQ to be detected. A spurious
IRQ is acknowledged but retires nothing.

Timing fields are independent:

- `poll_min_interval`
- `poll_max_interval`
- `poll_backoff_factor`
- fixed or adaptive poll policy
- `irq_watchdog_interval`, where zero disables the watchdog
- `completion_timeout`, where zero disables a final completion deadline

Adaptive polling is deterministic:

```text
new work or completion progress: interval = poll_min_interval
idle query: interval = min(interval * factor, poll_max_interval)
```

A TX worker with no outstanding transaction waits for new-work notification
instead of polling. New work interrupts a pending long poll and restarts at the
minimum interval. Reset and cleanup also cancel a pending poll wait. RX polling
continues while the receive window is active and backs off while idle.

Suggested simulation defaults are:

| Queue | Detection | Poll min | Poll max | IRQ watchdog | Final timeout |
| --- | --- | ---: | ---: | ---: | ---: |
| CMDQ | adaptive poll | 10 ns | 100 ns | unused | 10 us |
| MSGQ | IRQ | 50 ns | 500 ns | 1 us | disabled |
| TLPQ | IRQ | 50 ns | 500 ns | 1 us | disabled |
| directed timing tests | fixed poll | 10 ns | 10 ns | per test | per test |

Validation rejects a zero minimum, a maximum below the minimum, a backoff
factor below one, and unequal fixed-policy bounds. A TX completion deadline
must exceed the maximum poll interval. A deadline below four maximum intervals
produces a configuration warning because it permits very few observations.

These values are simulation scheduling parameters, not a one-for-one mapping
of C busy loops or microsecond delays.

## 7. MSGQ Library

### 7.1 Files

`src/msgq/` contains:

- `msgq_pkg.sv`
- `msgq_types.sv`
- `msgq_entry_base.sv`
- `msgq_raw_entry.sv`
- `msgq_mac_age_entry.sv`
- `msgq_1588_entry.sv`
- `msgq_completion.sv`
- `msgq_ptr_codec.sv`
- `msgq_refill_profile.sv`
- `msgq_reg_adapter.sv`
- `msgq_env.sv`
- `msgq_sequences.sv`

### 7.2 Entry formats

MAC-age provides a concrete 16-byte entry matching
`struct msgq_mac_age_msg_s`:

- `hash_key_l`
- 29-bit `hash_key_h`
- 9-bit `mac_act_idx`
- reserved fields, which must be zero when strict validation is selected

1588 timestamp provides a concrete 8-byte entry:

- low 32 timestamp bits
- high 8 timestamp bits
- 16-bit timestamp tag
- 2-bit timestamp type
- a 4-bit source-port representation

The 4-bit source-port representation is a superset of the Linux header's
2-bit variant. A Linux-profile entry requires the upper two bits to be zero;
the active EMP profile accepts all four bits.

`msgq_raw_entry` preserves fixed-size bytes without assigning protocol fields.
FSE, IACL, EACL, vDPA, and notify queue kinds may be registered with a user
entry factory and explicit entry size, but receive no default concrete parser
or business-conformance claim.

### 7.3 Completion and auto-recycle

MSGQ has no descriptor `AVAIL/USED` ownership. Its completion source casts the
generic adapter to `msgq_reg_adapter`, calls the asynchronous
`read_current_ptr()`, validates the returned index, and computes:

```text
completed_count = (current_ptr - (logical_head % depth) + depth) % depth
```

The outstanding window is `depth-1`, so the count is unambiguous as long as
hardware does not overwrite a full unread lap. A current pointer equal to the
logical head index means zero progress, matching the driver. The available
register contract has no wrap bit and therefore cannot distinguish zero
progress from an entire overwritten lap; preventing that overflow is a system
service-latency requirement.

Initialization clears the ring, configures it, publishes `depth-1`, and then
uses auto-recycle. No tail is published after normal completion.

### 7.4 Register adapter

`msgq_reg_adapter` derives from `gq_hw_adapter` and translates generic calls to
semantic MSGQ callbacks. In addition to configure, disable, initial publish,
IRQ wait, and IRQ ACK, it exposes:

```systemverilog
virtual task read_msgq_current_ptr(
    int unsigned queue_id,
    output bit valid,
    output bit [15:0] current_ptr);
```

The adapter owns mapping from logical queue ID to MAC-age, timestamp, or a
future user-defined physical queue and owns all register addresses.

## 8. CMDQ Library

### 8.1 Files

`src/cmdq/` contains:

- `cmdq_pkg.sv`
- `cmdq_types.sv`
- `cmdq_tx_desc.sv`
- `cmdq_completion.sv`
- `cmdq_ptr_codec.sv`
- `cmdq_reg_adapter.sv`
- `cmdq_env.sv`
- `cmdq_sequences.sv`

### 8.2 Descriptor and buffers

CMDQ is a depth-32 TX ring with a 32-byte descriptor:

```text
u16 flags
u16 tx_buf_len
u64 tx_buf_addr
u16 dst_id
u16 rx_buf_len
u64 rx_buf_addr
u64 reserved
```

Each descriptor owns an independent 256-byte maximum TX buffer and 256-byte
RX/result buffer. Submission:

1. validates payload size;
2. allocates both buffers;
3. copies the raw request payload;
4. writes `AVAIL=1, USED=0`;
5. publishes the bit-15 phase tail.

Hardware may change `flags` and `rx_buf_len`. TX length/address, destination,
RX address, and reserved fields are stable and are checked during unpack.
Completion requires `USED=1`. The completed RX length must not exceed 256.
The result is copied into descriptor-owned dynamic bytes before host-memory
allocations are released.

The default business sequence submits one command and waits for its persistent
descriptor completion event, matching the synchronous driver flow. It returns
the copied result for query commands and never returns stale RX storage after a
timeout. Generic GQ batch submission remains available to advanced users but
is not the driver-conformance default.

The C driver's occasional repeat of the same doorbell while busy-waiting is a
transport recovery measure, not a change in descriptor ownership. Normal
conformance requires one successful publish. A concrete adapter may internally
retry a failed or non-linearized bus write without changing the GQ API, subject
to the existing publish/disable cancellation contract.

### 8.3 Register adapter

`cmdq_reg_adapter` exposes semantic configuration for base, depth, HID, FID,
MSI-X, reset, enable, disable, tail notify, IRQ wait, and IRQ ACK. It contains
no numerical address such as `0x1000`; the user implementation supplies that
mapping.

## 9. TLPQ Library and PCIe Association

### 9.1 Files

`src/tlpq/` contains:

- `tlpq_pkg.sv`
- `tlpq_types.sv`
- `tlpq_rx_desc.sv`
- `tlpq_completion.sv`
- `tlpq_refill_profile.sv`
- `tlpq_ptr_codec.sv`
- `tlpq_packet_bridge.sv`
- `tlpq_reg_adapter.sv`
- `tlpq_tx_reg_adapter.sv`
- `tlpq_env.sv`
- `tlpq_sequences.sv`

### 9.2 RX queues and descriptor

Host RX and Switch RX are independent GQ RX engines. Each defaults to:

- depth 32
- 16-byte descriptor
- 128-byte owned buffer
- `depth-1` initial descriptors
- explicit refill with maximum refill batch one
- bit-15 phase tail

The descriptor is:

```text
u16 flags
u16 buf_len
u64 buf_addr
u4  host_id
u4  type
u8  primary_bus
u8  secondary_bus
u8  subordinate_bus
```

Hardware may change flags, completed length, and routing metadata. Buffer
address is stable. Completion requires `USED=1`; parsing validates a nonzero
length that is sufficient for the indicated header and no greater than 128.

After parsing, the descriptor exposes:

- the routing metadata;
- copied raw DPU buffer bytes;
- a decoded `pcie_tl_pkg::pcie_tl_tlp` object.

Host and Switch have distinct queue IDs, engine state, adapters, IRQ waits,
heads, tails, and phase progression.

### 9.3 DPU packet bridge

The DPU receive buffer is not the same byte layout consumed by
`pcie_tl_codec.decode()`. The reference code treats every queue header slot as
four DWORDs and locates the common header at byte offset 12.

For a 3-DW TLP, the DPU layout is conceptually:

```text
[padding, DW2, DW1, DW0, payload...]
```

For a 4-DW TLP:

```text
[DW3, DW2, DW1, DW0, payload...]
```

`tlpq_packet_bridge` validates the DPU length, removes 3-DW padding, reverses
header DWORD order, performs the required per-DWORD byte ordering, and then
calls `pcie_tl_codec.decode()`. TX applies the inverse transformation after
`pcie_tl_codec.encode()`.

The bridge contains no independent PCIe header parser and produces no local
TLP transaction class. Golden-vector tests, not only round trips, establish
the exact byte order against the C structures.

### 9.4 Register TX path

TLP transmit is a register data channel rather than a descriptor ring. It
therefore belongs to `tlpq` but does not enter `gq_queue_engine`.

`tlpq_tx_reg_adapter` accepts a `pcie_tl_tlp`, uses the `pcie_work` codec and
the DPU bridge, waits for Host or Switch TX ready, and emits consecutive chunks
of at most 16 DWORDs. It sets keep bits for valid DWORDs, Host ID in TUSER,
SOP on the first chunk, and EOP on the last chunk. Multi-chunk data is
contiguous; the implementation does not reproduce an erroneous pointer skip
from reference C code.

The user-derived adapter implements the actual ready, data, keep, TUSER, and
control register accesses.

## 10. Ownership and Concurrency

- The GQ engine owns the ring and all descriptor-associated `host_mem`
  allocations after successful internal ownership transfer.
- Completion analysis delivery is synchronous.
- Parsed raw bytes, copied CMDQ results, and decoded TLP objects are valid
  throughout the callback.
- A subscriber that retains a descriptor or TLP beyond the callback clones it.
- CMDQ waiters consume copied dynamic result bytes and never retain the freed
  host-memory buffer.
- `pcie_work` objects do not retain a GQ engine, adapter, or host-memory
  allocation.
- Every allocation is released exactly once on completion, reset rollback, or
  final cleanup.

Reset and cleanup use this order:

1. make stop/reset visible and wake capacity waiters;
2. cancel polling or IRQ waits;
3. disable the hardware queue;
4. wait for in-flight publish, completion query, and IRQ ACK tasks to quiesce;
5. discard stale epoch results;
6. release descriptor buffers and ring storage.

No state lock is held across a user adapter task. The existing publish
linearization and disable-cancellation contract remains in force.

## 11. Error Handling

- Invalid configuration fails before adapter programming.
- A failed completion query reports an adapter error and retires nothing.
- MSGQ `current_ptr >= depth` is a protocol error and consumes no entry.
- A completion count beyond the pending or outstanding snapshot is rejected.
- A changed stable descriptor field fails parsing and preserves the head for
  diagnosis.
- An invalid CMDQ result length fails completion and returns no result.
- An invalid TLP header length, DPU layout, byte count, or null codec result
  fails parsing and does not refill that descriptor.
- A spurious IRQ is acknowledged but is not treated as completion progress.
- A lost IRQ may be recovered by the watchdog query.
- TX final timeout is reported once for the oldest published transaction.
- RX event queues may remain empty indefinitely without timeout errors.
- A malformed head blocks ordered retirement; later entries are not retired
  out of order.
- Unknown MSGQ entries guarantee only configured fixed-size raw-byte capture
  and pointer progression.

## 12. Driver-Conformance Verification

### 12.1 Semantic adapter trace

Mock business adapters record semantic events rather than numerical addresses:

```text
RESET
CONFIGURE(base, depth, descriptor_size, business metadata)
PUBLISH(tail)
ENABLE
WAIT_IRQ
ACK_IRQ
READ_CURRENT_PTR
DISABLE
```

Tests compare event ordering and arguments with the real driver flow while
leaving address mapping user-defined.

### 12.2 MSGQ cases

- MAC-age depth 128, 16-byte entries, initial tail 127, one initial notify,
  current-pointer consumption, no refill publish, multiple completions, and
  wrap.
- 1588 depth 32 active-EMP profile, 8-byte entries, mode-1 behavior, initial
  tail 31, timestamp/tag/type/port parsing, and wrap.
- The configurable depth-128 timestamp variant.
- Invalid current pointer and failed register read.
- Poll and IRQ detection, lost-IRQ watchdog, spurious IRQ, and reset races.
- Raw user entry factory smoke coverage without a field-level conformance
  claim.

### 12.3 CMDQ cases

- Reset/configure/enable ordering.
- Depth 32, descriptor size 32, TX/RX buffer size 256.
- Flow-table send to the FSE destination.
- Statistics query to the PSTAT destination with actual result length.
- `AVAIL` publication and `USED` completion.
- Slot 31 to slot 0 transition publishing `16'h8000`.
- Stable-field corruption, oversized result, no completion, and reset races.
- Adaptive polling as the driver-conformance mode.
- IRQ mode as an additional generic-library capability.

### 12.4 TLPQ cases

- Independent Host and Switch setup, each with 31 initial descriptors.
- Descriptor completion followed by one-at-a-time refill and tail publication.
- Independent Host and Switch bit-15 wrap.
- Poll and IRQ modes, batch completion on one IRQ, watchdog recovery, and
  interrupt isolation.
- Descriptor length/address corruption and malformed packet handling.
- TX ready, keep, Host ID, SOP/EOP, and consecutive 16-DWORD chunk behavior.

Golden vectors cover:

- Configuration Read and Write Type 0
- Configuration Read and Write Type 1
- Memory Read and Write
- Message with Data
- Completion and Completion with Data

Each receive vector follows:

```text
pcie_tl_tlp
  -> pcie_tl_codec.encode
  -> independently checked DPU layout bytes
  -> mock TLPQ DMA completion
  -> tlpq_rx_desc parse
  -> pcie_tl_codec.decode
  -> field and payload comparison
```

Independent expected DPU DWORD arrays prevent a bridge encode/decode pair from
passing merely because both directions share the same mistake.

### 12.5 Polling and timing cases

- Fixed poll detects completion within one configured interval.
- Adaptive poll follows `10, 20, 40, 80, 100 ns` for the CMDQ defaults.
- Progress resets the interval to 10 ns.
- New CMDQ work wakes an idle or long-waiting worker immediately.
- Long RX idle periods do not create a zero-time loop or remain at maximum
  query frequency.
- IRQ arrival cancels the watchdog path and results in one ACK.
- Watchdog completion queries do not generate an ACK.

### 12.6 Regression environment

All existing GQ and mailbox tests continue to pass. New tests compile each
business package independently and together to catch accidental business
dependencies.

Simulation runs on `10.11.10.53` as user `ubuntu` through a bash login shell so
the VCS path and license environment come from `~/.bashrc`. The full regression
includes the pinned `host_mem` and `pcie_work` submodules.

## 13. Acceptance Criteria

The feature is accepted when:

1. `gq` contains no MSGQ, CMDQ, TLPQ, DPU register, or PCIe TLP business type.
2. Each business compiles as its own package from its own directory.
3. No project-owned `.svh` source is added.
4. Existing mailbox and generic-queue regressions pass unchanged in behavior.
5. MSGQ MAC-age and timestamp tests match the current-pointer and auto-recycle
   driver behavior.
6. CMDQ tests match descriptor, buffer, completion, result, and wrap behavior.
7. Host and Switch TLPQ tests match setup, completion, refill, and wrap
   behavior.
8. TLPQ exposes `pcie_work` TLP objects and passes independent DPU-layout
   golden vectors.
9. Poll, IRQ, lost-IRQ watchdog, spurious IRQ, and lifecycle races pass.
10. The complete VCS regression passes on `10.11.10.53`.

