# Generic Queue UVM Environment

This repository provides a sparse, reset-aware UVM queue environment plus a
mailbox specialization. Queue rings use 64-bit host addresses, hardware tail
pointers are 32-bit encoded values, and software head/tail positions are
64-bit logical sequences. The availability phase changes once per queue-depth
lap, so long-running tests do not need to truncate logical sequence numbers.

## Configure memory and sparse queues

Inject one shared `host_mem_api` implementation and one DUT-specific
`gq_hw_adapter` into the environment configuration. Only queues explicitly
added to `queues` get agents or preallocated rings.

In the example below, `my_mailbox_adapter` is a concrete class supplied by the
user project that extends `gq_hw_adapter` and implements queue register/IRQ
access. `my_mailbox_ptr_codec` is likewise a user-project concrete
`gq_ptr_codec` for the DUT's raw pointer layout. Neither name is a testbench
mock from this repository.

```systemverilog
function gq_queue_cfg make_mailbox_queue_cfg(
    string name,
    gq_role_e role,
    int unsigned queue_id,
    int unsigned depth,
    gq_wait_mode_e wait_mode,
    time poll_interval,
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
    queue_cfg.wait_mode          = wait_mode;
    queue_cfg.poll_interval      = poll_interval;
    queue_cfg.completion_timeout = completion_timeout;
    queue_cfg.ptr_codec          = ptr_codec;
    queue_cfg.completion_source  = mailbox_completion::type_id::create(
        {name, "_completion"});
    return queue_cfg;
endfunction

host_mem_manager mem;
my_mailbox_adapter adapter;
my_mailbox_ptr_codec codec;
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
codec = my_mailbox_ptr_codec::type_id::create("codec");

cfg = mailbox_env_cfg::type_id::create("cfg");
cfg.mem       = mem;
cfg.adapter   = adapter;
cfg.ptr_codec = codec;

tx_1_cfg = make_mailbox_queue_cfg(
    "tx_1_cfg", GQ_TX, 1, 32, GQ_POLL, 100ns, 10us, codec);
tx_4095_cfg = make_mailbox_queue_cfg(
    "tx_4095_cfg", GQ_TX, 4095, 32, GQ_IRQ, 100ns, 10us, codec);
rx_2_cfg = make_mailbox_queue_cfg(
    "rx_2_cfg", GQ_RX, 2, 32, GQ_POLL, 100ns, 10us, codec);
rx_3000_cfg = make_mailbox_queue_cfg(
    "rx_3000_cfg", GQ_RX, 3000, 32, GQ_IRQ, 100ns, 10us, codec);

if (!cfg.add_queue(tx_1_cfg, reason) ||
    !cfg.add_queue(tx_4095_cfg, reason) ||
    !cfg.add_queue(rx_2_cfg, reason) ||
    !cfg.add_queue(rx_3000_cfg, reason))
    `uvm_fatal("QUEUE_CFG", reason)

uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", cfg);
env = mailbox_env::type_id::create("env", this);
```

The mailbox configuration validates IDs in `0..4095`, power-of-two depths in
`32..65536`, 64-byte TX descriptors, and 16-byte RX descriptors. A successful
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

Keep all wrap decisions in the codec and use `gq_phase(sequence, depth)` for
the descriptor phase. The concrete codec belongs to the user project because
the raw head/tail representation is DUT-specific.

## Submit TX work

The same sequence represents a single request or an atomic batch. Descriptor
ownership transfers only after a successful commit.

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

## Select poll or IRQ completion

Poll and IRQ modes share the same ordered drain path. Select `wait_mode`,
`poll_interval`, and `completion_timeout` on each `gq_queue_cfg` before its
successful `add_queue`, as shown in the configuration example above. Do not
change those values through `cfg.queues` after ownership transfers.

In IRQ mode the adapter implements `wait_irq()` and `ack_irq()`. The timeout
also bounds an IRQ wait. Completion diagnostics start their age after the tail
publish returns and report an oldest-outstanding episode once, including role,
queue ID, head, tail, slot, phase, ring/slot addresses, and descriptor bytes.

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
to end, the environment raises its own objection, stops completion workers,
releases outstanding descriptor buffers, disables every enabled queue, frees
every ring, runs the one shared memory leak check, and then drops its objection.
This automatic finalization is safe after runtime reset. Explicit early calls
to `cleanup_and_check_leaks()` remain supported; concurrent or repeated calls
join the same idempotent finalization.

```systemverilog
phase.drop_objection(this);
```

## Run with VCS

On a machine where VCS and the UVM license environment are already loaded:

```bash
make run TEST=gq_regression_test
```

The repository helper copies a clean source snapshot to `10.11.10.53`, enters
the host's interactive login environment, builds with VCS, runs one test, and
removes the remote temporary directory:

```bash
./scripts/run_vcs_remote.sh gq_regression_test
```

Run the complete checked regression with these exact commands:

```bash
./scripts/run_vcs_remote.sh gq_config_test
./scripts/run_vcs_remote.sh mailbox_desc_test
./scripts/run_vcs_remote.sh gq_submit_test
./scripts/run_vcs_remote.sh gq_completion_test
./scripts/run_vcs_remote.sh gq_refill_test
./scripts/run_vcs_remote.sh gq_reset_test
./scripts/run_vcs_remote.sh gq_regression_test
```

The underlying remote command used by the helper is:

```bash
ssh ubuntu@10.11.10.53 \
  "cd '<temporary-copy>' && bash -lc 'bash -ic \"make run TEST=gq_regression_test\"'"
```
