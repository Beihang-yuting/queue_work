# Generic Queue UVM Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable UVM descriptor-queue environment, derive a functional mailbox environment from it, and pass the full mock-hardware regression under VCS on `10.11.10.53`.

**Architecture:** The common `gq` package owns sparse queue construction, ring memory, logical sequence/phase state, submission, ordered completion, refill, and reset. Descriptor formats, hardware access, completion storage, and 32-bit pointer encoding are abstract strategies; `mailbox_pkg` supplies 64-byte TX and 16-byte RX descriptors plus descriptor-writeback completion. Tests use the real `host_mem_manager` and a mock adapter/DUT sharing the same `host_mem_api`.

**Tech Stack:** SystemVerilog, UVM 1.2, VCS, Git submodule `host_mem`, bash/rsync/SSH for remote validation.

---

## File Map

Create or track these focused files:

```text
.gitignore
.gitmodules
Makefile
scripts/run_vcs_remote.sh
host_mem/

src/gq/gq_pkg.sv
src/gq/gq_types.sv
src/gq/gq_desc_base.sv
src/gq/gq_ptr_codec.sv
src/gq/gq_hw_adapter.sv
src/gq/gq_completion_source.sv
src/gq/gq_tail_mem_completion.sv
src/gq/gq_wait_policy.sv
src/gq/gq_queue_cfg.sv
src/gq/gq_refill_profile.sv
src/gq/gq_request.sv
src/gq/gq_queue_engine.sv
src/gq/gq_agent.sv
src/gq/gq_reset_controller.sv
src/gq/gq_env_cfg.sv
src/gq/gq_env.sv

src/mailbox/mailbox_pkg.sv
src/mailbox/mailbox_tx_desc.sv
src/mailbox/mailbox_rx_desc.sv
src/mailbox/mailbox_completion.sv
src/mailbox/mailbox_refill_profile.sv
src/mailbox/mailbox_sequences.sv
src/mailbox/mailbox_env.sv

tb/mocks/gq_test_ptr_codec.sv
tb/mocks/mailbox_mock_adapter.sv
tb/mocks/mailbox_mock_dut.sv
tb/tests/gq_config_test.sv
tb/tests/mailbox_desc_test.sv
tb/tests/gq_submit_test.sv
tb/tests/gq_completion_test.sv
tb/tests/gq_refill_test.sv
tb/tests/gq_reset_test.sv
tb/tests/gq_regression_test.sv
tb/gq_test_pkg.sv
tb/tb_top.sv
```

## Task 1: Dependency and Remote VCS Harness

**Files:**
- Create: `.gitignore`
- Create: `.gitmodules` through `git submodule add`
- Track: `host_mem/`
- Create: `Makefile`
- Create: `scripts/run_vcs_remote.sh`
- Create: `src/gq/gq_pkg.sv`
- Create: `src/mailbox/mailbox_pkg.sv`
- Create: `tb/gq_test_pkg.sv`
- Create: `tb/tb_top.sv`

- [ ] **Step 1: Create an isolated implementation worktree**

Invoke `superpowers:using-git-worktrees`, create a feature worktree from commit
`66774c1`, and verify `git status --short` is empty.

- [ ] **Step 2: Register the memory manager dependency**

Run:

```bash
git submodule add -b master https://github.com/Beihang-yuting/host_mem.git host_mem
git -C host_mem checkout 3b9e000
git add .gitmodules host_mem
```

Expected: `git diff --cached --submodule` shows gitlink `3b9e000`.

- [ ] **Step 3: Write a compile test that initially references missing packages**

Create `tb/tb_top.sv`:

```systemverilog
module tb_top;
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import gq_pkg::*;
  import mailbox_pkg::*;
  import gq_test_pkg::*;
  initial run_test();
endmodule
```

Run the direct VCS command on `10.11.10.53` before creating the two packages.
Expected: compilation fails with missing `gq_pkg` and `mailbox_pkg`.

- [ ] **Step 4: Add minimal packages and smoke test**

Create `src/gq/gq_pkg.sv`:

```systemverilog
package gq_pkg;
  import uvm_pkg::*;
  import host_mem_pkg::*;
  `include "uvm_macros.svh"
endpackage
```

Create `src/mailbox/mailbox_pkg.sv`:

```systemverilog
package mailbox_pkg;
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import gq_pkg::*;
  `include "uvm_macros.svh"
endpackage
```

Create `tb/gq_test_pkg.sv`:

```systemverilog
package gq_test_pkg;
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import gq_pkg::*;
  import mailbox_pkg::*;
  `include "uvm_macros.svh"
  `include "host_mem_manager.sv"

  class gq_smoke_test extends uvm_test;
    `uvm_component_utils(gq_smoke_test)
    function new(string name = "gq_smoke_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
  endclass
endpackage
```

- [ ] **Step 5: Add deterministic VCS and remote-run commands**

Create `Makefile`:

```make
TEST ?= gq_smoke_test
VCS ?= vcs
SIMV := build/simv
VCS_FLAGS := -full64 -sverilog +v2k -ntb_opts uvm-1.2 -timescale=1ns/1ps
INCDIRS := +incdir+host_mem/src +incdir+src/gq +incdir+src/mailbox +incdir+tb
SOURCES := host_mem/src/host_mem_pkg.sv \
           src/gq/gq_pkg.sv src/mailbox/mailbox_pkg.sv \
           tb/gq_test_pkg.sv tb/tb_top.sv

.PHONY: vcs run clean
vcs:
	mkdir -p build
	$(VCS) $(VCS_FLAGS) $(INCDIRS) $(SOURCES) -o $(SIMV) -l build/compile.log

run: vcs
	$(SIMV) +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=UVM_MEDIUM -l build/$(TEST).log

clean:
	rm -f build/simv build/compile.log build/$(TEST).log
```

Create executable `scripts/run_vcs_remote.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

test_name="${1:-gq_smoke_test}"
remote_host="${GQ_REMOTE_HOST:-ubuntu@10.11.10.53}"
remote_dir="$(ssh "${remote_host}" 'mktemp -d /tmp/gq_uvm.XXXXXX')"

case "${test_name}" in
  *[!A-Za-z0-9_]*) echo "invalid test name: ${test_name}" >&2; exit 2 ;;
esac

case "${remote_dir}" in
  /tmp/gq_uvm.*) ;;
  *) echo "unexpected remote directory: ${remote_dir}" >&2; exit 2 ;;
esac

rsync -az --exclude=.git --exclude=.superpowers --exclude=build \
  ./ "${remote_host}:${remote_dir}/"
ssh "${remote_host}" "bash -lc 'cd ${remote_dir} && make run TEST=${test_name}'"
```

Create `.gitignore`:

```gitignore
.superpowers/
build/
csrc/
simv*
*.daidir/
*.log
ucli.key
vc_hdrs.h
```

- [ ] **Step 6: Run the remote smoke test**

```bash
chmod +x scripts/run_vcs_remote.sh
scripts/run_vcs_remote.sh gq_smoke_test
```

Expected: VCS exits zero with zero UVM errors and fatals.

- [ ] **Step 7: Commit**

```bash
git add .gitignore .gitmodules Makefile scripts host_mem src tb
git commit -m "build: add host memory dependency and VCS harness"
```

## Task 2: Common Types, Strategy Contracts, and Configuration

**Files:**
- Create: `src/gq/gq_types.sv`
- Create: `src/gq/gq_ptr_codec.sv`
- Create: `src/gq/gq_hw_adapter.sv`
- Create: `src/gq/gq_completion_source.sv`
- Create: `src/gq/gq_queue_cfg.sv`
- Modify: `src/gq/gq_pkg.sv`
- Create: `tb/tests/gq_config_test.sv`
- Modify: `tb/gq_test_pkg.sv`

- [ ] **Step 1: Write failing width, phase, and validation tests**

The test must assert:

```systemverilog
if ($bits(gq_addr_t) != 64) `uvm_fatal("WIDTH", "gq_addr_t")
if ($bits(gq_raw_ptr_t) != 32) `uvm_fatal("WIDTH", "gq_raw_ptr_t")
if (gq_phase(0, 32) != 1) `uvm_fatal("PHASE", "initial")
if (gq_phase(31, 32) != 1) `uvm_fatal("PHASE", "early wrap")
if (gq_phase(32, 32) != 0) `uvm_fatal("PHASE", "missing wrap")

cfg.depth = 48;
cfg.desc_size = 64;
cfg.alignment = 16;
cfg.poll_interval = 10ns;
cfg.completion_timeout = 1us;
if (cfg.validate(reason)) `uvm_fatal("CFG", "accepted depth 48")
cfg.depth = 32;
if (!cfg.validate(reason)) `uvm_fatal("CFG", reason)
```

Run `scripts/run_vcs_remote.sh gq_config_test`.
Expected: compilation fails because types/classes do not exist.

- [ ] **Step 2: Implement widths and helpers**

Create `gq_types.sv`:

```systemverilog
typedef bit [63:0] gq_addr_t;
typedef bit [31:0] gq_raw_ptr_t;
typedef longint unsigned gq_logical_seq_t;

typedef enum bit { GQ_TX, GQ_RX } gq_role_e;
typedef enum bit { GQ_POLL, GQ_IRQ } gq_wait_mode_e;
typedef enum int { GQ_OK, GQ_RESOURCE_ERROR, GQ_ABORTED_BY_RESET } gq_status_e;

function automatic bit gq_is_pow2(int unsigned value);
  return value >= 2 && ((value & (value - 1)) == 0);
endfunction

function automatic bit gq_phase(gq_logical_seq_t seq, int unsigned depth);
  return (((seq / depth) & 1) == 0);
endfunction

function automatic string gq_queue_key(gq_role_e role, int unsigned queue_id);
  return $sformatf("%s_%0d", role == GQ_TX ? "tx" : "rx", queue_id);
endfunction
```

- [ ] **Step 3: Implement stable strategy interfaces**

Use these exact signatures:

```systemverilog
virtual class gq_ptr_codec extends uvm_object;
  pure virtual function gq_raw_ptr_t encode_publish(
    gq_logical_seq_t old_tail, gq_logical_seq_t new_tail,
    int unsigned depth);
  virtual function bit decode_completion(
    gq_raw_ptr_t raw, gq_logical_seq_t logical_head,
    int unsigned depth, output gq_logical_seq_t completed_tail);
    completed_tail = logical_head;
    return 0;
  endfunction
endclass

virtual class gq_hw_adapter extends uvm_object;
  pure virtual task configure_queue(gq_role_e role, int unsigned queue_id,
    gq_addr_t base, int unsigned depth, int unsigned desc_size);
  pure virtual task disable_queue(gq_role_e role, int unsigned queue_id);
  pure virtual task publish(gq_role_e role, int unsigned queue_id,
    gq_raw_ptr_t raw_tail);
  pure virtual task wait_irq(gq_role_e role, int unsigned queue_id);
  pure virtual task ack_irq(gq_role_e role, int unsigned queue_id);
endclass
```

Forward-declare `gq_desc_base` and `gq_completion_source` before configuration.
The non-null strategy checks are added when the corresponding concrete test
doubles exist in Tasks 4 and 6.

- [ ] **Step 4: Implement queue configuration validation**

`gq_queue_cfg::validate(output string reason)` returns zero for zero descriptor
size/alignment, non-power-of-two depth, zero poll interval in poll mode, or
zero completion timeout. It reports a concrete reason string and does not
issue UVM reports. Later tasks extend validation for non-null strategies once
their interfaces and test doubles are available. The environment converts a
failed validation into `UVM_FATAL` before memory allocation.

- [ ] **Step 5: Run and commit**

```bash
scripts/run_vcs_remote.sh gq_config_test
git add src/gq tb/tests/gq_config_test.sv tb/gq_test_pkg.sv
git commit -m "feat: define generic queue contracts and configuration"
```

## Task 3: Descriptor Ownership and Mailbox Packing

**Files:**
- Create: `src/gq/gq_desc_base.sv`
- Create: `src/mailbox/mailbox_tx_desc.sv`
- Create: `src/mailbox/mailbox_rx_desc.sv`
- Modify: package include files
- Create: `tb/tests/mailbox_desc_test.sv`

- [ ] **Step 1: Write failing little-endian descriptor tests**

Initialize real memory:

```systemverilog
mem = new("mem");
mem.init_region(64'h1000_0000, 64'h10ff_ffff, MODE_LINEAR, 16);
```

Set TX flags `16'h0001`, IDs `1122/3344/5566`, `buf_len=4`,
`data_len=3`, and inline bytes `aa/bb/cc`. Assert:

```systemverilog
if (packed.size() != 64) `uvm_fatal("TXLE", "size")
if (packed[2] != 8'h22 || packed[3] != 8'h11) `uvm_fatal("TXLE", "srcid")
if (packed[20] != 8'haa || packed[21] != 8'hbb ||
    packed[22] != 8'hcc) `uvm_fatal("TXLE", "inline")
```

For RX, set `buf_len=32'h100` and assert 16-byte size, length in bytes 4..7,
and the 64-bit address in bytes 8..15. Expected initial compile failure.

- [ ] **Step 2: Implement owned allocation helpers**

`gq_desc_base` stores `host_mem_api mem`, `gq_addr_t owned_addrs[$]`, and a
released bit:

```systemverilog
function gq_addr_t alloc_owned(int unsigned size, int unsigned align = 1);
  gq_addr_t addr;
  addr = mem.alloc(size, align, `__FILE__, `__LINE__);
  if (addr != '1) owned_addrs.push_back(addr);
  return addr;
endfunction

function void release_owned();
  if (released) return;
  foreach (owned_addrs[i]) mem.free(owned_addrs[i], `__FILE__, `__LINE__);
  owned_addrs.delete();
  released = 1;
endfunction
```

Define virtual `prepare`, `mark_available`, `pack`, `unpack`,
`is_complete`, and `parse_completion` methods. Byte arrays use `byte` to match
`host_mem_api`.

- [ ] **Step 3: Implement mailbox TX**

Use `bit [511:0] raw` and copy `raw[i*8 +: 8]` into `data[i]`. Constrain
`data_len<=44`. Allocate/write external randomized data only when
`buf_len!=0`. Mailbox publishes fixed `avail=1, used=0` ownership flags on
every traversal and completes when `used==1`; the generic phase argument is
ignored by mailbox descriptors.

- [ ] **Step 4: Implement mailbox RX**

Use `bit [127:0] raw` with flags `[15:0]`, reserved zero `[31:16]`,
`buf_len[63:32]`, and `buf_addr[127:64]`. Allocate exactly `buf_len` bytes.
On completion, read exactly `buf_len` bytes into `rx_data`.

- [ ] **Step 5: Verify data and idempotent release**

Read back all four external TX bytes, call `release_owned()` twice, release RX,
and run `mem.leak_check()`. Expected: no double-free fatal and no leak warning.

- [ ] **Step 6: Run and commit**

```bash
scripts/run_vcs_remote.sh mailbox_desc_test
git add src/gq src/mailbox tb/tests/mailbox_desc_test.sv tb/gq_test_pkg.sv
git commit -m "feat: add mailbox descriptor formats and owned buffers"
```

## Task 4: Sparse Environment and Up-Front Ring Allocation

**Files:**
- Create: `src/gq/gq_queue_engine.sv`
- Create: `src/gq/gq_agent.sv`
- Create: `src/gq/gq_env_cfg.sv`
- Create: `src/gq/gq_env.sv`
- Create: `src/mailbox/mailbox_env.sv`
- Create: `tb/mocks/gq_test_ptr_codec.sv`
- Create: `tb/mocks/mailbox_mock_adapter.sv`
- Modify: `tb/tests/gq_config_test.sv`

- [ ] **Step 1: Write failing sparse allocation test**

Enable TX 3 and 100 at depth 32, and RX 9 at depth 64. Assert three agents,
TX ring size `32*64`, RX ring size `64*16`, and no TX 4 agent. Expected:
missing environment API compile failure.

- [ ] **Step 2: Implement test codec and adapter recorder**

The codec returns low 16 bits of `new_tail` and phase in bit 16:

```systemverilog
return gq_raw_ptr_t'({15'b0, gq_phase(new_tail, depth),
                      new_tail[15:0]});
```

The adapter records configure/disable/publish calls by
`gq_queue_key(role,id)` and provides one IRQ event per enabled queue.

- [ ] **Step 3: Implement sparse assembly and mailbox limits**

`gq_env_cfg` stores `gq_queue_cfg queues[string]`. Build only those entries.
Create a minimal `gq_queue_agent` that owns one `gq_queue_engine`; submission
driver/sequencer support is added in Task 5. Require a non-null pointer codec
before creating the engine.
`mailbox_env_cfg.add_tx` forces 64-byte descriptors; `add_rx` forces 16-byte
descriptors. Reject IDs above 4095 and depths outside inclusive 32..32768 or
not power-of-two.

- [ ] **Step 4: Allocate exact ring capacity**

Calculate:

```systemverilog
longint unsigned ring_bytes;
ring_bytes = cfg.depth;
ring_bytes = (ring_bytes * cfg.desc_size) + cfg.status_area_size;
```

Reject overflow and values above `32'hffff_ffff`, allocate once, and call
`configure_queue` with the 64-bit base. Compute
`status_addr=ring_base+(depth*desc_size)`. `gq_env.run_phase` initializes all
enabled engines before accepting sequence requests and triggers an
`env_ready` event after the last configure task; tests and virtual sequences
wait for that event. Expose read-only test accessors.

- [ ] **Step 5: Run and commit**

```bash
scripts/run_vcs_remote.sh gq_config_test
git add src/gq src/mailbox tb/mocks tb/tests/gq_config_test.sv
git commit -m "feat: allocate sparse enabled queue rings"
```

## Task 5: Single Submit and Atomic Batch Publish

**Files:**
- Create: `src/gq/gq_request.sv`
- Modify: `src/gq/gq_queue_engine.sv`
- Modify: `src/gq/gq_agent.sv`
- Create: `src/mailbox/mailbox_sequences.sv`
- Create: `tb/tests/gq_submit_test.sv`
- Modify: package include files

- [ ] **Step 1: Write failing single/batch tests**

Submit one TX descriptor and expect one raw-tail publish at logical tail 1.
Submit three as one request and expect exactly one more publish at tail 4.
Add a failing descriptor as member two of a batch and assert resource-error,
unchanged tail, and no publish.

- [ ] **Step 2: Implement typed requests**

Define `typedef enum bit {GQ_SUBMIT, GQ_START_RX} gq_request_kind_e` now so the
type remains unchanged when refill is added. `gq_request` uses `GQ_SUBMIT` in
this task and contains `gq_desc_base descs[$]`. `gq_response` contains status,
committed count, and reset epoch. Use explicit `add_desc` and `size` methods;
do not automate class-handle queues.

- [ ] **Step 3: Implement capacity and engine state**

Store monotonic head/tail and outstanding descriptors keyed by logical
sequence. Capacity is `tail-head`. A `uvm_event space_available` wakes
submitters after drain/reset. Reserve capacity for the whole batch before
preparing member one.

- [ ] **Step 4: Implement prepare/commit/rollback**

For every member: attach memory, prepare, apply slot phase, pack exact length,
and write its ring slot. On any failure release every batch member, leave
logical tail unchanged, and do not publish. On success install all handles,
advance tail once, encode old/new tail, and publish once.

- [ ] **Step 5: Connect agent driver**

Create `gq_sequencer extends uvm_sequencer#(gq_request)` and
`gq_driver extends uvm_driver#(gq_request)`. The driver calls
`engine.wait_ready()` before accepting its first item, calls `submit_batch`,
sets a typed response, and calls `item_done` exactly once for success,
resource error, and reset abort.

Add `mailbox_tx_sequence extends uvm_sequence#(gq_request)`. It owns a queue of
`mailbox_tx_desc` handles; its body builds one `GQ_SUBMIT` request containing
all queued descriptors. One descriptor gives single publish, while multiple
descriptors give one atomic batch publish.

- [ ] **Step 6: Run and commit**

```bash
scripts/run_vcs_remote.sh gq_submit_test
git add src/gq tb/tests/gq_submit_test.sv tb/gq_test_pkg.sv
git commit -m "feat: submit descriptors with atomic batch publish"
```

## Task 6: Ordered Completion, Poll/IRQ, and Phase Wrap

**Files:**
- Complete: `src/gq/gq_completion_source.sv`
- Create: `src/gq/gq_tail_mem_completion.sv`
- Create: `src/gq/gq_wait_policy.sv`
- Create: `src/mailbox/mailbox_completion.sv`
- Create: `tb/mocks/mailbox_mock_dut.sv`
- Create: `tb/tests/gq_completion_test.sv`
- Modify: `src/gq/gq_queue_engine.sv`

- [ ] **Step 1: Write failing ordered completion test**

Submit three descriptors. Complete slots 0 and 2, drain, and assert only slot
0 retires. Complete slot 1, drain, and assert 1 then 2 retire through the
analysis port.

- [ ] **Step 2: Define completion query**

```systemverilog
pure virtual function int unsigned completed_count(
  host_mem_api mem,
  gq_addr_t ring_base,
  gq_addr_t status_addr,
  int unsigned depth,
  int unsigned desc_size,
  gq_logical_seq_t logical_head,
  input gq_desc_base pending[$]);
```

The source never mutates engine state.
Extend final queue validation here to reject a null completion source. The
mailbox environment installs `mailbox_completion` for every TX and RX queue,
so the check runs before completion workers start.

- [ ] **Step 3: Implement the reusable trailing-memory source**

`gq_tail_mem_completion` stores a pointer codec, byte offset inside the status
area, and byte order. It reads four bytes from `status_addr+offset`, assembles
one `gq_raw_ptr_t`, calls `decode_completion`, and returns
`completed_tail-logical_head`. It returns zero when decode fails and reports a
count above `pending.size()` to the engine as a protocol violation. Extend the
test codec with a matching decode method and verify little- and big-endian raw
loads in the focused completion test.

- [ ] **Step 4: Implement mailbox descriptor writeback**

For each pending item, read its ring slot, unpack into the descriptor, compute
phase from `logical_head+i`, and stop at the first incomplete item.

- [ ] **Step 5: Implement drain and analysis**

For every returned completion: parse, write the descriptor to analysis port,
release owned memory, delete outstanding state, increment head. Trigger
`space_available` after a nonzero drain. A count above outstanding reports
`UVM_ERROR` and retires nothing.

- [ ] **Step 6: Implement wait policies**

Poll waits `cfg.poll_interval`. IRQ calls adapter `wait_irq` then `ack_irq`.
Both invoke the same `drain_completed` after waking.

- [ ] **Step 7: Test wrap and equivalent wake modes**

At depth 32, complete one full traversal, reuse slot zero, and assert pending
flags change from avail 1/used 0 to avail 0/used 1. Run identical completions
under poll and IRQ and compare order.

- [ ] **Step 8: Run and commit**

```bash
scripts/run_vcs_remote.sh gq_completion_test
git add src/gq src/mailbox tb/mocks tb/tests/gq_completion_test.sv
git commit -m "feat: drain ordered completions in poll and IRQ modes"
```

## Task 7: One-Shot RX Startup and DUT-Driven Refill

**Files:**
- Create: `src/gq/gq_refill_profile.sv`
- Create: `src/mailbox/mailbox_refill_profile.sv`
- Modify: `src/mailbox/mailbox_sequences.sv`
- Modify: `src/gq/gq_request.sv`
- Modify: `src/gq/gq_queue_engine.sv`
- Create: `tb/tests/gq_refill_test.sv`

- [ ] **Step 1: Write failing startup test**

Start RX once with initial 8, low 3, high 7, and deterministic lengths
`64+logical_seq`. Expect one publish at tail 8 and eight buffers. Wait without
DUT progress and assert no refill or second publish.

- [ ] **Step 2: Define persistent profile**

Store initial/low/high and `bit restart_after_reset`. Add:

```systemverilog
pure virtual function gq_desc_base create_desc(
  int unsigned queue_id, gq_logical_seq_t logical_seq);
```

Validate `low<high<=depth` and `initial<=depth`. The engine clones the profile.

- [ ] **Step 3: Implement mailbox provider**

Provide virtual `choose_buf_len(logical_seq)`. Default randomizes a positive
length within configured min/max; the test subclass returns
`64+logical_seq`.

- [ ] **Step 4: Implement startup/refill**

Handle the previously defined request kind `GQ_START_RX`. Reject it on TX.
Clone the profile, publish the initial batch, then set `rx_started`. Only after
a nonzero DUT drain compute
`posted=tail-head`; if `posted<=low`, create `high-posted` items and publish
once. No timer or later sequence triggers refill.

Add `mailbox_rx_start_sequence extends uvm_sequence#(gq_request)`. Its body
sends exactly one `GQ_START_RX` request containing the refill profile and then
finishes; the cloned profile, not the sequence object, owns later generation.

- [ ] **Step 5: Prove watermark behavior**

Complete five of eight. Expect posted 3, four new descriptors, logical tail 12,
and exactly one additional publish. Verify old buffers free before replacements.

- [ ] **Step 6: Run and commit**

```bash
scripts/run_vcs_remote.sh gq_refill_test
git add src/gq src/mailbox tb/tests/gq_refill_test.sv
git commit -m "feat: refill RX queues from DUT completion progress"
```

## Task 8: Runtime Reset and RX Recovery Choice

**Files:**
- Modify: `src/gq/gq_queue_engine.sv`
- Modify: `src/gq/gq_env.sv`
- Modify: `src/gq/gq_agent.sv`
- Create: `src/gq/gq_reset_controller.sv`
- Create: `tb/tests/gq_reset_test.sv`

- [ ] **Step 1: Write failing reset-abort test**

Create two outstanding TX items and active RX. Assert reset; expect zero
outstanding and two adapter disable calls. Release reset; expect new valid ring
addresses and head/tail zero.

- [ ] **Step 2: Add reset events and epochs**

`gq_env_cfg` owns asserted/deasserted `uvm_event` objects. A
`gq_reset_controller` registers every sparse engine, waits on those two events,
and calls each engine's reset-assert/reset-release entry point in deterministic
queue-key order. Each engine increments epoch at assertion. Submit, wait,
completion, and refill capture the epoch and discard stale results after a
change.

- [ ] **Step 3: Implement cleanup/reinitialize**

On assertion reject requests, stop workers, release outstanding, free ring,
zero state, and disable queue. An interrupted request returns
`GQ_ABORTED_BY_RESET`. On deassertion reallocate/configure the ring and restart
workers.

- [ ] **Step 4: Test both RX recovery modes**

With `restart_after_reset=1`, retain a profile clone and republish its initial
batch. With `restart_after_reset=0`, clear the profile and publish nothing
until another startup request.

- [ ] **Step 5: Run and commit**

```bash
scripts/run_vcs_remote.sh gq_reset_test
git add src/gq tb/tests/gq_reset_test.sv tb/gq_test_pkg.sv
git commit -m "feat: recover queue engines across runtime reset"
```

## Task 9: Diagnostics, Cleanup, and Integrated Regression

**Files:**
- Modify: `src/gq/gq_queue_engine.sv`
- Modify: `src/gq/gq_env.sv`
- Create: `tb/tests/gq_regression_test.sv`
- Modify: `tb/gq_test_pkg.sv`
- Create: `README.md`

- [ ] **Step 1: Write failing integrated regression**

Enable TX 1/4095 and RX 2/3000. Exercise single/batch TX, RX refill, poll/IRQ,
phase wrap, and runtime reset. At shutdown require empty engines, freed rings,
and zero host-memory leaks.

- [ ] **Step 2: Add timeout/protocol diagnostics**

Track oldest outstanding time. At configured timeout issue one `UVM_ERROR`
with role, ID, head, tail, slot, phase, and ring address. A completion count
above outstanding emits the same state and retires nothing. Read the current
descriptor bytes through `host_mem_api.read_mem` and format those bytes in the
diagnostic message, keeping common code independent of concrete
`host_mem_manager` debug methods. Use a UVM report catcher in the focused
negative tests to count and demote the expected error; the full regression
must still finish with a zero-error UVM summary.

- [ ] **Step 3: Implement idempotent final cleanup**

Stop workers, release outstanding buffers, disable queues, free rings, and then
call leak check. Reset followed by final phase must not double-free.

- [ ] **Step 4: Document public usage**

`README.md` shows memory injection, sparse queues, descriptor/codec derivation,
TX single/batch requests, one-shot RX startup, poll/IRQ selection, reset events,
and exact VCS commands.

- [ ] **Step 5: Run all tests on 53**

```bash
for t in gq_config_test mailbox_desc_test gq_submit_test \
         gq_completion_test gq_refill_test gq_reset_test \
         gq_regression_test; do
  scripts/run_vcs_remote.sh "$t"
done
```

Expected for each: exit zero, `UVM_ERROR : 0`, `UVM_FATAL : 0`, and final zero
allocations.

- [ ] **Step 6: Commit**

```bash
git diff --check
git add README.md src tb
git commit -m "test: cover generic queue and mailbox integration"
```

## Task 10: Final Verification and Handoff

**Files:**
- Verify: `README.md`
- Verify: `src/gq/`
- Verify: `src/mailbox/`
- Verify: `tb/`
- No planned source changes; a discovered failure returns to its owning task

- [ ] **Step 1: Run a clean full regression**

Run all seven named tests again with `scripts/run_vcs_remote.sh` after the
final commit. Record VCS version and zero-error summaries for handoff; do not
commit logs.

- [ ] **Step 2: Verify repository state**

```bash
git status --short --branch
git submodule status
git diff HEAD --check
```

Expected: clean feature worktree and `host_mem` at `3b9e000`.

- [ ] **Step 3: Request code review**

Invoke `superpowers:requesting-code-review` against the approved design and
this plan. Fix correctness findings, rerun focused tests, then rerun
`gq_regression_test`.

- [ ] **Step 4: Present integration choices**

Invoke `superpowers:finishing-a-development-branch` and offer merge, PR, or
worktree-retention choices without changing the user's main branch.
