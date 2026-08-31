# Generic Queue Extensible Completion and Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `gq` with timed completion queries, reusable writeback and index/phase strategies, selectable RX slot lifecycles, bounded refill, and deterministic Poll/IRQ scheduling.

**Architecture:** `gq` remains protocol-neutral: completion sources interpret progress, wait policies only produce wake reasons, and the engine owns lifecycle linearization. Existing mailbox behavior is preserved by deriving its completion and pointer types from the new generic strategies.

**Tech Stack:** SystemVerilog, UVM 1.2, `host_mem`, VCS, GNU Make, bash/rsync/SSH.

**Spec:** `docs/superpowers/specs/2026-08-27-msgq-cmdq-tlpq-gq-reuse-design.md`

## Global Constraints

- Before Task 1, commit the existing mailbox adapter/pointer work and repository-owned `.svh` to `.sv` migration as a separate clean baseline; do not mix those changes into any task below.
- All repository-owned SystemVerilog files use `.sv`; only external `uvm_macros.svh` remains an `.svh` include.
- `gq` must not mention MSGQ, CMDQ, TLPQ, DPU register names, or PCIe TLP types.
- No state lock may be held across `configure_queue`, `disable_queue`, `publish`, `wait_irq`, `ack_irq`, or `query_completed`.
- Reset and cleanup must cancel waits, quiesce publish/query/ACK operations, reject stale epochs, and release each owned allocation exactly once.
- Run every simulation on `ubuntu@10.11.10.53` in a bash login shell; that host supplies VCS and its license environment.
- Directed timing tests use fixed 10 ns polling; CMDQ-facing defaults are verified separately as 10/20/40/80/100 ns.
- Each task starts from a clean index and commits only its listed files.

---

## File Map

```text
src/gq/gq_types.sv                         wake, poll, and RX lifecycle enums
src/gq/gq_completion_source.sv             timed completion-query contract
src/gq/gq_desc_writeback_completion.sv     contiguous descriptor completion
src/gq/gq_ptr_codec.sv                     existing abstract pointer contract
src/gq/gq_index_phase_ptr_codec.sv         reusable bit-15 phase codec
src/gq/gq_queue_cfg.sv                     timing and lifecycle validation
src/gq/gq_wait_policy.sv                   fixed/adaptive Poll and IRQ watchdog
src/gq/gq_desc_base.sv                     owned-allocation inspection
src/gq/gq_refill_profile.sv                bounded refill configuration
src/gq/gq_queue_engine.sv                  async query, wake, recycle, refill
src/gq/gq_pkg.sv                           public include order
src/mailbox/mailbox_completion.sv           compatibility-derived completion
src/mailbox/mailbox_ptr_codec.sv            compatibility-derived pointer codec
tb/mocks/gq_async_completion_source.sv      delayed/invalid query control
tb/tests/gq_async_completion_test.sv         timed query and stale epoch cases
tb/tests/gq_index_phase_ptr_codec_test.sv    bit placement and wrap cases
tb/tests/gq_timing_config_test.sv            configuration validation
tb/tests/gq_wait_policy_test.sv              deterministic wake scheduling
tb/tests/gq_worker_wakeup_test.sv            idle TX/new work/reset behavior
tb/tests/gq_auto_recycle_test.sv             no-rewrite/no-publish recycling
tb/tests/gq_refill_batch_test.sv             one-at-a-time explicit refill
tb/gq_test_pkg.sv                            test registration
Makefile                                     selectable business source lists
scripts/run_vcs_remote.sh                    selected-library remote execution
README.md                                    public timing/lifecycle contract
```

### Task 1: Timed Completion Contract and Generic Writeback

**Files:**
- Create: `src/gq/gq_desc_writeback_completion.sv`
- Create: `tb/mocks/gq_async_completion_source.sv`
- Create: `tb/tests/gq_async_completion_test.sv`
- Modify: `src/gq/gq_completion_source.sv`
- Modify: `src/gq/gq_tail_mem_completion.sv`
- Modify: `src/gq/gq_queue_engine.sv`
- Modify: `src/gq/gq_pkg.sv`
- Modify: `src/mailbox/mailbox_completion.sv`
- Modify: `tb/gq_test_pkg.sv`

**Interfaces:**
- Consumes: `gq_desc_base.unpack()`, `gq_desc_base.is_complete()`, the engine epoch and completion commit boundary.
- Produces: `gq_completion_source.query_completed(...)`; `gq_desc_writeback_completion` for mailbox, CMDQ, and TLPQ.

- [ ] **Step 1: Write the failing asynchronous-query tests**

Add a source whose task blocks on `release_query`, then returns controlled `valid` and `count` outputs:

```systemverilog
class gq_async_completion_source extends gq_completion_source;
    `uvm_object_utils(gq_async_completion_source)
    uvm_event query_entered = new("query_entered");
    uvm_event release_query = new("release_query");
    bit next_valid = 1;
    int unsigned next_count = 0;

    function new(string name = "gq_async_completion_source");
        super.new(name);
    endfunction

    virtual task query_completed(
        host_mem_api mem, gq_hw_adapter adapter, gq_addr_t ring_base,
        gq_addr_t status_addr, int unsigned depth, int unsigned desc_size,
        gq_logical_seq_t logical_head, input gq_desc_base pending[$],
        output bit valid, output int unsigned completed_count);
        query_entered.trigger();
        release_query.wait_on();
        valid = next_valid;
        completed_count = next_count;
    endtask
endclass
```

In `gq_async_completion_test`, assert that an invalid query retires zero, a delayed valid query does not hold `state_lock` (reset can enter), and a result returning after reset is discarded by epoch comparison. Add a writeback case that marks slots 0 and 1 used, leaves slot 2 incomplete, and expects count 2.

- [ ] **Step 2: Run the focused test and verify the old function contract fails compilation**

Run:

```bash
scripts/run_vcs_remote.sh gq_async_completion_test
```

Expected: VCS reports that `query_completed` and `gq_desc_writeback_completion` are undefined.

- [ ] **Step 3: Replace the completion function with the timed task**

Define the base contract exactly as follows and convert `gq_tail_mem_completion` to a zero-time implementation that sets `valid=0` on address/read/decode failure:

```systemverilog
pure virtual task query_completed(
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

Create `gq_desc_writeback_completion` with a zero-time `query_completed`: read each physical slot in logical order, require exactly `desc_size` bytes, call `pending[i].unpack(bytes)` and `pending[i].is_complete(gq_phase(logical_head+i, depth))`, and stop at the first false result. It returns `valid=1` for a well-formed incomplete head and `valid=0` for null memory, null pending entries, a short read, or unpack failure.

- [ ] **Step 4: Make engine query/commit asynchronous and epoch-safe**

In `drain_completed()`, snapshot head, epoch, ring/status addresses, and pending handles under `state_lock`; release the lock before calling:

```systemverilog
cfg.completion_source.query_completed(
    mem, adapter, query_ring_base, query_status_addr, cfg.depth,
    cfg.desc_size, query_head, pending, query_valid, count);
```

After the task, enter `completion_commit_boundary`, reacquire `state_lock`, discard invalid or stale results, and reject `count > pending.size()` or `count > logical_tail_seq-logical_head_seq`. Preserve ordered parsing and retirement. Convert mailbox completion into a thin subclass of `gq_desc_writeback_completion` so its public type remains available.

- [ ] **Step 5: Run async, mailbox completion, and reset-race tests**

```bash
scripts/run_vcs_remote.sh gq_async_completion_test
scripts/run_vcs_remote.sh gq_completion_test
scripts/run_vcs_remote.sh gq_reset_test
```

Expected: all three tests finish with zero UVM errors/fatals; the invalid and stale query cases retire zero descriptors.

- [ ] **Step 6: Commit the timed completion boundary**

```bash
git add src/gq/gq_completion_source.sv src/gq/gq_desc_writeback_completion.sv \
  src/gq/gq_tail_mem_completion.sv src/gq/gq_queue_engine.sv src/gq/gq_pkg.sv \
  src/mailbox/mailbox_completion.sv tb/mocks/gq_async_completion_source.sv \
  tb/tests/gq_async_completion_test.sv tb/gq_test_pkg.sv
git commit -m "feat(gq): support timed completion queries"
```

### Task 2: Reusable Index-and-Phase Pointer Codec

**Files:**
- Create: `src/gq/gq_index_phase_ptr_codec.sv`
- Create: `tb/tests/gq_index_phase_ptr_codec_test.sv`
- Modify: `src/gq/gq_pkg.sv`
- Modify: `src/mailbox/mailbox_ptr_codec.sv`
- Modify: `tb/gq_test_pkg.sv`

**Interfaces:**
- Consumes: `gq_ptr_codec.encode_publish(old_tail, new_tail, depth)`.
- Produces: `gq_index_phase_ptr_codec.new(name, index_width, phase_bit)` and validation reusable by business pointer subclasses.

- [ ] **Step 1: Write failing index/phase vectors**

Test depth 32 and require:

```systemverilog
if (codec.encode_publish(0, 1, 32)  != 32'h0000_0001) `uvm_error("PTR", "slot 1")
if (codec.encode_publish(31, 32, 32) != 32'h0000_8000) `uvm_error("PTR", "first wrap")
if (codec.encode_publish(63, 64, 32) != 32'h0000_0000) `uvm_error("PTR", "second wrap")
if (codec.validate_depth(32768, reason) != 1) `uvm_error("PTR", reason)
if (codec.validate_depth(65536, reason) != 0) `uvm_error("PTR", "index overflow accepted")
```

Also assert constructor validation rejects `index_width=0`, `phase_bit<index_width`, and `phase_bit>=32`.

- [ ] **Step 2: Run the pointer test and verify the type is missing**

```bash
scripts/run_vcs_remote.sh gq_index_phase_ptr_codec_test
```

Expected: VCS fails because `gq_index_phase_ptr_codec` is undefined.

- [ ] **Step 3: Add the generic codec and mailbox derivation**

Implement these public methods:

```systemverilog
function new(string name = "gq_index_phase_ptr_codec",
             int unsigned index_width = 15,
             int unsigned phase_bit = 15);
function bit validate_depth(int unsigned depth, output string reason);
virtual function gq_raw_ptr_t encode_publish(
    gq_logical_seq_t old_tail, gq_logical_seq_t new_tail,
    int unsigned depth);
```

`encode_publish` returns zero after a `GQ_PTR_CFG` error if validation fails; otherwise it places `new_tail % depth` in `[index_width-1:0]`, `(new_tail/depth)&1` in `phase_bit`, and zero elsewhere. Derive `mailbox_ptr_codec` from the generic class and call `super.new(name, 15, 15)`.

- [ ] **Step 4: Run pointer and mailbox wrap tests**

```bash
scripts/run_vcs_remote.sh gq_index_phase_ptr_codec_test
scripts/run_vcs_remote.sh mailbox_wrap_test
```

Expected: exact bit-15 wrap vectors pass and mailbox retains its public codec type.

- [ ] **Step 5: Commit the pointer strategy**

```bash
git add src/gq/gq_index_phase_ptr_codec.sv src/gq/gq_pkg.sv \
  src/mailbox/mailbox_ptr_codec.sv tb/tests/gq_index_phase_ptr_codec_test.sv \
  tb/gq_test_pkg.sv
git commit -m "feat(gq): add configurable index phase pointer codec"
```

### Task 3: Timing and RX Lifecycle Configuration

**Files:**
- Create: `tb/tests/gq_timing_config_test.sv`
- Modify: `src/gq/gq_types.sv`
- Modify: `src/gq/gq_queue_cfg.sv`
- Modify: `src/gq/gq_refill_profile.sv`
- Modify: `src/gq/gq_desc_base.sv`
- Modify: `src/mailbox/mailbox_env.sv`
- Modify: `tb/tests/gq_completion_test.sv`
- Modify: `tb/tests/gq_config_test.sv`
- Modify: `tb/tests/gq_refill_test.sv`
- Modify: `tb/tests/gq_regression_test.sv`
- Modify: `tb/tests/gq_reset_test.sv`
- Modify: `tb/tests/gq_submit_test.sv`
- Modify: `tb/gq_test_pkg.sv`

**Interfaces:**
- Consumes: existing `gq_wait_mode_e`, role, depth, and completion source validation.
- Produces: deterministic timing fields, RX lifecycle mode, bounded refill, and allocation inspection.

- [ ] **Step 1: Write the failing configuration matrix**

Exercise the following public types and fields:

```systemverilog
typedef enum bit { GQ_POLL_FIXED, GQ_POLL_ADAPTIVE } gq_poll_policy_e;
typedef enum bit { GQ_RX_EXPLICIT_REFILL, GQ_RX_AUTO_RECYCLE } gq_rx_slot_mode_e;
typedef enum int { GQ_WAKE_CANCELLED, GQ_WAKE_POLL, GQ_WAKE_IRQ,
                   GQ_WAKE_WATCHDOG, GQ_WAKE_NEW_WORK } gq_wakeup_e;

cfg.poll_policy = GQ_POLL_ADAPTIVE;
cfg.poll_min_interval = 10ns;
cfg.poll_max_interval = 100ns;
cfg.poll_backoff_factor = 2;
cfg.irq_watchdog_interval = 1us;
cfg.completion_timeout = 10us;
cfg.rx_slot_mode = GQ_RX_EXPLICIT_REFILL;
profile.max_refill_batch = 1;
```

Require validation failure for zero poll minimum, maximum below minimum, factor below one, unequal fixed bounds, TX timeout zero, and TX timeout not greater than poll maximum. Require RX timeout zero to pass. Use `uvm_report_catcher` to require a warning when a nonzero timeout is below four maximum intervals.

- [ ] **Step 2: Run the configuration test and verify fields are missing**

```bash
scripts/run_vcs_remote.sh gq_timing_config_test
```

Expected: VCS reports undefined timing/lifecycle members.

- [ ] **Step 3: Add defaults and exact validation**

Replace `poll_interval` with the four poll fields above. Defaults are fixed policy, `poll_min_interval=10ns`, `poll_max_interval=10ns`, factor 2, watchdog zero, explicit refill, and timeout unchanged for existing callers. Validation rules are:

```text
Poll mode: min > 0; max >= min; factor >= 1.
Fixed Poll: min == max.
TX: completion_timeout > poll_max_interval.
RX: completion_timeout == 0 is legal.
Nonzero timeout < 4 * poll_max_interval: emit GQ_CFG_TIMEOUT warning.
IRQ: watchdog 0 disables fallback; nonzero watchdog must be > 0.
```

Add `max_refill_batch` to `gq_refill_profile`, default zero, and copy it in `do_copy`. Add `gq_desc_base.owned_allocation_count()` returning `owned_allocations.size()` so auto-recycle can reject separately owned buffers.

- [ ] **Step 4: Update existing tests/config factories and run configuration regression**

Set both poll bounds wherever an existing test formerly assigned `poll_interval`. Keep mailbox fixed at its previous interval. Run:

```bash
scripts/run_vcs_remote.sh gq_timing_config_test
scripts/run_vcs_remote.sh gq_config_test
scripts/run_vcs_remote.sh gq_regression_test
```

Expected: validation matrix and all legacy configuration expectations pass.

- [ ] **Step 5: Commit timing and lifecycle configuration**

```bash
git add src/gq/gq_types.sv src/gq/gq_queue_cfg.sv src/gq/gq_refill_profile.sv \
  src/gq/gq_desc_base.sv src/mailbox/mailbox_env.sv \
  tb/tests/gq_timing_config_test.sv tb/tests/gq_completion_test.sv \
  tb/tests/gq_config_test.sv tb/tests/gq_refill_test.sv \
  tb/tests/gq_regression_test.sv tb/tests/gq_reset_test.sv \
  tb/tests/gq_submit_test.sv tb/gq_test_pkg.sv
git commit -m "feat(gq): configure polling and receive lifecycles"
```

### Task 4: Fixed/Adaptive Poll and IRQ Watchdog Policies

**Files:**
- Create: `tb/tests/gq_wait_policy_test.sv`
- Modify: `src/gq/gq_wait_policy.sv`
- Modify: `tb/mocks/mailbox_mock_adapter.sv`
- Modify: `tb/gq_test_pkg.sv`

**Interfaces:**
- Consumes: Task 3 `gq_wakeup_e` and timing fields.
- Produces: cancellable waits and `note_progress()`/`note_idle()` adaptive state.

- [ ] **Step 1: Write failing deterministic timing tests**

Instantiate a poll policy with CMDQ values and record `$time` after five idle waits. Require deltas `10ns,20ns,40ns,80ns,100ns`; call `note_progress()` and require the next delta to be 10 ns. Race a 100 ns wait against `new_work.trigger()` at 7 ns and require `GQ_WAKE_NEW_WORK` at 7 ns. For IRQ mode, require an IRQ at 20 ns to return `GQ_WAKE_IRQ`, and no IRQ with watchdog 50 ns to return `GQ_WAKE_WATCHDOG` without calling ACK.

- [ ] **Step 2: Run the policy test and verify the legacy signature fails**

```bash
scripts/run_vcs_remote.sh gq_wait_policy_test
```

Expected: compilation fails because the wait policy has no wake-reason, cancel, new-work, or adaptive interface.

- [ ] **Step 3: Define the cancellable policy contract**

Use this exact interface:

```systemverilog
pure virtual task wait_for_wakeup(
    gq_queue_cfg cfg,
    gq_hw_adapter adapter,
    uvm_event cancel_event,
    uvm_event new_work_event,
    output gq_wakeup_e wakeup);
virtual function void note_progress();
virtual function void note_idle();
```

The poll policy tracks `current_interval`; `note_progress()` resets it to minimum and `note_idle()` multiplies it by the factor with saturation. Its wait races the current timer, cancel, and new work. The IRQ policy races `adapter.wait_irq`, cancel, new work, and the watchdog only when nonzero. Use nested forks so `disable fork` cannot terminate another policy invocation.

- [ ] **Step 4: Run wait-policy timing tests**

```bash
scripts/run_vcs_remote.sh gq_wait_policy_test
```

Expected: all timestamps and wake reasons match exactly; watchdog wake produces zero ACK calls in the policy itself.

- [ ] **Step 5: Commit wait policies**

```bash
git add src/gq/gq_wait_policy.sv tb/mocks/mailbox_mock_adapter.sv \
  tb/tests/gq_wait_policy_test.sv tb/gq_test_pkg.sv
git commit -m "feat(gq): add adaptive polling and irq watchdog waits"
```

### Task 5: Worker Wakeups, ACK Semantics, and Timeout Control

**Files:**
- Create: `tb/tests/gq_worker_wakeup_test.sv`
- Modify: `src/gq/gq_queue_engine.sv`
- Modify: `tb/gq_test_pkg.sv`

**Interfaces:**
- Consumes: Task 1 timed queries and Task 4 wake reasons.
- Produces: TX idle sleep, IRQ-only ACK, watchdog query, and progress feedback.

- [ ] **Step 1: Write failing engine scheduling tests**

Cover these event traces:

```text
TX with zero outstanding for 1 us: zero completion queries.
Submit during a 100 ns adaptive wait: query begins without waiting 100 ns.
Real IRQ: WAIT_IRQ, ACK_IRQ, QUERY; exactly one ACK.
Spurious IRQ: ACK_IRQ, QUERY(valid,count=0); zero retirements.
Watchdog: WAIT_IRQ, QUERY; zero ACK.
Reset during Poll or IRQ wait: GQ_WAKE_CANCELLED and no post-reset query.
RX completion_timeout=0 during 20 us idle: no timeout report.
```

- [ ] **Step 2: Run the worker test and observe legacy ACK/timeout behavior fail**

```bash
scripts/run_vcs_remote.sh gq_worker_wakeup_test
```

Expected: at least the idle-TX query count, watchdog ACK count, and zero-timeout RX expectations fail.

- [ ] **Step 3: Separate query result from the public drain wrapper**

Add this protected engine seam:

```systemverilog
protected task drain_completed_once(
    output bit query_valid,
    output int unsigned retired_count);
```

Keep public `drain_completed()` as a wrapper for existing tests. `wait_and_drain_once()` ACKs only `GQ_WAKE_IRQ`, queries on `GQ_WAKE_IRQ`, `GQ_WAKE_WATCHDOG`, or `GQ_WAKE_POLL`, calls `note_progress()` when `retired_count>0`, and `note_idle()` after a valid zero-progress query. `GQ_WAKE_NEW_WORK` consumes/resets the event, calls `note_progress()` to restore the minimum interval, and begins a new wait rather than querying immediately. Query failure does not advance adaptive backoff.

- [ ] **Step 4: Add worker new-work and timeout gates**

Add `uvm_event new_work_event`; trigger it after a successful publish and during reset/cleanup cancellation. A TX worker with no published outstanding waits only for new work, reset, or cleanup. Guard timeout comparison with `cfg.completion_timeout != 0`; report the oldest published TX timeout once, never report an RX empty-window timeout when zero disables it.

- [ ] **Step 5: Run worker and lifecycle races**

```bash
scripts/run_vcs_remote.sh gq_worker_wakeup_test
scripts/run_vcs_remote.sh gq_reset_test
scripts/run_vcs_remote.sh gq_regression_test
```

Expected: all event order/count checks pass and no zero-time loop appears in the RX idle case.

- [ ] **Step 6: Commit engine wake scheduling**

```bash
git add src/gq/gq_queue_engine.sv tb/tests/gq_worker_wakeup_test.sv \
  tb/gq_test_pkg.sv
git commit -m "feat(gq): coordinate completion worker wakeups"
```

### Task 6: Auto-Recycle and Bounded Explicit Refill

**Files:**
- Create: `tb/tests/gq_auto_recycle_test.sv`
- Create: `tb/tests/gq_refill_batch_test.sv`
- Modify: `src/gq/gq_queue_engine.sv`
- Modify: `tb/mocks/mailbox_mock_adapter.sv`
- Modify: `tb/gq_test_pkg.sv`

**Interfaces:**
- Consumes: Task 3 `rx_slot_mode`, `owned_allocation_count()`, and `max_refill_batch`.
- Produces: depth-minus-one auto-recycle windows and one-at-a-time explicit refill.

- [ ] **Step 1: Write failing auto-recycle tests**

Start depth 8 RX with seven fixed-size entries and `GQ_RX_AUTO_RECYCLE`. Snapshot all ring bytes and publish history after activation. Complete three entries and require: three analysis deliveries, head/tail both advance by three, outstanding returns to seven, ring bytes are unchanged, and publish history still contains exactly the initial tail. Make a profile return an entry whose `prepare()` calls `alloc_owned(8)` and require activation to fail with `GQ_RX_AUTO_RECYCLE_ALLOC` before a tail is published.

- [ ] **Step 2: Write failing bounded-refill test**

Start explicit-refill depth 8 with seven entries and `max_refill_batch=1`. Complete three together and require three additional publish calls whose logical tails advance one each; with `max_refill_batch=0`, require the legacy single batched publish.

- [ ] **Step 3: Run both tests and verify current refill behavior fails**

```bash
scripts/run_vcs_remote.sh gq_auto_recycle_test
scripts/run_vcs_remote.sh gq_refill_batch_test
```

Expected: auto-recycle mode is absent and explicit refill publishes the three replacements as one batch.

- [ ] **Step 4: Add auto-recycle commit logic**

After ordered retirement, when the mode is auto-recycle, call `refill_profile.create_desc(queue_id, logical_tail_seq)` once per retired entry, attach memory, prepare, require zero owned allocations, mark it hardware-visible, install it at the new logical tail, and advance the logical tail. Do not pack/write the descriptor slot and do not call `adapter.publish`. If creation/preparation fails, report the named error and leave the shortened window diagnosable.

- [ ] **Step 5: Bound explicit refill iterations**

In each explicit-refill loop calculate:

```systemverilog
refill_count = active_profile.high_watermark - posted;
if (active_profile.max_refill_batch != 0 &&
    refill_count > active_profile.max_refill_batch)
    refill_count = active_profile.max_refill_batch;
```

Publish that batch, then recalculate until the high watermark is restored or reset/cleanup/publish cancellation wins.

- [ ] **Step 6: Run recycle, refill, reset, and mailbox regression**

```bash
scripts/run_vcs_remote.sh gq_auto_recycle_test
scripts/run_vcs_remote.sh gq_refill_batch_test
scripts/run_vcs_remote.sh gq_refill_test
scripts/run_vcs_remote.sh gq_reset_test
scripts/run_vcs_remote.sh gq_regression_test
```

Expected: all tests pass; mailbox retains batched explicit refill by default.

- [ ] **Step 7: Commit RX lifecycle behavior**

```bash
git add src/gq/gq_queue_engine.sv tb/mocks/mailbox_mock_adapter.sv \
  tb/tests/gq_auto_recycle_test.sv tb/tests/gq_refill_batch_test.sv \
  tb/gq_test_pkg.sv
git commit -m "feat(gq): support recyclable and bounded refill queues"
```

### Task 7: Selectable Build, Documentation, and Full Compatibility Gate

**Files:**
- Modify: `Makefile`
- Modify: `scripts/run_vcs_remote.sh`
- Modify: `scripts/check_sv_layout.sh`
- Modify: `tb/tb_top.sv`
- Modify: `README.md`

**Interfaces:**
- Consumes: all GQ features from Tasks 1-6.
- Produces: a build surface later plans extend with `msgq`, `cmdq`, and `tlpq`.

- [ ] **Step 1: Add a failing build-selector check**

Run:

```bash
make -n run LIBS=mailbox TEST=gq_smoke_test
make check-layout
```

Expected before the Makefile change: `LIBS` has no effect; the layout check does not yet require the new GQ source files.

- [ ] **Step 2: Add comma-separated library selection**

Use this Make structure so later plans only append maps:

```make
LIBS ?= mailbox
comma := ,
LIB_LIST := $(subst $(comma), ,$(LIBS))
LIB_SOURCE_mailbox := src/mailbox/mailbox_pkg.sv
LIB_SOURCES := $(foreach lib,$(LIB_LIST),$(LIB_SOURCE_$(lib)))
LIB_INCDIRS := $(foreach lib,$(LIB_LIST),+incdir+src/$(lib))
TEST_SUITE ?= gq
TEST_PACKAGE_gq := tb/gq_test_pkg.sv
TEST_DEFINE_gq := +define+QUEUE_TEST_GQ
TEST_PACKAGE_SOURCE := $(TEST_PACKAGE_$(TEST_SUITE))
UNKNOWN_LIBS := $(foreach lib,$(LIB_LIST),\
                  $(if $(LIB_SOURCE_$(lib)),,$(lib)))

ifneq ($(strip $(UNKNOWN_LIBS)),)
$(error unknown LIBS entries: $(UNKNOWN_LIBS))
endif
ifeq ($(strip $(TEST_PACKAGE_SOURCE)),)
$(error unknown TEST_SUITE: $(TEST_SUITE))
endif

INCDIRS := +incdir+host_mem/src +incdir+src/gq $(LIB_INCDIRS) +incdir+tb
SOURCES := host_mem/src/host_mem_pkg.sv src/gq/gq_pkg.sv \
           $(LIB_SOURCES) $(TEST_PACKAGE_SOURCE) tb/tb_top.sv
VCS_FLAGS += $(TEST_DEFINE_$(TEST_SUITE))
```

Reject unknown library names by comparing `LIB_LIST` with the defined `LIB_SOURCE_*` variables and reject a test suite whose package map is empty. Compile `$(TEST_DEFINE_$(TEST_SUITE))`; in `tb_top.sv`, guard the existing `gq_test_pkg` import with `QUEUE_TEST_GQ` so later plans can add mutually exclusive package imports.

Extend the remote script with optional validated arguments `libraries=${2:-mailbox}` and `test_suite=${3:-}`. If no suite is supplied, select `gq` for `mailbox` or a comma-separated library set, otherwise select the single library name. Validate libraries with `^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$`, validate the suite with `^[A-Za-z0-9_]+$`, and pass both `LIBS=$libraries TEST_SUITE=$test_suite` to remote Make.

- [ ] **Step 3: Document public behavior and strengthen layout checks**

Document exact completion task outputs, fixed/adaptive formulas, IRQ watchdog ACK rule, timeout-zero RX rule, explicit/auto recycle semantics, and `max_refill_batch=0` meaning unlimited. Make `check_sv_layout.sh` require `gq_desc_writeback_completion.sv` and `gq_index_phase_ptr_codec.sv`, and continue rejecting all repository-owned `.svh` files/includes except `uvm_macros.svh`.

- [ ] **Step 4: Run static and full remote compatibility gates**

```bash
make check-layout
rg -n "MSGQ|CMDQ|TLPQ|pcie_tl|DPU_" src/gq
for test_name in gq_config_test gq_submit_test gq_completion_test \
  gq_refill_test gq_reset_test gq_regression_test \
  mailbox_desc_test mailbox_ptr_codec_test mailbox_reg_adapter_test \
  mailbox_wrap_test; do
  scripts/run_vcs_remote.sh "$test_name" mailbox
done
```

Expected: layout exits zero; the business-token scan prints no matches; every VCS test exits zero with zero UVM errors/fatals.

- [ ] **Step 5: Commit build and documentation**

```bash
git add Makefile scripts/run_vcs_remote.sh scripts/check_sv_layout.sh \
  tb/tb_top.sv README.md
git commit -m "docs(gq): publish completion and scheduling contracts"
```

## Plan Completion Checks

- Map spec Sections 6, 10, 11, 12.5, 12.6, and Acceptance Criteria 1, 3, 4, 9, and 10 to the tasks above; every clause must have a named test or static check.
- Run `rg -n 'T[B]D|T[O]DO|implement[[:space:]]+later|fill in detai[l]s|appropriate error handlin[g]|similar to Tas[k]' docs/superpowers/plans/2026-08-27-gq-extensible-completion-lifecycle.md` and require no matches.
- Run `rg -n "completed_count\(|poll_interval|GQ_RX_AUTO_RECYCLE|query_completed|wait_for_wakeup|max_refill_batch" src tb` and verify only the new signatures/names remain.
- Run `git status --short` and verify only intentional post-plan work remains.
