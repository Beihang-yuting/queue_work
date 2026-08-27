# Lock-Free Publish Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every engine semaphore from the external tail-publish call while preserving per-queue publish order and allowing reset/cleanup to cancel a blocked publish through `disable_queue()`.

**Architecture:** A queue-local owner/done domain linearizes one publish at a time. Descriptor installation claims an operation under the short state lock, all submission semaphores are released before the adapter task, and reset/cleanup performs disable → wait for the captured persistent done event → free resources. The adapter contract requires disable to cancel an in-flight publish without making a post-disable tail visible.

**Tech Stack:** SystemVerilog, UVM 1.2, `host_mem_api`, VCS W-2024.09-SP1 on `10.11.10.53`.

---

## File Map

- Modify `src/gq/gq_hw_adapter.sv`: document disable-driven publish cancellation.
- Modify `src/gq/gq_queue_engine.sv`: add publish operation ownership, split install from external publish, and reorder teardown.
- Modify `tb/tests/gq_submit_test.sv`: prove publish owns no engine semaphore and later submits cannot overtake it.
- Modify `tb/tests/gq_reset_test.sv`: block publish until disable and prove reset/cleanup cannot deadlock.
- Modify `README.md`: document the concrete-adapter cancellation requirement.
- Verify `tb/mocks/mailbox_mock_adapter.sv`: its zero-time operations already satisfy the contract; change it only if the focused tests need common observable state.
- Verify `tb/tests/gq_regression_test.sv`: retain its 10 us global watchdog and automatic-finalization assertions without weakening them.

## Task 1: Ordered Publish Ownership and Disable-First Teardown

**Files:**

- Modify: `src/gq/gq_hw_adapter.sv`
- Modify: `src/gq/gq_queue_engine.sv`
- Modify: `tb/tests/gq_submit_test.sv`
- Modify: `tb/tests/gq_reset_test.sv`

- [ ] **Step 1: Add the failing no-lock publish test**

Extend `gq_submit_test_engine` with a test task that acquires and immediately
returns both submission semaphores. It is a task because `semaphore.put()` is a
task even though it consumes no simulation time:

```systemverilog
task probe_publish_locks_for_test(output bit locks_available);
    bit got_user;
    bit got_submit;

    got_user   = user_request_ordering.try_get(1);
    got_submit = submit_serialization.try_get(1);
    if (got_submit)
        submit_serialization.put(1);
    if (got_user)
        user_request_ordering.put(1);
    locks_available = got_user && got_submit;
endtask
```

In the existing delayed-publish scenario, call this probe after
`publish_entered.wait_on()`. Keep the second submit and require that its
descriptor has not been prepared until the first publish completes:

```systemverilog
engine.probe_publish_locks_for_test(locks_available);
if (!locks_available)
    `uvm_fatal("SUBMIT_PUBLISH_LOCK",
               "external publish retained an engine submission semaphore")

fork : delayed_second_submit
    begin
        engine.submit_batch(second_request, second_response);
        second_returned = 1;
    end
join_none
#1ns;
if (second_concurrent.prepare_calls != 0 || second_returned)
    `uvm_fatal("SUBMIT_PUBLISH_ORDER",
               "later submit overtook the active publish")
```

Retain the final tail checks for `encode_publish(4, 5, 32)` followed by
`encode_publish(5, 6, 32)`.

- [ ] **Step 2: Run the submit test and verify RED**

Run on `10.11.10.53`:

```bash
scripts/run_vcs_remote.sh gq_submit_test
```

Expected: the current implementation reaches `SUBMIT_PUBLISH_LOCK`, because
the owner still holds `user_request_ordering` and `submit_serialization` while
the delayed adapter task is active.

- [ ] **Step 3: Add the failing disable-cancels-publish reset test**

Extend `gq_reset_order_adapter` with deterministic cancellation state:

```systemverilog
bit block_publish_until_disable;
string blocked_publish_key;
uvm_event publish_cancelled;
int unsigned cancelled_publish_count;

function new(string name = "gq_reset_order_adapter");
    super.new(name);
    block_publish_until_disable = 0;
    blocked_publish_key = "";
    publish_cancelled = new({name, "_publish_cancelled"});
    cancelled_publish_count = 0;
endfunction
```

For the selected reset test queue, make `publish()` enter and block before it
updates mock-visible tail state. Make `disable_queue()` set disabled state and
trigger the persistent cancellation event. A canceled publish resets the event,
increments `cancelled_publish_count`, and returns without calling
`super.publish()`:

```systemverilog
virtual task publish(gq_role_e role, int unsigned queue_id,
                     gq_raw_ptr_t raw_tail);
    string key;

    key = gq_queue_key(role, queue_id);
    publish_entered.trigger();
    if (block_publish_until_disable && key == blocked_publish_key) begin
        publish_cancelled.wait_on();
        publish_cancelled.reset();
        cancelled_publish_count++;
        return;
    end
    if (publish_delay != 0)
        #(publish_delay);
    if (disabled_state.exists(key) && disabled_state[key])
        post_disable_publish = 1;
    super.publish(role, queue_id, raw_tail);
endtask

virtual task disable_queue(gq_role_e role, int unsigned queue_id);
    string key;

    key = gq_queue_key(role, queue_id);
    disabled_state[key] = 1;
    if (block_publish_until_disable && key == blocked_publish_key)
        publish_cancelled.trigger();
    if (spy_mem != null && spy_mem.enforce_disable_before_desc_free)
        spy_mem.queue_disable_observed = 1;
    disable_order.push_back(key);
    super.disable_queue(role, queue_id);
endtask
```

Start one TX request in a fork, wait for `publish_entered`, and assert reset in
a second fork. Use the existing 10 us `RESET_WATCHDOG`. The GREEN assertions
that will initially fail are:

```systemverilog
if (!submit_returned || response.status != GQ_ABORTED_BY_RESET)
    `uvm_fatal("RESET_PUBLISH_CANCEL",
               "blocked publish request was not reset-aborted")
if (!reset_returned || adapter.cancelled_publish_count != 1)
    `uvm_fatal("RESET_PUBLISH_CANCEL",
               "disable did not quiesce exactly one blocked publish")
if (adapter.post_disable_publish ||
    adapter.publish_count["tx_7"] != publish_count_before)
    `uvm_fatal("RESET_PUBLISH_CANCEL",
               "a canceled publish became visible after disable")
if (tx_engine.ring_base() != 0 || tx_engine.outstanding_count() != 0)
    `uvm_fatal("RESET_PUBLISH_CANCEL",
               "reset freed or retained the wrong publish resources")
```

Use the existing delayed-refill reset scenario for this RED by targeting
`"rx_5"`: replace its finite `publish_delay` with
`block_publish_until_disable=1`. After reset cancels that refill, clear blocking
before reset release so recovery publication can run normally.

At the end of the environment portion of `gq_reset_test`, add the cleanup
variant. Start a new blocked TX publication targeting `"tx_7"`, wait for entry,
then call `env.cleanup()` in a fork. Require cleanup and the submit to return
before the watchdog, require the response to be `GQ_ABORTED_BY_RESET`, require
`cancelled_publish_count` to advance exactly once more, and require no visible
tail update. This proves explicit cleanup uses the same disable-first path as
runtime reset.

- [ ] **Step 4: Run the reset test and verify RED**

```bash
scripts/run_vcs_remote.sh gq_reset_test
```

Expected: the existing implementation reaches `RESET_WATCHDOG` at 10 us. The
publish owns `submit_serialization`, reset waits for that semaphore, and
`disable_queue()` cannot trigger `publish_cancelled`.

- [ ] **Step 5: Define the internal publish operation and owner state**

At package scope in `src/gq/gq_queue_engine.sv`, before `gq_queue_engine`, add
the non-factory internal operation:

```systemverilog
class gq_publish_operation;
    gq_logical_seq_t old_tail;
    gq_logical_seq_t new_tail;
    gq_raw_ptr_t raw_tail;
    longint unsigned request_epoch;
    bit allow_during_reset;
    uvm_event done;

    function new(string name = "gq_publish_operation");
        old_tail = 0;
        new_tail = 0;
        raw_tail = 0;
        request_epoch = 0;
        allow_during_reset = 0;
        done = new({name, "_done"});
    endfunction
endclass
```

Add queue-local state and initialize it in the constructor:

```systemverilog
protected bit publish_in_progress;
protected uvm_event active_publish_done;

publish_in_progress = 0;
active_publish_done = null;
```

- [ ] **Step 6: Split descriptor installation from the external publish task**

Change `submit_desc_batch_locked()` so it never calls the adapter. Add outputs
for a busy publish, its persistent event, and the newly claimed operation:

```systemverilog
protected task submit_desc_batch_locked(
    input gq_desc_base descs[$],
    inout gq_response response,
    input bit activate_rx,
    input gq_refill_profile activation_profile,
    input longint unsigned request_epoch,
    input bit allow_during_reset,
    output bit capacity_wait_required,
    output bit publish_wait_required,
    output uvm_event wait_publish_done,
    output gq_publish_operation publish_op,
    output bit ownership_transferred);
```

Initialize every output at entry. After lifecycle validation and before any
descriptor preparation, detect an active publish under `state_lock`:

```systemverilog
if (publish_in_progress) begin
    publish_wait_required = 1;
    wait_publish_done = active_publish_done;
    state_lock.put(1);
    return;
end
```

After installing the descriptors and advancing `logical_tail_seq`, claim the
operation before releasing the state lock:

```systemverilog
publish_op = new($sformatf("%s_publish_%0d", get_name(), old_tail));
publish_op.old_tail = old_tail;
publish_op.new_tail = new_tail;
publish_op.raw_tail = cfg.ptr_codec.encode_publish(
    old_tail, new_tail, cfg.depth);
publish_op.request_epoch = request_epoch;
publish_op.allow_during_reset = allow_during_reset;
publish_in_progress = 1;
active_publish_done = publish_op.done;
```

Remove `adapter.publish()` and all post-publish response/timestamp work from
this locked task.

- [ ] **Step 7: Add the lock-free publish completion helper**

Add the helper:

```systemverilog
protected task publish_and_complete(
    input gq_publish_operation publish_op,
    inout gq_response response);
```

`publish_and_complete()` revalidates epoch/reset/shutdown under `state_lock`
and skips the adapter call when reset already won. Otherwise it releases the
lock and immediately calls, without an intervening blocking statement:

```systemverilog
adapter.publish(cfg.role, cfg.queue_id, publish_op.raw_tail);
```

No semaphore may be held at that statement. After a real publish returns,
reacquire `state_lock`, revalidate lifecycle state, and arm
`outstanding_since`/`outstanding_published` only when the operation is still
current. Set `GQ_OK` only for that current operation; otherwise call
`abort_response_by_reset(response)`. Finally clear `publish_in_progress`, clear
`active_publish_done` only when it matches `publish_op.done`, release the lock,
and trigger `publish_op.done` exactly once.

- [ ] **Step 8: Make all submission sources use the same owner/done path**

Change `submit_desc_batch_ordered()` to output `gq_publish_operation` and to
wait on a captured earlier publish event after releasing
`submit_serialization`:

```systemverilog
protected task submit_desc_batch_ordered(
    input gq_desc_base descs[$],
    inout gq_response response,
    input bit activate_rx,
    input gq_refill_profile activation_profile,
    input longint unsigned request_epoch,
    input bit allow_during_reset,
    output gq_publish_operation publish_op,
    output bit ownership_transferred);
```

Its wait branch is:

```systemverilog
if (publish_wait_required) begin
    if (wait_publish_done != null && !wait_publish_done.is_on())
        wait_publish_done.wait_on();
    continue;
end
```

The helper returns immediately after it claims an operation; it does not call
the adapter.

Update each source as follows:

- `submit_batch`: keep `user_request_ordering` while choosing/installing the
  next ordered batch, release it, then call `publish_and_complete()`.
- `start_rx`: retain the existing one-shot/profile checks, return an operation
  from ordered install, release `user_request_ordering`, then publish.
- `refill_after_progress`: release `submit_serialization` after descriptor
  generation, use the ordered helper so an earlier publish cannot be
  overtaken, then publish with no semaphore held.
- `release_reset`: use the ordered helper with `allow_during_reset=1`, then
  publish the RX recovery batch with no semaphore held.

On every error path, preserve the existing rule: release locally generated
descriptors only when `ownership_transferred==0`; reset/cleanup owns installed
descriptors.

- [ ] **Step 9: Reorder reset/cleanup teardown around the in-flight publish**

In `release_queue_resources()`, capture the exact persistent event under
`state_lock` before detaching state:

```systemverilog
uvm_event release_publish_done;

release_publish_done = publish_in_progress ? active_publish_done : null;
```

Do not clear publish ownership from teardown. After releasing
`submit_serialization`, `completion_serialization`, and `state_lock`, perform:

```systemverilog
if (release_configured)
    adapter.disable_queue(cfg.role, cfg.queue_id);
if (release_publish_done != null && !release_publish_done.is_on())
    release_publish_done.wait_on();
foreach (cleanup_descs[i])
    cleanup_descs[i].release_owned();
if (release_allocated)
    mem.free(release_ring_base, `__FILE__, `__LINE__);
```

This is the required disable → publish done → descriptor free → ring free
order. Reset release remains behind `finish_reset_done`, so reconfiguration
cannot race the old publish.

- [ ] **Step 10: Document the adapter cancellation contract**

Add this contract immediately above the pure virtual methods in
`src/gq/gq_hw_adapter.sv`:

```systemverilog
// publish() may block in a concrete bus/DUT adapter. disable_queue() must be
// callable concurrently for the same role/queue, must cause such a publish to
// return, and must prevent its pre-disable tail update from becoming visible
// after disable returns. The engine waits for publish completion before it
// frees or reuses queue memory.
```

- [ ] **Step 11: Run focused GREEN verification**

Run on `10.11.10.53`:

```bash
scripts/run_vcs_remote.sh gq_submit_test
scripts/run_vcs_remote.sh gq_reset_test
scripts/run_vcs_remote.sh gq_regression_test
```

Expected for each: process exit 0, final `UVM_WARNING/UVM_ERROR/UVM_FATAL` all
zero, every `HOST_MEM` leak check reports `0 blocks outstanding`. The reset
test must finish below its 10 us watchdog and report one reset-canceled publish
plus one cleanup-canceled publish.

- [ ] **Step 12: Commit the engine fix**

```bash
git diff --check
git add src/gq/gq_hw_adapter.sv src/gq/gq_queue_engine.sv \
        tb/tests/gq_submit_test.sv tb/tests/gq_reset_test.sv
git commit -m "fix: cancel blocked publishes during queue teardown"
```

## Task 2: Public Contract, Full Regression, and Final Review

**Files:**

- Modify: `README.md`
- Verify: `src/gq/`
- Verify: `src/mailbox/`
- Verify: `tb/`

- [ ] **Step 1: Document the production adapter requirement**

In README's adapter/poll/IRQ section, state:

```text
A concrete adapter may block in publish(), but disable_queue() must be callable
concurrently for that queue, must cancel/unblock the publish, and must prevent
the canceled tail from becoming visible after disable. Reset and final cleanup
wait for the publish task to return before freeing descriptor or ring memory.
```

- [ ] **Step 2: Run the complete fresh VCS regression**

From a clean committed snapshot, run all seven tests on `10.11.10.53`:

```bash
for test_name in \
  gq_config_test mailbox_desc_test gq_submit_test gq_completion_test \
  gq_refill_test gq_reset_test gq_regression_test; do
    scripts/run_vcs_remote.sh "${test_name}"
done
```

Record for each test: process exit, final warning/error/fatal counts, and the
number of zero-block leak lines over all leak lines. Every count must be zero
for warnings/errors/fatals and every leak line must be zero-block.

- [ ] **Step 3: Commit documentation**

```bash
git diff --check
git add README.md
git commit -m "docs: define publish cancellation adapter contract"
```

- [ ] **Step 4: Verify repository state**

```bash
git status --short --branch
git submodule status
git diff HEAD --check
git log -4 --oneline --decorate
```

Expected: clean `feature/generic-queue-uvm`, `host_mem` at
`3b9e000d5df4d10efbb3029f43605e0362e0caca`, and no diff-check failures.

- [ ] **Step 5: Request focused spec and quality review**

Review the implementation against
`docs/superpowers/specs/2026-08-06-publish-lifecycle-fix-design.md`. Fix every
Critical/Important finding, rerun the affected tests, then rerun
`gq_regression_test`.

- [ ] **Step 6: Repeat final whole-range review**

Review `66774c1..HEAD` against the original generic-queue design, the original
implementation plan, and the publish-lifecycle fix design. The branch may be
handed off only with no Critical or Important findings.

- [ ] **Step 7: Run final clean verification after the last commit**

Record VCS version and rerun the seven named tests from the final committed
snapshot. Do not commit logs. Clean the exact remote temporary directory and
confirm the local worktree and submodule remain clean.
