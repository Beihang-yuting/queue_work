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

```systemverilog
host_mem_manager mem;
mailbox_mock_adapter adapter;
gq_test_ptr_codec codec;
mailbox_env_cfg cfg;
mailbox_env env;
string reason;

mem = new("mem");
mem.init_region(64'h0000_0001_0000_0000,
                64'h0000_0001_00ff_ffff, MODE_LINEAR, 16);
adapter = mailbox_mock_adapter::type_id::create("adapter");
codec = gq_test_ptr_codec::type_id::create("codec");

cfg = mailbox_env_cfg::type_id::create("cfg");
cfg.mem       = mem;
cfg.adapter   = adapter;
cfg.ptr_codec = codec;
if (!cfg.add_tx(1, 32, reason) ||
    !cfg.add_tx(4095, 32, reason) ||
    !cfg.add_rx(2, 32, reason) ||
    !cfg.add_rx(3000, 32, reason))
    `uvm_fatal("QUEUE_CFG", reason)

uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", cfg);
env = mailbox_env::type_id::create("env", this);
```

The mailbox configuration validates IDs in `0..4095`, power-of-two depths in
`32..65536`, 64-byte TX descriptors, and 16-byte RX descriptors. A successful
`add_queue` transfers ownership of that queue configuration to the environment;
finish all per-queue changes before build starts.

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
the descriptor phase. `gq_test_ptr_codec` is a compact reference implementation.

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

Poll and IRQ modes share the same ordered drain path. Select the mode before
the configuration is consumed:

```systemverilog
cfg.queues["tx_1"].wait_mode = GQ_POLL;
cfg.queues["tx_1"].poll_interval = 100ns;

cfg.queues["tx_4095"].wait_mode = GQ_IRQ;
cfg.queues["tx_4095"].completion_timeout = 10us;
```

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

Before dropping the test's final objection, call the environment-level final
cleanup. It stops completion workers, releases outstanding descriptor buffers,
disables every enabled queue, frees every ring, and then runs the one shared
memory leak check. The call is idempotent and safe after runtime reset.

```systemverilog
env.cleanup_and_check_leaks();
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
