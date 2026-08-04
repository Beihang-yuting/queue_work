# Generic Queue UVM Environment Design

## 1. Purpose

This document defines a reusable UVM environment for RTL blocks that use a
virtio-like descriptor queue. The first concrete consumer is `mailbox_env`;
future consumers include `cmdq` and `dmaq`.

The common layer owns queue storage, logical producer/consumer state,
descriptor lifetime, completion servicing, reset recovery, and batching. A
concrete design supplies its descriptor format, completion source, hardware
register adapter, and raw pointer encoding.

## 2. Scope

The first delivery contains:

- A compilable SystemVerilog/UVM common queue package.
- A `mailbox_env` derived from the common environment.
- Reuse of `host_mem_api` from
  `https://github.com/Beihang-yuting/host_mem`, branch `master`, commit
  `3b9e000` or a compatible later revision.
- Mock hardware and unit tests for queue behavior; no mailbox RTL or RAL model
  is required.
- VCS verification on `10.11.10.53` in the login-shell environment.

The first delivery does not:

- Bind to a particular AXI, PCIe, or register VIP.
- Implement a TX-to-RX payload scoreboard.
- Interpret mailbox RX success/failure information that has not yet been
  specified.
- Prescribe the bit layout or semantics of a design's raw head/tail value.

## 3. Confirmed Requirements

### 3.1 Queue model

- A design may expose many independent TX and RX queues.
- Each enabled queue has a fixed descriptor size and a power-of-two depth.
- Queue ring storage is allocated during queue initialization, before traffic.
- Disabled queues create no agent and allocate no host memory.
- Descriptor-referenced buffers are allocated per transaction.
- Completions are in submission order.
- Submission supports one descriptor per publish or multiple descriptors
  followed by one larger tail publish.
- Completion notification is selectable between polling and interrupt modes.
- The completion storage mechanism is supplied by the concrete design:
  descriptor writeback or a status area following the ring.
- Runtime reset aborts outstanding traffic, frees all queue resources, and
  reinitializes enabled queue rings after reset release.

### 3.2 Address and pointer widths

```systemverilog
typedef bit [63:0] gq_addr_t;
typedef bit [31:0] gq_raw_ptr_t;
typedef longint unsigned gq_logical_seq_t;
```

- All host-memory addresses and address arithmetic are 64-bit.
- Hardware head/tail data has a 32-bit transport type.
- The common engine uses a monotonic 64-bit logical sequence and never embeds
  a design-specific raw pointer interpretation.
- A user-supplied pointer codec maps between logical sequence state and the
  32-bit hardware value. It may choose current-index, next-index, phase, or
  other field layouts.

### 3.3 Host memory

The queue environment and the DUT-facing memory BFM share the same
`host_mem_api` instance. This is the single source of truth for descriptor
rings, status areas, and referenced data buffers.

The common layer uses these abstract operations:

- `alloc(size, align)`
- `free(addr)`
- `write_mem(addr, data)`
- `read_mem(addr, size, data)`
- `leak_check()`

The environment is not bound directly to `host_mem_manager` internals.

## 4. Architecture

The design uses composition for independent variation points. Concrete
environments do not reimplement queue algorithms.

```text
gq_env
|-- gq_env_cfg
|   |-- host_mem_api
|   |-- gq_hw_adapter
|   |-- gq_completion_source prototype
|   `-- enabled queue_cfg entries
|-- gq_reset_controller
`-- gq_queue_agent queues[]
    |-- gq_sequencer
    |-- gq_driver
    `-- gq_queue_engine
        |-- slot/outstanding state
        |-- gq_wait_policy
        |-- optional gq_refill_policy
        `-- completion analysis_port
```

### 4.1 `gq_env`

`gq_env` creates agents only for enabled queue configurations. It shares the
memory API, hardware adapter, reset events, and design-level policy prototypes
with those agents. Sparse queue configuration is required so a design with
thousands of possible queue IDs pays only for enabled queues.

### 4.2 `gq_queue_cfg`

Each enabled queue configuration contains:

- Queue ID and role (`GQ_TX` or `GQ_RX`).
- Ring depth and descriptor size in bytes.
- Ring alignment and optional status-area size/alignment.
- Descriptor factory/type information.
- Completion source and raw pointer codec.
- Poll interval or interrupt wait policy selection.
- Completion timeout.
- Optional refill profile for an active RX queue.

Concrete environments validate additional limits. For example, mailbox
requires IDs `0..4095` and depths from 32 through 65536.

### 4.3 `gq_desc_base`

`gq_desc_base` is an abstract `uvm_sequence_item`. A concrete descriptor owns
its transaction fields and the list of memory allocations associated with one
slot. Its virtual contract covers:

- Allocate and initialize referenced buffers.
- Pack exactly `desc_size` bytes.
- Mark a slot available for the supplied phase.
- Test completion for the supplied phase.
- Parse DUT writeback and referenced result buffers.
- Release every associated allocation exactly once.

The ring allocation is owned by the queue engine, not by descriptor objects.

### 4.4 `gq_queue_engine`

The engine owns:

- Ring and optional trailing status-area addresses.
- Monotonic `logical_tail` and `logical_head` values.
- Slot-to-descriptor outstanding handles.
- Submission, batch commit, ordered drain, and queue-full backpressure.
- Phase calculation from logical sequence and ring depth.
- Optional RX refill service.
- Reset epoch and shutdown state.

The slot address is always:

```text
ring_base + ((logical_sequence % depth) * desc_size)
```

The engine never parses a concrete descriptor field.

### 4.5 `gq_completion_source`

The completion source answers how far the DUT has completed. Two reusable
forms are required:

- Descriptor writeback: re-read the descriptor at `logical_head`, call its
  phase-aware completion predicate, and continue in order until the first
  incomplete slot.
- Trailing status memory: read the status area following the ring and decode
  the raw completion value with a user-supplied codec.

The source must reject completion progress beyond the outstanding count.

### 4.6 `gq_wait_policy`

The wait policy only determines when to call the common drain operation:

- Poll policy waits the configured interval.
- Interrupt policy calls `gq_hw_adapter.wait_irq()`, acknowledges as required,
  and then drains every currently completed descriptor.

Polling and interrupt modes therefore cannot diverge in completion semantics.

### 4.7 `gq_hw_adapter`

The adapter is the only common-layer dependency on design hardware access. Its
virtual interface covers:

- Configure/enable a queue with 64-bit base, depth, and descriptor size.
- Reset or disable a queue.
- Publish a 32-bit raw tail value.
- Wait for and acknowledge an interrupt.

The adapter may use RAL, a virtual interface, or another BFM. The first unit
tests use a mock adapter.

### 4.8 `gq_ptr_codec`

The pointer codec receives the previous and new logical tail, depth, and phase
and returns `gq_raw_ptr_t` for a publish. A completion-capable codec also maps a
32-bit raw writeback value to a logical completion position relative to the
current head.

The codec owns whether a raw pointer means the last published slot, the next
available slot, or another representation. This decision does not leak into
the engine.

## 5. Queue Memory and Lifecycle

For every enabled queue, initialization allocates one contiguous block:

```text
queue_base
|-- descriptor[0]       desc_size bytes
|-- descriptor[1]       desc_size bytes
|-- ...
|-- descriptor[depth-1]
`-- optional status area
```

The allocation size is:

```text
(depth * desc_size) + status_area_size
```

The implementation performs this arithmetic in 64-bit space and checks for
overflow before calling `host_mem_api.alloc`.

The queue block exists from initialization until runtime reset, explicit
shutdown, or the UVM final cleanup. Referenced buffers have descriptor
lifetime and are released after completion or abort.

At normal test shutdown, workers stop, all descriptor resources and ring
blocks are freed, and the shared memory leak check runs after cleanup.

## 6. Submission and Batching

### 6.1 Single submission

1. The driver receives a request containing one concrete descriptor.
2. The engine waits until outstanding count is less than depth.
3. The descriptor allocates its referenced buffers.
4. The engine supplies the slot phase, the descriptor marks itself available,
   and then packs exactly `desc_size` bytes for the selected ring slot.
5. The packed bytes are written to shared host memory.
6. The engine records the descriptor in the outstanding slot.
7. The pointer codec encodes the new logical tail.
8. The hardware adapter publishes it once.

### 6.2 Batch submission

A request may contain multiple descriptors. The engine prepares all members
and then performs one tail publish. No member is considered committed until
the complete batch has prepared successfully.

If preparation fails:

- Every referenced allocation made by this batch is freed.
- No logical tail is committed.
- No raw tail is published.
- Any bytes written to unreachable ring slots may be overwritten by the next
  successful submission.
- The request returns a resource-error response.

The DUT contract is that it does not consume beyond the published tail.

## 7. Ordered Completion

The completion worker always starts at `logical_head` and retires in order. It
never skips an incomplete slot. For every completed descriptor it:

1. Parses descriptor writeback and any referenced output buffer.
2. Publishes a completed transaction through an analysis port.
3. Releases descriptor-owned memory.
4. Clears the outstanding slot.
5. Increments `logical_head`.
6. Wakes a submitter blocked by a full queue.

The worker drains all consecutive completions on each poll or interrupt.

## 8. RX Startup and Automatic Refill

RX uses a one-time startup sequence rather than a continuous stream of
sequence items. The startup request supplies a profile that the engine clones
and owns after the sequence ends:

- Enable/disable state.
- `initial_post_count`.
- `low_watermark` and `high_watermark`.
- A persistent descriptor provider/randomization policy.
- Reset restart choice.

The engine initially generates and publishes `initial_post_count` descriptors
as one batch. After startup, only DUT completion progress can trigger a refill;
another sequence call is not required and cannot advance refill state.

After `logical_head` advances, the engine computes:

```text
posted_count = logical_tail - logical_head
```

If `posted_count <= low_watermark`, it generates enough new descriptors to
reach `high_watermark` and publishes the refill as one batch. The profile must
satisfy:

```text
0 <= low_watermark < high_watermark <= depth
initial_post_count <= depth
```

Each completed RX descriptor is parsed and its old buffer is released before
the replacement batch is allocated.

## 9. Phase Handling

The engine derives a slot phase from the logical sequence and depth. The
initial phase is one, and it toggles on every complete traversal of the ring.
A descriptor receives the phase as an argument; the generic engine does not
assume flag bit positions.

For mailbox, both TX and RX use:

```text
first traversal:  submit avail=1, used=0; complete when used=1
second traversal: submit avail=0, used=1; complete when used=0
```

The pattern repeats on later traversals. On submission, mailbox explicitly
writes `avail=phase` and `used=!phase`. Completion is `used==phase`.

## 10. Reset and Concurrency

### 10.1 Runtime reset

On reset assertion:

1. Increment a reset epoch and reject new submissions.
2. Stop or invalidate poll, interrupt, completion, and refill workers.
3. Return `GQ_ABORTED_BY_RESET` for active sequence requests.
4. Release every outstanding descriptor resource exactly once.
5. Free all enabled ring allocations.
6. Clear logical head/tail, slot state, and phase back to initial values.

On reset release:

1. Reallocate rings for all enabled queues.
2. Reprogram base/depth through the hardware adapter.
3. Restart completion workers.
4. For each RX queue, apply its configured recovery mode:
   - restart mode preserves the cloned profile, performs a new initial prefill,
     and resumes refill;
   - wait-for-sequence mode clears the profile and remains idle until another
     startup request.

Every asynchronous operation captures its reset epoch before beginning and
must discard stale results if the epoch changes.

### 10.2 Serialization

Each queue serializes state transitions among its submit, completion, refill,
and reset paths. Locks are not held across external timed waits. Descriptor and
ring memory calls are zero-time `host_mem_api` functions; the shared API is the
only memory store used by the environment and mock DUT.

## 11. Mailbox Extension

### 11.1 Queue configuration

Mailbox has independent TX and RX queue ID spaces, each containing IDs
`0..4095`. Only enabled IDs are represented in sparse environment
configuration.

Each mailbox queue has:

- An enable and reset control supplied through the hardware adapter.
- A 64-bit ring base.
- A power-of-two depth from 32 through 65536 descriptors.
- TX descriptor size 64 bytes.
- RX descriptor size 16 bytes.
- Descriptor writeback completion.
- Test-selectable poll or interrupt notification.
- User-supplied 32-bit tail pointer codec.

### 11.2 TX descriptor

The 512-bit TX descriptor is packed little-endian:

| Bits | Field | Behavior |
|---|---|---|
| `[15:0]` | `flags` | bit 0 `avail`, bit 1 `used`, others reserved |
| `[31:16]` | `srcid` | Defined but no function-specific checking |
| `[47:32]` | `dstid` | Defined but no function-specific checking |
| `[63:48]` | `msg_type` | Defined but no function-specific checking |
| `[127:64]` | `buf_addr` | 64-bit address of external data |
| `[143:128]` | `buf_len` | Valid external-data byte count |
| `[159:144]` | `data_len` | Valid inline-data byte count, constrained to 0..44 |
| `[511:160]` | `data` | 44 inline bytes, least-significant byte first |

External and inline data may both be valid. When `buf_len` is nonzero, the
descriptor allocates an external buffer, fills exactly `buf_len` randomized
bytes, and writes those bytes through `host_mem_api`. Inline valid bytes begin
at bits `[167:160]`. The first version does not combine the two fields for a
TX-to-RX scoreboard.

### 11.3 RX descriptor

The 128-bit RX descriptor is packed little-endian:

| Bits | Field | Behavior |
|---|---|---|
| `[15:0]` | `flags` | bit 0 `avail`, bit 1 `used`, others reserved |
| `[31:16]` | reserved | Packed as zero by default |
| `[63:32]` | `buf_len` | Allocated receive-buffer length |
| `[127:64]` | `buf_addr` | 64-bit receive-buffer address |

The RX descriptor provider used by the startup profile chooses `buf_len` for
each generated descriptor. The descriptor allocates the buffer before
submission. After completion it reads the actual bytes and publishes them as
an RX result. Success/failure interpretation and TX comparison remain future
extensions.

### 11.4 Mailbox completion source

Mailbox shares one descriptor-writeback source implementation between TX and
RX. It uses each queue's configured descriptor size for slot addressing and
delegates flag interpretation to the concrete descriptor. It synthesizes a
logical completed position by scanning consecutive `used` phases; mailbox
does not require a trailing completion status area.

## 12. Error Handling and Diagnostics

Configuration errors are fatal before traffic:

- Missing memory API, hardware adapter, pointer codec, or completion source.
- Duplicate queue ID/role entries.
- Invalid descriptor size, alignment, queue depth, or mailbox ID.
- RX watermarks outside their required ordering and range.
- Ring-size arithmetic overflow.

Runtime protocol/resource errors include:

- Packed byte count different from `desc_size`: fatal descriptor error.
- Allocation failure: batch rollback and resource-error response.
- Completion progress beyond outstanding count: protocol error with queue
  state dump.
- Completion timeout: report queue ID, role, logical head/tail, phase, and a
  descriptor hexdump.
- Stale work after reset: silently discarded by epoch after owned temporary
  resources are released.

Diagnostic messages include queue ID, direction, logical sequence, slot
index, phase, and ring address whenever applicable.

## 13. Unit-Test Design

The testbench uses the real `host_mem_manager`, a mock mailbox hardware
adapter, and a mock DUT operating on the same memory API. The mock DUT consumes
only through the last published tail, updates descriptor `used`, optionally
writes RX buffers, and can trigger an interrupt.

Required tests are:

1. Mailbox configuration boundary checks for IDs and depths.
2. Sparse queue construction and zero allocation for disabled queues.
3. Up-front ring allocation sizes for TX and RX enabled queues.
4. Little-endian TX 64-byte and RX 16-byte packing.
5. Simultaneous external and inline TX data.
6. Per-transaction referenced-buffer allocation and release.
7. Single TX publish and multi-descriptor batch with one publish.
8. Failed batch rollback with no tail update.
9. Ordered completion stopping at the first incomplete descriptor.
10. Phase inversion after a full ring traversal for TX and RX.
11. Poll and interrupt modes producing identical completions.
12. RX initial prefill from one startup sequence.
13. RX low/high-watermark refill only after DUT progress.
14. Runtime reset aborting outstanding traffic and reallocating enabled rings.
15. Both RX post-reset profile recovery modes.
16. Concurrent sparse TX/RX queues.
17. Final cleanup with zero host-memory leaks.

Compilation and simulation run on `10.11.10.53` using a bash login shell so
the VCS executable and license environment come from that host's `.bashrc`.

## 14. Acceptance Criteria

The design is accepted when:

- The common library compiles independently of mailbox RTL/RAL code.
- `mailbox_env` uses common queue algorithms without overriding engine
  submission, drain, batch, refill, or reset implementations.
- A user can replace the raw pointer codec and hardware adapter without
  editing common source.
- Enabled mailbox TX/RX queues allocate the exact configured ring capacity;
  disabled queues allocate none.
- All required tests pass under VCS on `10.11.10.53`.
- Test shutdown reports no memory leaks.
