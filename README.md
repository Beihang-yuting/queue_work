# Generic Queue UVM Environment

This repository provides a sparse, reset-aware UVM queue environment plus a
mailbox specialization. Queue rings use 64-bit host addresses, hardware tail
pointers are 32-bit encoded values, and software head/tail positions are
64-bit logical sequences. The generic core keeps wrap/phase information for
protocols that need it; the mailbox specialization follows the DPU mailbox
contract with fixed descriptor ownership and a 16-bit index/wrap tail value.

## Configure memory and sparse queues

Inject one shared `host_mem_api` implementation and one DUT-specific
`gq_hw_adapter` into the environment configuration. Only queues explicitly
added to `queues` get agents or preallocated rings.

In the example below, `my_mailbox_adapter` is a concrete class supplied by the
user project that extends `mailbox_reg_adapter` and implements queue
register/IRQ access. `mailbox_env_cfg` creates the production
`mailbox_ptr_codec` by default; its public `ptr_codec` handle remains
replaceable when another DUT needs a different pointer layout.

```systemverilog
function gq_queue_cfg make_mailbox_queue_cfg(
    string name,
    gq_role_e role,
    int unsigned queue_id,
    int unsigned depth,
    gq_wait_mode_e wait_mode,
    time fixed_poll_interval,
    time irq_watchdog_interval,
    time completion_timeout,
    gq_ptr_codec ptr_codec);
    gq_queue_cfg queue_cfg;

    queue_cfg = gq_queue_cfg::type_id::create(name);
    queue_cfg.queue_id           = queue_id;
    queue_cfg.role               = role;
    queue_cfg.depth              = depth;
    queue_cfg.desc_size          = role == GQ_TX ? 64 : 16;
    queue_cfg.alignment          = 64;
    queue_cfg.status_area_size   = 0;
    queue_cfg.wait_mode             = wait_mode;
    queue_cfg.poll_policy           = GQ_POLL_FIXED;
    queue_cfg.poll_min_interval     = fixed_poll_interval;
    queue_cfg.poll_max_interval     = fixed_poll_interval;
    queue_cfg.irq_watchdog_interval = irq_watchdog_interval;
    queue_cfg.completion_timeout    = completion_timeout;
    queue_cfg.ptr_codec             = ptr_codec;
    queue_cfg.completion_source     = mailbox_completion::type_id::create(
        {name, "_completion"});
    return queue_cfg;
endfunction

host_mem_manager mem;
my_mailbox_adapter adapter;
mailbox_env_cfg cfg;
mailbox_env env;
gq_queue_cfg tx_1_cfg;
gq_queue_cfg tx_4095_cfg;
gq_queue_cfg rx_2_cfg;
gq_queue_cfg rx_3000_cfg;
string reason;

mem = new("mem");
mem.init_region(64'h0000_0001_0000_0000,
                64'h0000_0001_00ff_ffff, MODE_LINEAR, 16);
adapter = my_mailbox_adapter::type_id::create("adapter");

cfg = mailbox_env_cfg::type_id::create("cfg");
cfg.mem       = mem;
cfg.adapter   = adapter;

tx_1_cfg = make_mailbox_queue_cfg(
    "tx_1_cfg", GQ_TX, 1, 32, GQ_POLL, 100ns, 0, 10us,
    cfg.ptr_codec);
tx_4095_cfg = make_mailbox_queue_cfg(
    "tx_4095_cfg", GQ_TX, 4095, 32, GQ_IRQ, 100ns, 1us, 10us,
    cfg.ptr_codec);
rx_2_cfg = make_mailbox_queue_cfg(
    "rx_2_cfg", GQ_RX, 2, 32, GQ_POLL, 100ns, 0, 0,
    cfg.ptr_codec);
rx_3000_cfg = make_mailbox_queue_cfg(
    "rx_3000_cfg", GQ_RX, 3000, 32, GQ_IRQ, 100ns, 1us, 0,
    cfg.ptr_codec);

if (!cfg.add_queue(tx_1_cfg, reason) ||
    !cfg.add_queue(tx_4095_cfg, reason) ||
    !cfg.add_queue(rx_2_cfg, reason) ||
    !cfg.add_queue(rx_3000_cfg, reason))
    `uvm_fatal("QUEUE_CFG", reason)

uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", cfg);
env = mailbox_env::type_id::create("env", this);
```

The mailbox configuration validates IDs in `0..4095`, power-of-two depths in
`32..32768`, 64-byte TX descriptors, and 16-byte RX descriptors. The DPU
driver on `10.11.10.53` currently configures depth 256, which lies within this
range. A successful
`add_queue` transfers ownership of that queue configuration to the environment.
Set every field and strategy before calling it, and do not mutate the queue
configuration through either the original handle or `cfg.queues` afterward.
The `add_tx`/`add_rx` helpers install mailbox defaults; construct an explicit
`gq_queue_cfg` as above when a queue needs custom wait or timeout policy.

## Derive descriptors and pointer codecs

A protocol descriptor derives from `gq_desc_base`. Implement `prepare()` for
transaction-buffer ownership, `mark_available(phase)`, fixed-size `pack()` and
`unpack()`, `is_complete(phase)`, and completion parsing when the protocol has
writeback data. Allocate transaction buffers with `alloc_owned()` so completion,
reset, and final cleanup can release them exactly once. See
`mailbox_tx_desc` and `mailbox_rx_desc` for concrete 64-byte and 16-byte
implementations.

Mailbox does not phase its descriptor ownership flags. Both TX and RX always
publish `flags=16'h0001` (`AVAIL=1`, `USED=0`) and complete only after the DUT
writes `USED=1`. Their `mark_available(phase)` and `is_complete(phase)` methods
therefore intentionally ignore the phase argument. Other descriptor protocols
may still use the generic `gq_phase(sequence, depth)` value.

Completion storage/writeback is a design-level mechanism and strategy type
across roles and queues, not a per-queue hardware-mode switch. The source still
stores one `completion_source` object in each `gq_queue_cfg` so an instance can
carry queue-specific parameters or state. A derived environment must validate
or install the design's required strategy type for every queue, while creating
separate instances where needed. For example, `mailbox_env_cfg` enforces a
`mailbox_completion` instance for every TX and RX queue; a design based on
`gq_tail_mem_completion` may instead give each queue's instance its applicable
pointer codec, byte offset, and byte order without changing the design-level
completion mechanism.

A hardware pointer format derives from `gq_ptr_codec` and implements:

```systemverilog
virtual function gq_raw_ptr_t encode_publish(
    gq_logical_seq_t old_tail,
    gq_logical_seq_t new_tail,
    int unsigned depth);

virtual function bit decode_completion(
    gq_raw_ptr_t raw,
    gq_logical_seq_t logical_head,
    int unsigned depth,
    output gq_logical_seq_t completed_tail);
```

The default `mailbox_ptr_codec` encodes the published tail as follows:

| Bits | Meaning |
| --- | --- |
| `[14:0]` | Ring index, `new_tail % depth` |
| `[15]` | Wrap parity, `(new_tail / depth) & 1` |
| `[31:16]` | Zero |

This layout supports mailbox depths through 32768. For example, a depth-32
queue publishes logical tail 32 as `16'h8000` and logical tail 33 as
`16'h8001`. Keep all wrap decisions in the codec; replace `cfg.ptr_codec`
with a derived `gq_ptr_codec` only when the target hardware uses another raw
pointer representation.

## Adapt mailbox register access

`mailbox_reg_adapter` is the register-access seam. It converts the generic
queue callbacks into mailbox-specific callbacks and narrows the production
tail value to 16 bits, but deliberately contains no register addresses or
access mechanism. A user adapter can use UVM RAL, PCIe transactions, or a DUT
backdoor, for example:

```systemverilog
class my_mailbox_adapter extends mailbox_reg_adapter;
    `uvm_object_utils(my_mailbox_adapter)

    my_mailbox_regs ral;

    function new(string name = "my_mailbox_adapter");
        super.new(name);
    endfunction

    virtual task configure_mailbox_registers(
        gq_role_e role, int unsigned queue_id, gq_addr_t base,
        int unsigned depth, int unsigned desc_size);
        int unsigned local_qid = map_local_qid(role, queue_id);
        // Program the user project's RAL/PCIe/backdoor registers here.
    endtask

    virtual task disable_mailbox_registers(
        gq_role_e role, int unsigned queue_id);
        // Disable or cancel this logical queue here.
    endtask

    virtual task write_mailbox_notify(
        gq_role_e role, int unsigned queue_id, bit [15:0] raw_tail);
        // Write the mapped RX/TX notify register here.
    endtask

    virtual task wait_mailbox_irq(
        gq_role_e role, int unsigned queue_id);
        // Wait through the user project's interrupt mechanism here.
    endtask

    virtual task ack_mailbox_irq(
        gq_role_e role, int unsigned queue_id);
        // Acknowledge the mapped interrupt here.
    endtask
endclass
```

The environment treats `queue_id` as a user-defined logical identifier. The
adapter owns the mapping from `(role, queue_id)` to physical/local RX or TX
queue IDs and registers; the generic and mailbox packages do not assume the
DPU driver's local numbering.

## Implement publish cancellation in the hardware adapter

A concrete `gq_hw_adapter` (including `mailbox_reg_adapter`) may block inside
`publish(role, queue_id, raw_tail)`.
For the same role and queue ID, `disable_queue(role, queue_id)` is the
cancellation operation for an in-flight blocked `publish()`. The adapter must
allow the two tasks to run concurrently. Every overlap must linearize in
exactly one of these orders:

- If `publish()` linearizes first, its tail update may already be visible and
  the call must proceed to completion as a non-cancelable publish. A later
  `disable_queue()` does not retroactively revoke that visible update.
- If `disable_queue()` becomes effective first, the not-yet-linearized publish
  is canceled and must return without waiting for engine teardown or
  queue-memory release. From that disable boundary onward, the canceled call
  must produce no new tail-visible side effect; in particular, its tail must
  not become visible after `disable_queue()` returns.

The adapter must make publish linearization, task completion, and the visible
tail side effect agree. It must not make a hardware tail visible while still
treating that same invocation as cancelable pending work. The public interface
intentionally requires no separate `cancel_publish()` task; an implementation
may use private cancellation helpers or state behind `publish()` and
`disable_queue()`.

The disable-first case is directly testable: block a publish before its
linearization point, call disable concurrently, then verify that publish
returns and the canceled tail remains unobserved. This is a cancellation and
quiescence contract, not a cancellation-timeout contract.

Returning from `disable_queue()` does not by itself prove that the corresponding
SystemVerilog `publish()` task has unwound. The engine tracks that exact
in-flight task and waits for its done event before releasing or reusing
descriptor-owned buffers, the queue ring, or any backing memory. The adapter
does not inspect the engine's done event and does not free host storage.
Conversely, return from `publish()` is the adapter's quiescence boundary for
that invocation: it must leave no deferred work that can later access queue or
backing storage or expose a tail update. These two responsibilities let disable
return before task unwind without letting the engine release storage early.

A normal return from `publish()` means only that the adapter call reached its
quiescence boundary. It does not automatically make the sequence response
successful and does not set `committed_count`. The engine first revalidates the
operation against the current epoch and queue lifecycle, and only a current
operation is reported as published to its caller. If runtime reset made an
in-flight user TX publish stale, the response is `GQ_ABORTED_BY_RESET`, even
when the adapter task returned normally.

## Submit TX work

The same sequence represents a single request or an atomic batch. Once the
engine takes descriptor ownership for its internal submit transaction, it
retains cleanup responsibility across publish and reset; caller-visible success
is decided only after publish return and epoch/lifecycle revalidation.

```systemverilog
mailbox_tx_sequence tx;
mailbox_tx_desc desc;

tx = mailbox_tx_sequence::type_id::create("single_tx");
desc = mailbox_tx_desc::type_id::create("desc");
desc.srcid = 1;
desc.dstid = 2;
desc.data_len = 1;
desc.data[0] = 8'ha5;
tx.add_desc(desc);
tx.start(tx_sequencer);
if (tx.response.status != GQ_OK || tx.response.committed_count != 1)
    `uvm_fatal("TX", "single submit failed")

tx = mailbox_tx_sequence::type_id::create("batch_tx");
tx.add_desc(first_desc);
tx.add_desc(second_desc);
tx.add_desc(third_desc);
tx.start(tx_sequencer);
if (tx.response.status != GQ_OK || tx.response.committed_count != 3)
    `uvm_fatal("TX", "batch submit failed")
```

## Start RX once

RX startup is a one-shot operation. The engine clones the supplied profile,
posts `initial_post_count` descriptors, and thereafter refills only after real
DUT retirement reduces the posted count to `low_watermark` or below.

```systemverilog
mailbox_refill_profile profile;
mailbox_rx_start_sequence start_rx;

profile = mailbox_refill_profile::type_id::create("profile");
profile.initial_post_count  = 4;
profile.low_watermark       = 2;
profile.high_watermark      = 6;
profile.restart_after_reset = 1;
profile.min_buf_len         = 256;
profile.max_buf_len         = 2048;

start_rx = mailbox_rx_start_sequence::type_id::create("start_rx");
start_rx.set_refill_profile(profile);
start_rx.start(rx_sequencer);
if (start_rx.response.status != GQ_OK)
    `uvm_fatal("RX", "RX startup failed")
```

A second startup request returns `GQ_RESOURCE_ERROR`. With
`restart_after_reset=1`, reset recovery reposts the saved initial profile; it
does not accept another user startup.

## Query completions and schedule waits

Every completion strategy implements the asynchronous `query_completed()`
task. It receives the memory and adapter handles, ring and status addresses,
ring geometry, the current logical head, and a snapshot of pending descriptors.
Its two outputs have exact, independent meanings:

- `valid=0` means completion state could not be sampled or parsed. The engine
  reports the query failure and retires no descriptor; `completed_count` is
  ignored and implementations return it as zero.
- `valid=1` means the sample is usable. `completed_count=0` is a successful
  no-progress sample, while a nonzero count is the contiguous number of
  descriptors completed from the logical head. The engine rejects a count
  larger than either the pending snapshot or the current outstanding count.

`gq_desc_writeback_completion` reads pending ring slots in logical order,
unpacks each descriptor, tests `is_complete(gq_phase(sequence, depth))`, and
stops at the first incomplete or invalid slot. `gq_tail_mem_completion` instead
decodes a sampled completion tail and returns its distance from the logical
head. The task may block in an adapter-backed implementation; reset and cleanup
do not hold the lifecycle lock across it, discard stale results by epoch, and
wait for the exact query task to quiesce before releasing storage.

Poll and IRQ modes share this ordered drain path. Select `wait_mode`,
`poll_policy`, `poll_min_interval`, `poll_max_interval`,
`poll_backoff_factor`, `irq_watchdog_interval`, and `completion_timeout` before
the successful `add_queue`; do not mutate them after ownership transfers.
Fixed polling requires equal minimum and maximum intervals and waits that
interval every time. Adaptive polling starts at `poll_min_interval`; after each
valid zero-progress query the next interval is
`min(poll_max_interval, current_interval * poll_backoff_factor)`, with
saturation before multiplication can overflow. Completion progress resets the
next interval to the minimum. New work wakes a sleeping worker and resets the
interval to the minimum, but does not itself trigger a completion query; an
invalid query does not advance the backoff. Reset followed by fresh work also
restores the minimum interval.

In IRQ mode a generic adapter implements `wait_irq()` and `ack_irq()`; a
`mailbox_reg_adapter` subclass implements `wait_mailbox_irq()` and
`ack_mailbox_irq()`, which the base class forwards. An actual IRQ is
acknowledged exactly once before its completion query. A nonzero
`irq_watchdog_interval` permits a lost-IRQ completion query, but a watchdog
wake is never acknowledged; zero disables the watchdog. A spurious IRQ is
still acknowledged, while valid zero progress remains zero progress.

The IRQ watchdog is separate from `completion_timeout`, which is the
oldest-published diagnostic deadline. TX requires a nonzero completion timeout
greater than `poll_max_interval`. RX permits `completion_timeout=0`; this
disables oldest-outstanding timeout reports so an empty RX queue may remain
idle indefinitely. A nonzero timeout starts after tail publication returns and
reports an oldest-outstanding episode once, including role, queue ID, head,
tail, slot, phase, ring/slot addresses, and descriptor bytes.

## Choose the RX slot lifecycle and refill granularity

`GQ_RX_EXPLICIT_REFILL` is the default. After ordered parsing and synchronous
analysis delivery, the engine retires completed descriptors, releases their
owned allocations, creates and prepares replacements, rewrites their ring
slots, and publishes the new tail until `high_watermark` is restored. A
nonzero `max_refill_batch` caps the number of replacements in one publication;
the engine performs more refill iterations as needed. `max_refill_batch=0`
means unlimited and preserves the legacy single batched publication.

`GQ_RX_AUTO_RECYCLE` registers and clears `depth-1` fixed-size entries and
publishes the initial tail once. After `N` contiguous completions it parses and
delivers those entries, advances both logical head and tail by `N`, creates
`N` fresh logical entry objects for the rotating sentinel slots, and restores
the outstanding window to `depth-1`. It neither rewrites the ring bytes nor
publishes another tail, so the ring image and publish count remain unchanged.
Auto-recycle entries must not own separate allocations; activation rejects such
an entry before publishing any tail. Explicit-refill queues retain the normal
rewrite/publish behavior, and auto-recycle queues never use refill batching.

## Drive reset and final cleanup

Reset assertion and deassertion are persistent events consumed by the
environment reset controller. Check the boolean result so duplicate or
out-of-order edges are not silently ignored.

```systemverilog
if (!cfg.trigger_reset_asserted())
    `uvm_fatal("RESET", "reset assertion rejected")
// Wait for DUT reset/queue-disable synchronization here.
if (!cfg.trigger_reset_deasserted())
    `uvm_fatal("RESET", "reset release rejected")
```

Drop the test's final run-phase objection normally. When the run phase is ready
to end, the environment raises its own objection, stops new submissions, and
quiesces completion activity. For each queue it then disables the hardware (or
joins disable already in progress), waits for the exact in-flight `publish()`
task to unwind, releases outstanding descriptor-owned buffers, and finally
frees the ring's backing allocation. After every queue reaches that boundary,
the environment runs the one shared memory leak check and drops its objection.
This automatic finalization is safe after runtime reset. Explicit early calls
to `cleanup_and_check_leaks()` remain supported; concurrent or repeated calls
join the same idempotent finalization.

```systemverilog
phase.drop_objection(this);
```

## Configure MSGQ receive queues

The independent `msgq` business library supplies these standard RX profiles:

| Profile | Depth | Entry size |
| --- | ---: | ---: |
| MAC-age | 128 | 16 bytes |
| 1588 active EMP | 32 | 8 bytes |
| 1588 Linux header | 128 | 8 bytes |

`msgq_env_cfg::add_msgq()` installs IRQ detection, adaptive polling with a
50 ns minimum, 500 ns maximum, and backoff factor 2, a 1 us lost-IRQ
watchdog, and `completion_timeout=0`. The disabled completion timeout allows
an RX event queue to remain empty indefinitely. Each profile uses
`GQ_RX_AUTO_RECYCLE` with an outstanding window of `depth-1` entries.

MSGQ progress comes from the hardware current index rather than descriptor
ownership bits. For logical head `logical_head`, the completion source uses:

```text
completed_count = (current_ptr - (logical_head % depth) + depth) % depth
```

The `depth-1` outstanding window makes zero progress distinct from every
permitted completion count. Initialization clears the fixed ring slots and
publishes the initial tail `depth-1` once through
`write_msgq_initial_tail()`. Normal auto-recycle completion advances the
logical head and tail, creates fresh logical entry objects for the rotating
slots, and neither rewrites ring bytes nor publishes another tail.

`msgq_reg_adapter` keeps addresses and access mechanisms in a user-derived
adapter. Its semantic callbacks are:

```systemverilog
configure_msgq_registers(queue_id, base, depth, entry_size);
disable_msgq_registers(queue_id);
write_msgq_initial_tail(queue_id, tail);
wait_msgq_irq(queue_id);
ack_msgq_irq(queue_id);
read_msgq_current_ptr(queue_id, valid, current_ptr);
```

MAC-age and the two 1588 profiles have concrete parsers. FSE, IACL, EACL,
vDPA, and notify are explicitly outside that field-level conformance claim:
they expose only configured fixed-size raw bytes and the
`msgq_entry_factory::create_entry()` seam. Their depth and entry size are
user-supplied, and the library assigns no protocol field semantics to those
bytes.

## Submit CMDQ commands and collect results

The independent `cmdq` business library provides one depth-32 TX command ring.
Each little-endian descriptor is exactly 32 bytes:

| Offset | Size | Field | Post-publication contract |
| --- | ---: | --- | --- |
| `0x00` | 2 | `flags` | Hardware may update |
| `0x02` | 2 | `tx_buf_len` | Stable |
| `0x04` | 8 | `tx_buf_addr` | Stable |
| `0x0c` | 2 | `dst_id` | Stable |
| `0x0e` | 2 | `rx_buf_len` | Hardware may update |
| `0x10` | 8 | `rx_buf_addr` | Stable |
| `0x18` | 8 | `reserved` | Stable, zero |

`cmdq_tx_desc::prepare()` allocates two distinct descriptor-owned
`CMDQ_BUFFER_BYTES` (256-byte) host-memory blocks. It copies the raw request
bytes into a zero-filled TX block, zeroes the RX block, and advertises the full
256-byte RX capacity. Once the descriptor transfers to GQ, the engine owns
cleanup of both allocations on completion, reset, or final cleanup. Hardware
may change only `flags` and `rx_buf_len`; unpack rejects changes to TX length or
address, destination, RX address, or the reserved field. Completion requires
`CMDQ_DESC_USED`, and an RX length greater than 256 is rejected.

Submission calls `mark_available()` to write `flags=16'h0001`, exactly
`AVAIL=1, USED=0`; the descriptor flag does not carry the ring phase. The
`cmdq_ptr_codec` carries that phase in published tail bit 15 and the slot index
in the low bits. For the standard depth-32 ring, logical tails 31, 32, and 64
encode as `16'h001f`, `16'h8000`, and `16'h0000`, respectively, so bit 15
toggles at each ring wrap.

`cmdq_command_sequence` is the synchronous raw-byte API. Set
`request_payload[]` and `dst_id`, then read its copied `result[]` and
`result_status` after `start()` returns. `CMDQ_DST_FSE` is destination 2 and
`CMDQ_DST_PSTAT` is destination 3; the library assigns no field format to
either payload. A completed result is copied out of host memory before those
allocations are released. Each descriptor's `completion_event` is a persistent
`uvm_event`, so `wait_on()` also observes a completion that arrived before the
sequence began waiting. The exported `cmdq_result_status_e` values are:

- `CMDQ_RESULT_OK`: the current sequence accepted completion and copied the
  result;
- `CMDQ_RESULT_SUBMIT_ERROR`: its one-descriptor GQ submission failed, with an
  empty result;
- `CMDQ_RESULT_TIMEOUT`: completion missed the inclusive deadline, which is
  10 us by default, with an empty result;
- `CMDQ_RESULT_PARSE_ERROR`: reserved for user or derived flows and not emitted
  by the current `cmdq_command_sequence`.

`cmdq_env_cfg::add_cmdq()` installs the standard TX profile: depth 32,
32-byte descriptors, `cmdq_ptr_codec`, writeback completion, and adaptive Poll
at 10, 20, 40, 80, then 100 ns. Progress or new work resets the next interval
to 10 ns. The queue's oldest-published diagnostic timeout and the synchronous
command sequence's final timeout both default to 10 us. The standard profile
has no IRQ watchdog; an explicit CMDQ `gq_queue_cfg` may instead select
`GQ_IRQ` and a nonzero `irq_watchdog_interval` while retaining the CMDQ pointer
and completion strategies. A real IRQ is acknowledged once, a watchdog query
is not acknowledged, and the watchdog remains separate from the final timeout.
One `cmdq_env_cfg` plus its adapter instance owns exactly one CMDQ ring. A
second `add_cmdq()` call is rejected for both the same and a distinct queue ID
before the original queue or adapter metadata changes. Advanced multi-ring use
requires separate environment/adapter instances or a future explicitly
queue-indexed metadata extension.

`cmdq_reg_adapter` is the semantic hardware boundary. A user-derived adapter
implements:

```systemverilog
pure virtual task reset_cmdq(int unsigned queue_id);
pure virtual task configure_cmdq_registers(
    int unsigned queue_id, gq_addr_t base, int unsigned depth,
    int unsigned desc_size, cmdq_hw_cfg_t hw_cfg);
pure virtual task enable_cmdq(int unsigned queue_id);
pure virtual task disable_cmdq(int unsigned queue_id);
pure virtual task write_cmdq_tail(
    int unsigned queue_id, bit [15:0] tail);
pure virtual task wait_cmdq_irq(int unsigned queue_id);
pure virtual task ack_cmdq_irq(int unsigned queue_id);
```

The generic configure operation calls reset, configure, and enable in that
order. `hw_cfg` carries host ID, function ID, MSI-X index, and MSI-X validity;
the derived adapter owns register mapping and transport access. An
adapter-internal transport retry never creates a second GQ publish: every retry
remains behind the one `write_cmdq_tail()` semantic callback for that publish.

## Bridge PCIe TLPs and operate TLPQ

TLPQ consumes the `pcie_work` submodule at the exact gitlink
`a86860d0551af62b21a8faffadc7097e8118bb07`. Initialize submodules before a
TLPQ build and do not substitute a locally declared `pcie_tl_tlp` or
`pcie_tl_codec`. For the complete combined build, the compile order is host
memory; `pcie_tl_if.sv`, the PCIe BDF and device-profile helper packages, and
`pcie_topology_pkg.sv`; `pcie_tl_pkg.sv`; GQ; `mailbox`, `msgq`, `cmdq`, and
`tlpq`; then the selected test package and `tb_top.sv`.

`tlpq_packet_bridge` uses the pinned PCIe codec and maintains independent
literal golden vectors for these nine valid packet categories: Configuration
Type 0 read, Configuration Type 0 write, Configuration Type 1 read,
Configuration Type 1 write, Memory Read, Memory Write, Message with Data,
Completion without Data, and Completion with Data. Separate boundary and
negative checks cover the encoded 1024-DWORD maximum, unsupported formats,
misaligned/truncated/overlong layouts, inconsistent Fmt/Length values, null
codec results, and nonzero 3DW padding. TLP Prefixes and ECRC are outside the
TLPQ DPU-layout contract at this pin: a canonical Prefix (`Fmt=3'b100`) and a
Digest-present header (`TD=1`) both fail closed with empty outputs and a
nonempty reason. The bridge does not drop a Prefix or accept an unverified ECRC.

The codec's canonical header order is converted to the DPU four-DWORD header
window below. Payload DWORDs follow at DPU index 4 in their original order.

| DPU DWORD | 4DW TLP | 3DW TLP |
| ---: | --- | --- |
| 0 | Canonical DW3 | `32'h0000_0000` padding |
| 1 | Canonical DW2 | Canonical DW2 |
| 2 | Canonical DW1 | Canonical DW1 |
| 3 | Canonical DW0 | Canonical DW0 |
| 4 onward | Payload DW0 onward | Payload DW0 onward |

Receive decode requires at least the complete 16-byte DPU header window and an
exact Fmt/Length-sized buffer. For a 3DW TLP, DWORD 0 is strict zero padding;
nonzero padding is rejected rather than ignored. Each DWORD is represented in
the DPU byte buffer least-significant byte first, while conversion to and from
the canonical PCIe codec preserves the DWORD values shown above.

The pinned codec carries all ten Tag bits: T9 and T8 use DW0 bits 23 and 19,
while the low eight bits remain in the type-specific request or Completion
header field. Completion decode takes `requester_id` and `tag[7:0]` from DW2,
so Cpl/CplD correlation no longer aliases the DW1 completer/status word. TLPQ
does not maintain a local compatibility repair. The same pin provides detached
clone semantics for current TLP subtypes, dynamic Vendor bytes, and Prefix
objects, so a subscriber may retain a clone without sharing Prefix state with
the producer.

Each TLPQ RX ring entry is exactly 16 bytes, little-endian, and owns one fresh,
zero-filled 128-byte receive buffer. The descriptor and owned-buffer contracts
are:

| Offset | Size | Field | Contract |
| --- | ---: | --- | --- |
| `0x00` | 2 | `flags` | Software publishes `AVAIL=1`; hardware completion sets `USED=1` |
| `0x02` | 2 | `buf_len` | Initially 128; hardware reports the received byte count, which must not exceed 128 |
| `0x04` | 8 | `buf_addr` | Stable address of the descriptor-owned buffer |
| `0x0c` | 1 | `host_id`, `tlp_type` | Low and high nibbles of route metadata |
| `0x0d` | 1 | `primary_bus` | Route metadata written with completion |
| `0x0e` | 1 | `secondary_bus` | Route metadata written with completion |
| `0x0f` | 1 | `subordinate_bus` | Route metadata written with completion |

| Owned-buffer property | Value |
| --- | --- |
| Allocation size | 128 bytes |
| Initial contents | All zero |
| Initial descriptor length | 128 bytes |
| Completion read length | Hardware-reported `buf_len`, limited to 128 |
| Ownership | Descriptor/GQ until retirement, reset, or final cleanup |
| Refill | A fresh descriptor object and a fresh 128-byte allocation |

Completion analysis callbacks are synchronous, so the delivered descriptor
and decoded TLP are borrowed for callback duration. A subscriber that retains
the result should clone the `tlpq_rx_desc`, whose clone is a detached snapshot:
it deep-copies raw DPU bytes and metadata, re-decodes an independent TLP, and
owns neither the ring nor the receive allocation. The pinned PCIe revision also
supports retaining a direct TLP clone: it preserves `at` and subtype-specific
fields, copies dynamic Vendor data, and deep-copies Prefix objects. Neither
clone owns the ring or receive allocation.

Host and Switch RX are separate channels with separate depth-32 rings,
configuration objects, pointer codecs, completion sources, refill profiles,
descriptors, and owned buffers. Each uses `GQ_RX_EXPLICIT_REFILL`, initially
posts 31 entries, and explicitly limits each refill publication to one entry
(`max_refill_batch=1`); neither channel shares progress or storage with the
other.

The standard RX wait policy is IRQ with adaptive Poll support configured for a
50 ns minimum, 500 ns maximum, and backoff factor 2. The lost-IRQ watchdog is
1 us and the RX completion timeout is zero, so an idle receive queue does not
report an oldest-outstanding timeout. Users may select either fixed or adaptive
Poll when changing a queue from IRQ mode, but fixed Poll requires equal minimum
and maximum intervals. A directed 10 ns Poll setting is a test-only override;
it is not a production TLPQ default.

RX activation is ordered independently for each channel as
`RESET -> CONFIGURE -> PUBLISH31 -> ENABLE`: reset and semantic register
configuration complete first, the initial tail value 31 is published only
after all 31 descriptors are serialized, and enable occurs only after that
publish returns. Later batch-one refills publish one replacement tail without
enabling the channel again.

The reusable library deliberately contains no register addresses. User-derived
RX and TX adapters map the semantic channel operations to project registers,
RAL, PCIe accesses, or a backdoor. RX implementations provide reset,
configure, enable, disable/cancellation, tail publish, IRQ wait, and IRQ
acknowledge callbacks. TX implementations provide ready wait, indexed DWORD
write, keep write, TUSER host-ID write, and SOP/EOP/valid control callbacks.
The adapters own Host/Switch address mapping; generic GQ and TLPQ code do not.

TX first encodes the TLP into the DPU DWORD stream, then sends chunks of at most
16 DWORDs. Every chunk performs its own ready wait before any callback for that
chunk. Source DWORD traversal remains continuous across chunks, while the
hardware data-register index restarts at zero for every chunk. `keep[i]` marks
each valid DWORD in that chunk, TUSER carries the selected host ID, SOP is set
only on the first chunk, EOP only on the final chunk, and valid is set on every
committed chunk. The sequence default ready timeout is 1 us; encode failure or
ready timeout returns `success=0` with a nonempty reason.

One adapter serializes the complete encode-through-control operation for each
channel, preventing two Host sends or two Switch sends from interleaving one
register stream. Host and Switch use independent locks, so either channel may
make progress while the other is waiting for ready.

Multi-chunk TX is intentionally non-atomic. If a later chunk's ready wait
times out, every earlier chunk already submitted remains committed; there is
no rollback. The failure reason includes the failing source DWORD offset, and
the adapter receives no data, keep, TUSER, or control callbacks after the
failed ready wait and performs no later-chunk ready waits for that transaction.
The per-channel lock is then released, so a subsequent transaction can run.

## Use the DMAQ transfer queue

DMAQ is an independent EMP transfer-queue library. Its one TX descriptor is
always exactly **`DMAQ_DESC_BYTES==32`** bytes; descriptor size is not a
profile field and does not change when queue geometry is customized. The
little-endian wire layout is:

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
| `0x1e` | 2 | reserved (always zero) |

`mark_available()` writes `AVAIL=1, USED=0`; hardware completion sets `USED`.
Only the two-byte flags field may change after preparation. `unpack()` rejects
any change to BDF, host ID, either length, either address, or reserved bytes.
DMAQ never allocates or frees transfer buffers: source and destination
addresses are borrowed from the caller, whose storage must remain valid until
the engine has retired the descriptor or reset/cleanup has released engine
ownership. A transfer length must be in `1..65535` and is stored identically
in the source and destination length fields.

Each `dmaq_endpoint_t` carries an endpoint role, a 64-bit address, a 16-bit
host ID, and a raw 16-bit BDF. The supported operations require these role
pairs:

| Operation | Source | Destination |
| --- | --- | --- |
| `DMAQ_AF_TO_HOST` | AF | Host |
| `DMAQ_HOST_TO_AF` | Host | AF |
| `DMAQ_HOST_TO_HOST` | Host | Host |

`dmaq_ep_bdf(function_number, vf_number, vf_valid)` packs function in
bits `[3:0]`, VF number in `[11:4]`, VF-valid in bit 12, and clears
`[15:13]`. `dmaq_switch_bdf(raw_bdf)` preserves the supplied raw 16-bit Switch
identity without adding a mode bit.

`dmaq_env_cfg` builds exactly one TX queue. Its public fields have these
defaults: `int unsigned depth = DMAQ_DEFAULT_DEPTH` (32),
`gq_logical_seq_t initial_logical_seq = DMAQ_DEFAULT_INITIAL_LOGICAL_SEQ`
(31), `time poll_interval = DMAQ_DEFAULT_POLL_INTERVAL` (10 ns), and
`time completion_timeout = DMAQ_DEFAULT_COMPLETION_TIMEOUT` (500 ns). Depth
must be a power of two in `2..32768`, the initial sequence must be below
depth, Poll must be nonzero, and the environment timeout must exceed it. For
example, configure the independent custom 64/5 profile as follows:

```systemverilog
dmaq_env_cfg cfg = dmaq_env_cfg::type_id::create("cfg");
cfg.depth = 64;
cfg.initial_logical_seq = 5;
cfg.poll_interval = 25ns;
cfg.completion_timeout = 750ns;
if (!cfg.add_dmaq(0, hw_cfg, reason))
    `uvm_fatal("DMAQ_CFG", reason)
```

The default logical head/tail starts at 31: the first descriptor uses slot 31
and its actual advance publishes `16'h8000`. Under any valid custom geometry,
the first slot is `initial_logical_seq` and the raw tail is encoded as
`raw[14:0] = logical_tail % depth`, `raw[15] = (logical_tail / depth) & 1`,
and `raw[31:16] = 0`; depth 64 with initial sequence 5 therefore first uses
slot 5 and publishes `16'h0006`.

The standard EMP profile is fixed Poll: equal minimum/maximum intervals use
`poll_interval`, backoff is 1, and no IRQ watchdog is installed. An advanced
user may instead construct an explicit DMAQ `gq_queue_cfg` with IRQ and a
nonzero watchdog; IRQ wait/ACK and watchdog behavior are optional GQ
extensions, not EMP-standard behavior. `dmaq_reg_adapter` keeps the hardware
boundary semantic through `reset_dmaq`, `configure_dmaq_registers`,
`enable_dmaq`, `disable_dmaq`, `write_dmaq_tail`, `wait_dmaq_irq`, and
`ack_dmaq_irq`. Configuration is reset, configure, enable. A tail write occurs
exactly once only when a committed logical tail actually advances; polling,
timeouts, and an unchanged tail do not create another write.

`dmaq_transfer_sequence` submits one descriptor and exposes public
`operation`, `source`, `destination`, `transfer_length`, and
`completion_timeout` fields. Its per-sequence timeout defaults to 500 ns and
is independently configurable from the environment's final diagnostic
timeout. Both timeouts remain active; neither replaces the other. A completion
at the inclusive deadline succeeds; after a sequence timeout, a late
completion remains owned by the engine and may still retire normally. Timeout
does not advance DMAQ pointers, alter descriptor bytes, or write a tail.

Run DMAQ's independent driver conformance test with:

```bash
make run TEST=dmaq_driver_conformance_test LIBS=dmaq TEST_SUITE=dmaq
```

## Run with VCS

On a machine where VCS and the UVM license environment are already loaded:

```bash
make run TEST=gq_regression_test LIBS=mailbox TEST_SUITE=gq
```

`LIBS` is a comma-separated library list and defaults to `mailbox`.
`TEST_SUITE` selects the matching test package and defaults to `gq`. Unknown
library or suite names fail during Make parsing, before compilation. Later
business libraries extend only the library, package, and preprocessor-define
maps; generic and selected business sources retain their dependency order.

The repository helper copies the current working-tree contents to
`10.11.10.53`, enters the host's interactive login environment, builds with
VCS, runs one test, and removes the remote temporary directory. Its `rsync`
includes tracked working-tree modifications and untracked files except for the
explicit `.git`, `.superpowers`, and `build` exclusions; it does not require or
imply a committed or clean tree. The streamed simulator output must include an
authoritative final UVM report summary whose warning, error, and fatal counts
are all zero; a missing/non-pristine summary or a failed remote command makes
the helper fail.

```bash
./scripts/run_vcs_remote.sh gq_regression_test
./scripts/run_vcs_remote.sh gq_regression_test mailbox gq
```

The runner accepts `TEST [LIBRARIES [TEST_SUITE]]`. Its one-argument form keeps
the mailbox/GQ defaults. Without an explicit suite, `mailbox` and any
comma-separated library set select `gq`; another single library selects its own
suite name. All three values are validated before the first SSH connection.

Run the complete checked regression with these exact commands:

```bash
./scripts/run_vcs_remote.sh gq_config_test mailbox
./scripts/run_vcs_remote.sh mailbox_desc_test mailbox
./scripts/run_vcs_remote.sh mailbox_ptr_codec_test mailbox
./scripts/run_vcs_remote.sh mailbox_reg_adapter_test mailbox
./scripts/run_vcs_remote.sh mailbox_wrap_test mailbox
./scripts/run_vcs_remote.sh gq_submit_test mailbox
./scripts/run_vcs_remote.sh gq_completion_test mailbox
./scripts/run_vcs_remote.sh gq_refill_test mailbox
./scripts/run_vcs_remote.sh gq_reset_test mailbox
./scripts/run_vcs_remote.sh gq_regression_test mailbox
```

The underlying remote command used by the helper is:

```bash
ssh ubuntu@10.11.10.53 \
  "cd '<temporary-copy>' && bash -lc 'bash -ic \"make run TEST=gq_regression_test LIBS=mailbox TEST_SUITE=gq\"'"
```
