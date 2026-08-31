# CMDQ Generic Queue Business Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an independent `cmdq` package for the DPU depth-32 command ring, including 32-byte descriptors, owned 256-byte TX/RX buffers, result completion, bit-15 wrap, and Poll/IRQ detection.

**Architecture:** CMDQ is a GQ TX specialization. A descriptor owns and validates its buffers and stable fields, generic writeback completion discovers contiguous `USED` descriptors, and a business sequence offers the driver's submit-one/wait-one behavior without hard-coding command payload formats or register addresses.

**Tech Stack:** SystemVerilog, UVM 1.2, GQ, `host_mem`, VCS, GNU Make, EMP `cmdq.c/cmdq.h` from archive SHA-256 `dbc70200...130cae`.

**Spec:** `docs/superpowers/specs/2026-08-27-msgq-cmdq-tlpq-gq-reuse-design.md`

## Global Constraints

- Complete the GQ extensible-completion plan before Task 1 and start with a clean worktree.
- All repository-owned SystemVerilog files use `.sv`; do not add `.svh` files.
- `cmdq_pkg` may depend on `gq_pkg` and `host_mem_pkg`, but not mailbox, MSGQ, TLPQ, or PCIe packages.
- The standard queue is TX, depth 32, descriptor size 32, and owns separate 256-byte TX and RX buffers per outstanding command.
- Submission sets `AVAIL=1,USED=0`; completion requires `USED=1`; bit 15 is the wrap phase.
- Payloads and results are raw bytes plus `dst_id`; do not invent FSE/PSTAT command-field parsers.
- Default completion detection is adaptive Poll at 10/20/40/80/100 ns with a 10 us final timeout; IRQ is also supported.
- Register addresses, bus retries, HID/FID/MSI-X mapping, and transport access remain in user-derived adapters.
- Validate every simulation with VCS on `ubuntu@10.11.10.53` through a bash login shell.

---

## File Map

```text
src/cmdq/cmdq_pkg.sv                  public package
src/cmdq/cmdq_types.sv                constants, destination/result types
src/cmdq/cmdq_tx_desc.sv              descriptor and owned buffers
src/cmdq/cmdq_completion.sv           generic writeback specialization
src/cmdq/cmdq_ptr_codec.sv            bit-15 phase pointer
src/cmdq/cmdq_reg_adapter.sv           semantic reset/config/notify/IRQ API
src/cmdq/cmdq_env.sv                   standard queue configuration
src/cmdq/cmdq_sequences.sv             submit-one/wait-one result API
tb/cmdq_test_pkg.sv                    CMDQ-only test package
tb/mocks/cmdq_mock_adapter.sv          semantic trace and IRQ control
tb/mocks/cmdq_mock_dut.sv              descriptor/result completion
tb/tests/cmdq_desc_test.sv             layout, ownership, corruption
tb/tests/cmdq_sequence_test.sv         persistent event/result/timeout
tb/tests/cmdq_driver_conformance_test.sv setup, Poll/IRQ, wrap, races
```

### Task 1: Independent Package and Exact Descriptor Layout

**Files:**
- Create: `src/cmdq/cmdq_pkg.sv`
- Create: `src/cmdq/cmdq_types.sv`
- Create: `src/cmdq/cmdq_tx_desc.sv`
- Create: `tb/cmdq_test_pkg.sv`
- Create: `tb/tests/cmdq_desc_test.sv`
- Modify: `Makefile`
- Modify: `tb/tb_top.sv`
- Modify: `scripts/run_vcs_remote.sh`

**Interfaces:**
- Consumes: `gq_desc_base` allocation, packing, completion, and release hooks.
- Produces: a 32-byte descriptor with copied request/result data and persistent completion event.

- [ ] **Step 1: Write failing independent descriptor vectors**

Create a descriptor with a three-byte request and `dst_id=16'h0002`. Attach `host_mem_manager`, call `prepare()`, `mark_available(phase)`, and require exact little-endian offsets:

```text
0x00 flags          u16 = 0x0001
0x02 tx_buf_len     u16 = 3
0x04 tx_buf_addr    u64
0x0c dst_id         u16 = 2
0x0e rx_buf_len     u16 = 256 before completion
0x10 rx_buf_addr    u64
0x18 reserved       u64 = 0
```

Require packed size 32, two distinct owned allocations, both 256 bytes, TX memory containing the request, and zeroed RX memory. Reject request sizes 257 and a second `prepare()` call.

- [ ] **Step 2: Add failing stable-field and result tests**

Starting from the packed bytes, change only flags to `USED` and RX length to 5, write five result bytes, then require `unpack()`, `is_complete()`, and `parse_completion()` to copy the five bytes into `result[]` and persistently trigger `completion_event`. In separate cases corrupt TX length/address, destination, RX address, or reserved bytes and require `unpack()` false; set RX length 257 and require completion parsing false.

- [ ] **Step 3: Run a CMDQ-only compile and verify package absence**

```bash
scripts/run_vcs_remote.sh cmdq_desc_test cmdq
```

Expected: VCS reports missing `cmdq_pkg`.

- [ ] **Step 4: Add constants, result status, and descriptor**

Define:

```systemverilog
localparam int unsigned CMDQ_DEPTH = 32;
localparam int unsigned CMDQ_DESC_BYTES = 32;
localparam int unsigned CMDQ_BUFFER_BYTES = 256;
localparam bit [15:0] CMDQ_DESC_AVAIL = 16'h0001;
localparam bit [15:0] CMDQ_DESC_USED  = 16'h0002;
localparam bit [15:0] CMDQ_DST_FSE    = 16'h0002;
localparam bit [15:0] CMDQ_DST_PSTAT  = 16'h0003;
typedef enum int { CMDQ_RESULT_OK, CMDQ_RESULT_SUBMIT_ERROR,
                   CMDQ_RESULT_TIMEOUT, CMDQ_RESULT_PARSE_ERROR }
                  cmdq_result_status_e;
```

`cmdq_tx_desc` stores `request[]`, `result[]`, flags/lengths/addresses/destination, prepared stable snapshots, and `uvm_event completion_event`. `prepare()` allocates two owned 256-byte blocks, copies and zero-fills TX, zeroes RX, and initializes advertised RX capacity. `unpack()` permits only flags and RX length to change. `parse_completion()` copies result before triggering the persistent event; GQ may release the underlying allocations immediately afterward.

- [ ] **Step 5: Add CMDQ build/test-suite selection**

Append:

```make
LIB_SOURCE_cmdq := src/cmdq/cmdq_pkg.sv
TEST_PACKAGE_cmdq := tb/cmdq_test_pkg.sv
TEST_DEFINE_cmdq := +define+QUEUE_TEST_CMDQ
```

Add the matching conditional import in `tb_top.sv`. Preserve independent `LIBS=cmdq TEST_SUITE=cmdq` compilation and the optional remote-script suite override defined by the GQ plan.

- [ ] **Step 6: Run exact layout and ownership tests**

```bash
scripts/run_vcs_remote.sh cmdq_desc_test cmdq
```

Expected: layout, two-buffer ownership, stable-field rejection, result copying, and event persistence pass.

- [ ] **Step 7: Commit the CMDQ descriptor package**

```bash
git add src/cmdq/cmdq_pkg.sv src/cmdq/cmdq_types.sv \
  src/cmdq/cmdq_tx_desc.sv tb/cmdq_test_pkg.sv \
  tb/tests/cmdq_desc_test.sv Makefile tb/tb_top.sv scripts/run_vcs_remote.sh
git commit -m "feat(cmdq): add exact command descriptor and buffers"
```

### Task 2: Completion, Bit-15 Pointer, and Semantic Adapter

**Files:**
- Create: `src/cmdq/cmdq_completion.sv`
- Create: `src/cmdq/cmdq_ptr_codec.sv`
- Create: `src/cmdq/cmdq_reg_adapter.sv`
- Create: `tb/mocks/cmdq_mock_adapter.sv`
- Modify: `src/cmdq/cmdq_pkg.sv`
- Modify: `tb/tests/cmdq_desc_test.sv`
- Modify: `tb/cmdq_test_pkg.sv`

**Interfaces:**
- Consumes: `gq_desc_writeback_completion` and `gq_index_phase_ptr_codec`.
- Produces: CMDQ public strategy types and address-free configuration callbacks.

- [ ] **Step 1: Write failing pointer/completion/adapter assertions**

Require `cmdq_ptr_codec` vectors 1=`16'h0001`, 31=`16'h001f`, 32=`16'h8000`, and 64=`16'h0000`. Put two descriptors in memory, mark only the first `USED`, and require `cmdq_completion.query_completed()` to return `valid=1,count=1`.

Require a mock semantic trace for configure and one publish:

```text
RESET(queue=0)
CONFIGURE(queue=0,base,depth=32,size=32,hid,fid,msix)
ENABLE(queue=0)
PUBLISH(queue=0,tail)
```

- [ ] **Step 2: Run the focused descriptor test and verify strategy types are missing**

```bash
scripts/run_vcs_remote.sh cmdq_desc_test cmdq
```

Expected: unresolved completion, pointer, and adapter types.

- [ ] **Step 3: Add thin generic-strategy subclasses**

`cmdq_completion` derives without overriding behavior from `gq_desc_writeback_completion`. `cmdq_ptr_codec` derives from `gq_index_phase_ptr_codec` and calls `super.new(name,15,15)`. Preserve these public CMDQ type names for factory override and user configuration.

- [ ] **Step 4: Define hardware metadata and semantic adapter callbacks**

Add:

```systemverilog
typedef struct packed {
    bit [7:0] host_id;
    bit [15:0] function_id;
    bit [15:0] msix_index;
    bit msix_valid;
} cmdq_hw_cfg_t;
```

`cmdq_reg_adapter` extends `gq_hw_adapter`, stores a `cmdq_hw_cfg_t`, and declares:

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

The generic `configure_queue()` requires TX role and calls reset/configure/enable in order. `publish()` rejects nonzero upper 16 bits. No method contains or accepts a register address.

- [ ] **Step 5: Run pointer, completion, and semantic trace tests**

```bash
scripts/run_vcs_remote.sh cmdq_desc_test cmdq
```

Expected: exact bit-15 values, contiguous writeback count, and address-free event order pass.

- [ ] **Step 6: Commit CMDQ strategies and adapter**

```bash
git add src/cmdq/cmdq_completion.sv src/cmdq/cmdq_ptr_codec.sv \
  src/cmdq/cmdq_reg_adapter.sv src/cmdq/cmdq_pkg.sv \
  tb/mocks/cmdq_mock_adapter.sv tb/tests/cmdq_desc_test.sv \
  tb/cmdq_test_pkg.sv
git commit -m "feat(cmdq): add completion pointer and register strategies"
```

### Task 3: Standard Environment Configuration

**Files:**
- Create: `src/cmdq/cmdq_env.sv`
- Create: `tb/tests/cmdq_sequence_test.sv`
- Modify: `src/cmdq/cmdq_pkg.sv`
- Modify: `tb/cmdq_test_pkg.sv`

**Interfaces:**
- Consumes: Task 2 strategies and GQ timing configuration.
- Produces: one validated driver-conformance queue configuration.

- [ ] **Step 1: Write failing standard-profile assertions**

Call `cmdq_env_cfg.add_cmdq(queue_id=0,hw_cfg,reason)` and require:

```systemverilog
cfg.role == GQ_TX
cfg.depth == 32
cfg.desc_size == 32
cfg.wait_mode == GQ_POLL
cfg.poll_policy == GQ_POLL_ADAPTIVE
cfg.poll_min_interval == 10ns
cfg.poll_max_interval == 100ns
cfg.poll_backoff_factor == 2
cfg.completion_timeout == 10us
```

Require completion type `cmdq_completion`, pointer type `cmdq_ptr_codec`, duplicate queue ID rejection, null/wrong adapter rejection, and IRQ override validation with watchdog 1 us.

- [ ] **Step 2: Run the sequence test and verify the environment type is absent**

```bash
scripts/run_vcs_remote.sh cmdq_sequence_test cmdq
```

Expected: `cmdq_env_cfg` is undefined.

- [ ] **Step 3: Add the standard configuration constructor**

Define `cmdq_env_cfg extends gq_env_cfg` with:

```systemverilog
function bit add_cmdq(
    int unsigned queue_id,
    cmdq_hw_cfg_t hw_cfg,
    output string reason);
```

Require `adapter` cast to `cmdq_reg_adapter`, copy `hw_cfg` into that adapter before queue addition, and create a GQ TX configuration with exact constants/defaults. Use alignment 64, status area zero, and the CMDQ completion/pointer strategies. Advanced users may mutate wait mode/timing before `add_queue()` transfers ownership.

- [ ] **Step 4: Run standard-profile validation**

```bash
scripts/run_vcs_remote.sh cmdq_sequence_test cmdq
```

Expected: all standard values and invalid adapter/duplicate cases pass.

- [ ] **Step 5: Commit the CMDQ environment profile**

```bash
git add src/cmdq/cmdq_env.sv src/cmdq/cmdq_pkg.sv \
  tb/tests/cmdq_sequence_test.sv tb/cmdq_test_pkg.sv
git commit -m "feat(cmdq): configure driver compatible command queue"
```

### Task 4: Submit-One/Wait-One Sequence and Result Lifetime

**Files:**
- Create: `src/cmdq/cmdq_sequences.sv`
- Modify: `src/cmdq/cmdq_pkg.sv`
- Modify: `tb/tests/cmdq_sequence_test.sv`
- Modify: `tb/cmdq_test_pkg.sv`

**Interfaces:**
- Consumes: GQ request/response and `cmdq_tx_desc.completion_event`.
- Produces: raw command request/result sequence with deterministic timeout.

- [ ] **Step 1: Add failing early-completion, query-result, and timeout cases**

For early completion, let the mock DUT mark `USED` before the sequence begins waiting; require the persistent event to avoid a lost wake. For a PSTAT query, return seven bytes and require exact result length/content after GQ frees both owned buffers. For no completion, require status `CMDQ_RESULT_TIMEOUT` at 10 us and empty result. For a failed submit response, require `CMDQ_RESULT_SUBMIT_ERROR` and no completion wait.

- [ ] **Step 2: Run sequence tests and verify the business sequence is missing**

```bash
scripts/run_vcs_remote.sh cmdq_sequence_test cmdq
```

Expected: unresolved `cmdq_command_sequence` and failing result-lifetime checks.

- [ ] **Step 3: Implement the public command sequence**

Expose:

```systemverilog
class cmdq_command_sequence extends uvm_sequence #(gq_request, gq_response);
    byte request_payload[];
    bit [15:0] dst_id;
    time completion_timeout = 10us;
    byte result[];
    cmdq_result_status_e result_status;
endclass
```

`body()` creates one descriptor, copies request/destination, submits one `GQ_SUBMIT`, then races `desc.completion_event.wait_on()` against the configured timeout in a nested fork. On completion copy `desc.result` into sequence-owned `result`; on timeout leave `result` empty. Generic batch submission remains available through GQ but is not used here.

- [ ] **Step 4: Run all sequence lifetime cases**

```bash
scripts/run_vcs_remote.sh cmdq_sequence_test cmdq
```

Expected: early event, FSE send, PSTAT result, submit failure, and timeout all pass without retaining host-memory addresses.

- [ ] **Step 5: Commit the synchronous business sequence**

```bash
git add src/cmdq/cmdq_sequences.sv src/cmdq/cmdq_pkg.sv \
  tb/tests/cmdq_sequence_test.sv tb/cmdq_test_pkg.sv
git commit -m "feat(cmdq): add synchronous command result sequence"
```

### Task 5: Driver-Conformance Poll/IRQ, Wrap, and Error Regression

**Files:**
- Create: `tb/mocks/cmdq_mock_dut.sv`
- Create: `tb/tests/cmdq_driver_conformance_test.sv`
- Modify: `tb/mocks/cmdq_mock_adapter.sv`
- Modify: `tb/cmdq_test_pkg.sv`

**Interfaces:**
- Consumes: complete CMDQ library and GQ scheduler.
- Produces: EMP driver-flow conformance and additional IRQ capability evidence.

- [ ] **Step 1: Write failing driver setup and FSE/PSTAT flows**

Require `RESET,CONFIGURE(depth=32,size=32),ENABLE` before the first publish. Submit FSE raw payload to destination 2, require one publish, `AVAIL` before hardware completion, then `USED`. Submit PSTAT destination 3, write an actual RX length shorter than 256, and require only that many bytes returned.

- [ ] **Step 2: Write failing wrap and adaptive-poll cases**

Complete 31 commands, submit the slot-31 command, and require the next tail publication to be `16'h8000`. With no completion, record query times and require 10/20/40/80/100 ns saturation. Complete work and require the next interval reset to 10 ns. With zero outstanding for 1 us require no completion queries; submit during a 100 ns wait and require immediate wake.

- [ ] **Step 3: Add error, IRQ, and lifecycle races**

Require stable-field corruption and RX length 257 to block retirement and return no result. Require timeout once for the oldest published descriptor. In IRQ mode test real/spurious/lost-IRQ watchdog paths and exact ACK counts. Reset while a writeback read or IRQ ACK is blocked and require stale work to retire nothing and all allocations to free once.

- [ ] **Step 4: Run driver-conformance suite**

```bash
ssh ubuntu@10.11.10.53 "bash -lc '
  sha256sum /home/ubuntu/Downloads/emp.zip
'"
scripts/run_vcs_remote.sh cmdq_driver_conformance_test cmdq
```

Expected: the hash record contains `dbc70200efdab93a96522a5115c9b81059b01fc512d587026b9b69b9db130cae`; setup, FSE/PSTAT, wrap, adaptive Poll, idle wake, errors, IRQ, watchdog, and reset cases all pass with zero UVM errors/fatals.

- [ ] **Step 5: Commit CMDQ conformance tests**

```bash
git add tb/mocks/cmdq_mock_dut.sv tb/mocks/cmdq_mock_adapter.sv \
  tb/tests/cmdq_driver_conformance_test.sv tb/cmdq_test_pkg.sv
git commit -m "test(cmdq): verify driver command queue behavior"
```

### Task 6: Documentation, Isolation, and Regression Gate

**Files:**
- Modify: `README.md`
- Modify: `scripts/check_sv_layout.sh`

**Interfaces:**
- Consumes: all CMDQ tasks.
- Produces: public API documentation and independent/legacy regression evidence.

- [ ] **Step 1: Document descriptor, result, timing, and adapter contracts**

Add a CMDQ section with the exact 32-byte table, 256-byte ownership, stable/mutable fields, destination/result API, persistent completion event, 10-100 ns adaptive Poll, 10 us timeout, IRQ option, and semantic adapter callbacks. State that adapter-internal transport retries do not cause a second GQ publish.

- [ ] **Step 2: Extend layout and isolation checks**

Require all eight `src/cmdq/*.sv` files. Run:

```bash
make check-layout
rg -n "0x[0-9a-fA-F]+|MSGQ|TLPQ|mailbox_pkg|pcie_tl" src/cmdq
```

Expected: layout passes and the isolation scan prints no matches.

- [ ] **Step 3: Run independent CMDQ and legacy regressions**

```bash
for test_name in cmdq_desc_test cmdq_sequence_test \
  cmdq_driver_conformance_test; do
  scripts/run_vcs_remote.sh "$test_name" cmdq
done
scripts/run_vcs_remote.sh gq_regression_test mailbox gq
scripts/run_vcs_remote.sh mailbox_wrap_test mailbox gq
```

Expected: all tests exit zero with zero UVM errors/fatals; CMDQ compiles without other business packages.

- [ ] **Step 4: Commit documentation and layout checks**

```bash
git add README.md scripts/check_sv_layout.sh
git commit -m "docs(cmdq): publish command queue extension contract"
```

## Plan Completion Checks

- Map spec Sections 8, 10, 11, 12.3, 12.5, 12.6 and Acceptance Criteria 2, 3, 6, 9, 10 to a named task/assertion above.
- Run `rg -n 'T[B]D|T[O]DO|implement[[:space:]]+later|fill in detai[l]s|appropriate error handlin[g]|similar to Tas[k]' docs/superpowers/plans/2026-08-27-cmdq-gq-business-library.md` and require no matches.
- Run `rg -n "cmdq_hw_cfg_t|completion_event|CMDQ_RESULT_TIMEOUT|CMDQ_BUFFER_BYTES|write_cmdq_tail" docs/superpowers/plans/2026-08-27-cmdq-gq-business-library.md src/cmdq tb` and correct all spelling/type mismatches.
- Verify `git diff --check` and `git status --short` before handoff.
