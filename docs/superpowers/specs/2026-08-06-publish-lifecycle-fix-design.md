# Lock-Free Publish Lifecycle Fix Design

## 1. Problem

`gq_queue_engine` currently calls the external timed task
`gq_hw_adapter.publish()` while holding `submit_serialization`. Runtime reset
and final cleanup later acquire the same semaphore before disabling the queue.
If a DUT-facing publish waits for a condition that reset or queue disable must
release, publish waits for reset while reset waits for publish.

This violates the approved generic-queue design rule that engine locks are not
held across external timed waits. It can also prevent an active request from
returning `GQ_ABORTED_BY_RESET` and can hold automatic-finalization objections
forever.

## 2. Goals and Non-Goals

The fix must:

- call `adapter.publish()` without holding any engine semaphore;
- preserve strict per-queue publish ordering;
- let reset and cleanup disable a queue while a publish is blocked;
- keep descriptors and ring storage alive until the in-flight publish has
  quiesced;
- return `GQ_ABORTED_BY_RESET` when reset wins the publish race;
- prevent a canceled pre-reset publish from becoming visible after disable or
  after reset reconfiguration;
- preserve batching, RX refill, reset restart, phase, timeout, and ownership
  behavior.

The fix does not add a separate `cancel_publish()` API, parallelize publishes
within one queue, change pointer encoding, or change descriptor formats.

## 3. Adapter Contract

`disable_queue(role, queue_id)` is the cancellation operation for an in-flight
publish on the same queue. A concrete adapter must support it being called
concurrently with `publish()` and must cause that publish to return.

After `disable_queue()` returns, a publish that was pending before disable must
not make a tail update visible. The engine may still wait for the corresponding
publish task to return before it releases descriptor or ring memory. Reset
reconfiguration cannot start until that return has been observed.

This contract keeps cancellation in the existing hardware-control interface
and avoids adding a second reset-like adapter method.

## 4. Queue-Local Publish Ownership

Each engine owns one publish lifecycle domain:

- `publish_in_progress` records whether one external publish is active;
- a persistent `publish_done` event represents that exact operation;
- state transitions that claim or release ownership occur under the short
  state lock;
- waiting for `publish_done` holds no lifecycle-owned semaphore, and calling
  `adapter.publish()` holds no engine semaphore at all.

Before descriptor preparation, a submit attempt checks whether a publish is
already active. If so, it captures that operation's persistent done event,
releases submission serialization, waits without any lifecycle-owned lock,
then retries after checking epoch/reset/shutdown state. A user request may
retain only its FIFO-ordering token while waiting for the earlier publish; reset
and cleanup never acquire that token. It does not prepare descriptors or
advance the logical tail while waiting.

When no publish is active, the submit attempt prepares and installs the batch,
advances the logical tail, and atomically claims publish ownership. It then
returns a captured publish operation to its caller. The caller releases both
submission serialization and any user FIFO-ordering token before entering
`adapter.publish()`.
Consequently, another submit can wait for the owner but cannot overtake it or
publish a later tail first.

When the external task returns, the owner briefly reacquires the state lock to:

1. arm completion-timeout timestamps only for entries still owned by this
   epoch;
2. choose `GQ_OK` or `GQ_ABORTED_BY_RESET` from current lifecycle state;
3. clear publish ownership; and
4. trigger the captured persistent done event.

Trigger-before-wait remains observable through `uvm_event.wait_on()`, so a
waiter cannot lose completion.

## 5. Reset and Cleanup Ordering

Reset assertion first publishes the new epoch/reset state and rejects new
submissions. Resource teardown then serializes against any zero-time
prepare/install attempt, captures the in-flight publish event, and detaches the
queue's outstanding/resource metadata using the existing ownership rules.

After releasing engine locks, teardown performs:

```text
disable_queue
    -> wait for captured publish_done, if any
        -> release descriptor-owned buffers
            -> free ring memory
```

Calling disable before waiting breaks the dependency cycle. Keeping memory
until publish completion prevents a canceled adapter operation from observing
freed storage. Reset release and reconfiguration occur only after this sequence
finishes, so a stale publish cannot target a newly configured queue.

Publish waiters awakened during reset revalidate epoch/reset/shutdown before
retrying and return aborted without touching detached or freed queue memory.
Final cleanup uses the same sequence and remains idempotent.

## 6. Error and Response Semantics

- Publish returns before reset owns the lifecycle boundary: the request may
  complete with `GQ_OK`.
- Reset changes the epoch before the publish owner commits its response: the
  request returns `GQ_ABORTED_BY_RESET`.
- A submit waiting behind another publish wakes into reset: it aborts before
  descriptor preparation.
- Adapter implementations that do not honor disable-driven cancellation
  violate the hardware-adapter contract; the environment cannot safely free or
  reuse their queue memory.

## 7. Verification

Add deterministic tests with an adapter whose publish blocks until
`disable_queue()` is called.

The pre-fix test must reach its watchdog because reset waits on
`submit_serialization` and cannot call disable. The fixed implementation must
prove:

- reset/cleanup calls disable while publish is blocked;
- disable releases the blocked publish;
- the active request returns `GQ_ABORTED_BY_RESET`;
- a later submit cannot overtake the active publish;
- no tail publication becomes visible after disable;
- reset release/reconfiguration occurs only after publish returns;
- descriptors and rings are released exactly once with zero memory leaks;
- automatic final cleanup completes without an objection hang.

Run focused submit, reset, and integrated-regression tests first, followed by
the complete seven-test VCS regression on `10.11.10.53`.

## 8. Expected Files

- `src/gq/gq_hw_adapter.sv`: document the disable-driven cancellation contract.
- `src/gq/gq_queue_engine.sv`: add publish owner/done lifecycle and reorder
  teardown.
- `tb/mocks/mailbox_mock_adapter.sv`: model the adapter contract.
- `tb/tests/gq_submit_test.sv`: verify publish ordering without a held engine
  semaphore.
- `tb/tests/gq_reset_test.sv`: verify blocked publish cancellation and reset
  completion.
- `tb/tests/gq_regression_test.sv`: retain the final global watchdog and
  automatic-finalization coverage.
- `README.md`: document the adapter cancellation requirement.
