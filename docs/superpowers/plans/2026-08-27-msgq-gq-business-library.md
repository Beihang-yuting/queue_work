# MSGQ Generic Queue Business Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an independent `msgq` package that models driver-accurate MAC-age and 1588 receive queues on GQ while keeping unproven message formats raw and user-extensible.

**Architecture:** MSGQ uses a GQ RX engine with `GQ_RX_AUTO_RECYCLE`; progress comes from a semantic register-adapter `current_ptr` read rather than descriptor ownership flags. Entry classes own byte parsing, a refill profile/factory creates each logical entry, and normal completion never rewrites a slot or republishes the tail.

**Tech Stack:** SystemVerilog, UVM 1.2, GQ, `host_mem`, VCS, GNU Make, Linux driver reference `f2c9cd6`, EMP archive SHA-256 `dbc70200...130cae`.

**Spec:** `docs/superpowers/specs/2026-08-27-msgq-cmdq-tlpq-gq-reuse-design.md`

## Global Constraints

- Complete `docs/superpowers/plans/2026-08-27-gq-extensible-completion-lifecycle.md` first and begin this plan from a clean worktree.
- All repository-owned SystemVerilog files use `.sv`; do not add `.svh` files.
- `msgq_pkg` may depend on `gq_pkg` and `host_mem_pkg`, but not mailbox, CMDQ, TLPQ, or PCIe packages.
- Register addresses and transport mechanisms remain in user-derived adapters; no numeric DPU register address appears under `src/msgq`.
- MAC-age defaults to depth 128 and 16-byte entries; active EMP 1588 defaults to depth 32 and 8-byte entries; the Linux-header timestamp variant is depth 128.
- FSE, IACL, EACL, vDPA, and notify have raw fixed-size capture and an entry-factory seam only; do not claim field-level protocol conformance.
- Default detection is IRQ with 50 ns minimum, 500 ns maximum, 1 us watchdog, and disabled final RX timeout; Poll remains selectable.
- Validate with VCS on `ubuntu@10.11.10.53` through a bash login shell.

---

## File Map

```text
src/msgq/msgq_pkg.sv                  package and include order
src/msgq/msgq_types.sv                kinds, profiles, constants
src/msgq/msgq_entry_base.sv           fixed-size raw-entry contract
src/msgq/msgq_raw_entry.sv            extension-safe byte preservation
src/msgq/msgq_mac_age_entry.sv        16-byte concrete parser
src/msgq/msgq_1588_entry.sv           8-byte EMP/Linux parser
src/msgq/msgq_completion.sv           async current-pointer completion
src/msgq/msgq_ptr_codec.sv            15-bit index + bit-15 phase
src/msgq/msgq_refill_profile.sv        entry factory and rotating objects
src/msgq/msgq_reg_adapter.sv           semantic register adapter
src/msgq/msgq_env.sv                   validated business profiles/env
src/msgq/msgq_sequences.sv             RX startup sequence
tb/msgq_test_pkg.sv                    MSGQ-only test package
tb/mocks/msgq_mock_adapter.sv          semantic trace/IRQ/current pointer
tb/mocks/msgq_mock_dut.sv              ring writer and pointer producer
tb/tests/msgq_entry_test.sv            parser vectors
tb/tests/msgq_profile_test.sv          defaults and raw factory
tb/tests/msgq_completion_test.sv       pointer math/error behavior
tb/tests/msgq_driver_conformance_test.sv init/consume/wrap/IRQ/Poll traces
```

### Task 1: Independent Package, Kinds, and Raw Entry Contract

**Files:**
- Create: `src/msgq/msgq_pkg.sv`
- Create: `src/msgq/msgq_types.sv`
- Create: `src/msgq/msgq_entry_base.sv`
- Create: `src/msgq/msgq_raw_entry.sv`
- Create: `tb/msgq_test_pkg.sv`
- Create: `tb/tests/msgq_profile_test.sv`
- Modify: `Makefile`
- Modify: `tb/tb_top.sv`

**Interfaces:**
- Consumes: `gq_desc_base`, `gq_logical_seq_t`, and GQ package build selection.
- Produces: MSGQ kind/profile enums, fixed entry base, raw entry, and an independently compilable package.

- [ ] **Step 1: Write a failing MSGQ-only package/profile test**

Define the intended public enumerations in the test:

```systemverilog
msgq_kind_e kinds[$] = '{MSGQ_MAC_AGE, MSGQ_1588, MSGQ_FSE,
                         MSGQ_IACL, MSGQ_EACL, MSGQ_VDPA, MSGQ_NOTIFY};
msgq_format_profile_e profile = MSGQ_PROFILE_EMP_ACTIVE;
msgq_raw_entry entry = msgq_raw_entry::type_id::create("entry");
byte expected[] = '{8'h12, 8'h34, 8'h56, 8'h78};

entry.set_entry_size(4);
if (!entry.unpack(expected)) `uvm_error("MSGQ_RAW", "unpack rejected")
if (entry.raw_bytes != expected) `uvm_error("MSGQ_RAW", "bytes changed")
```

Also require `pack()` before completion to return four zero bytes, reject an unpack array of size three, and report `owned_allocation_count()==0`.

- [ ] **Step 2: Run an MSGQ-only compile and verify the package is absent**

```bash
scripts/run_vcs_remote.sh msgq_profile_test msgq
```

Expected: VCS reports missing `msgq_pkg`.

- [ ] **Step 3: Add the focused package and entry base**

Create these constants and types:

```systemverilog
localparam int unsigned MSGQ_MAC_AGE_DEPTH = 128;
localparam int unsigned MSGQ_MAC_AGE_ENTRY_BYTES = 16;
localparam int unsigned MSGQ_1588_EMP_DEPTH = 32;
localparam int unsigned MSGQ_1588_LINUX_DEPTH = 128;
localparam int unsigned MSGQ_1588_ENTRY_BYTES = 8;

typedef enum int { MSGQ_MAC_AGE, MSGQ_1588, MSGQ_FSE, MSGQ_IACL,
                   MSGQ_EACL, MSGQ_VDPA, MSGQ_NOTIFY } msgq_kind_e;
typedef enum bit { MSGQ_PROFILE_EMP_ACTIVE,
                   MSGQ_PROFILE_LINUX_HEADER } msgq_format_profile_e;
```

`msgq_entry_base` extends `gq_desc_base`, stores `entry_size`, `logical_seq`, and `raw_bytes[]`, exposes `set_entry_size()`, packs a cleared fixed-size slot, unpacks exactly `entry_size` bytes, always reports complete once selected by the pointer completion source, and leaves field decoding to `parse_completion()`.

- [ ] **Step 4: Add selectable test-suite build wiring**

Extend the Task 7 GQ Make maps:

```make
LIB_SOURCE_msgq := src/msgq/msgq_pkg.sv
TEST_PACKAGE_msgq := tb/msgq_test_pkg.sv
TEST_DEFINE_msgq := +define+QUEUE_TEST_MSGQ
```

The GQ build already compiles `$(TEST_PACKAGE_SOURCE)` and `$(TEST_DEFINE_$(TEST_SUITE))`. Add the `QUEUE_TEST_MSGQ` conditional import to `tb_top.sv`; the GQ remote script maps the single `LIBS=msgq` selection to `TEST_SUITE=msgq` unless a third validated suite argument is supplied.

- [ ] **Step 5: Run the raw-entry test**

```bash
scripts/run_vcs_remote.sh msgq_profile_test msgq
```

Expected: the package compiles without mailbox and the raw byte/size tests pass.

- [ ] **Step 6: Commit the independent MSGQ shell**

```bash
git add src/msgq/msgq_pkg.sv src/msgq/msgq_types.sv \
  src/msgq/msgq_entry_base.sv src/msgq/msgq_raw_entry.sv \
  tb/msgq_test_pkg.sv tb/tests/msgq_profile_test.sv Makefile tb/tb_top.sv \
  scripts/run_vcs_remote.sh
git commit -m "feat(msgq): add independent raw entry package"
```

### Task 2: Concrete MAC-Age and 1588 Parsers

**Files:**
- Create: `src/msgq/msgq_mac_age_entry.sv`
- Create: `src/msgq/msgq_1588_entry.sv`
- Create: `tb/tests/msgq_entry_test.sv`
- Modify: `src/msgq/msgq_pkg.sv`
- Modify: `tb/msgq_test_pkg.sv`

**Interfaces:**
- Consumes: `msgq_entry_base.raw_bytes` and selected format profile.
- Produces: concrete driver-field accessors with strict reserved-bit validation.

- [ ] **Step 1: Write failing independent byte vectors**

For MAC-age, build the 16 bytes without calling the class packer and require:

```systemverilog
entry.hash_key_l == 32'h89ab_cdef
entry.hash_key_h == 29'h0123_4567
entry.mac_act_idx == 9'h155
```

Set the three high reserved bits of DWORD1 and require strict mode to reject them; clear strict mode and require the raw bytes and decoded fields to remain available.

For 1588, use an independent 64-bit little-endian vector and require timestamp `{8'h5a,32'h1234_5678}`, tag `16'hbeef`, type `2'b10`, and source port `4'ha`. In Linux profile require source-port upper bits zero and reject `4'ha`; in active EMP profile accept all four bits. Require both profiles to reject nonzero final reserved bits in strict mode.

- [ ] **Step 2: Run parser tests and verify concrete types are absent**

```bash
scripts/run_vcs_remote.sh msgq_entry_test msgq
```

Expected: VCS cannot resolve `msgq_mac_age_entry` or `msgq_1588_entry`.

- [ ] **Step 3: Implement MAC-age decoding**

Expose these fields:

```systemverilog
bit [31:0] hash_key_l;
bit [28:0] hash_key_h;
bit [8:0]  mac_act_idx;
bit strict_reserved;
```

After `super.unpack()` preserves the 16 bytes, `parse_completion()` assembles four little-endian DWORDs, checks DWORD1 `[31:29]`, DWORD2 `[31:9]`, and DWORD3 in strict mode, and extracts the three named fields.

- [ ] **Step 4: Implement 1588 decoding**

Expose:

```systemverilog
bit [39:0] timestamp;
bit [15:0] timestamp_tag;
bit [1:0]  timestamp_type;
bit [3:0]  source_port;
msgq_format_profile_e format_profile;
bit strict_reserved;
```

Decode the active EMP four-bit source-port representation. For `MSGQ_PROFILE_LINUX_HEADER`, enforce `source_port[3:2]==0`. Keep profile choice explicit in the constructor or setter; do not infer it from queue depth.

- [ ] **Step 5: Run parser and raw regression**

```bash
scripts/run_vcs_remote.sh msgq_entry_test msgq
scripts/run_vcs_remote.sh msgq_profile_test msgq
```

Expected: independent vectors pass and raw capture remains unchanged.

- [ ] **Step 6: Commit concrete formats**

```bash
git add src/msgq/msgq_mac_age_entry.sv src/msgq/msgq_1588_entry.sv \
  src/msgq/msgq_pkg.sv tb/tests/msgq_entry_test.sv tb/msgq_test_pkg.sv
git commit -m "feat(msgq): decode mac age and timestamp entries"
```

### Task 3: Semantic Register Adapter and Current-Pointer Completion

**Files:**
- Create: `src/msgq/msgq_reg_adapter.sv`
- Create: `src/msgq/msgq_completion.sv`
- Create: `src/msgq/msgq_ptr_codec.sv`
- Create: `tb/mocks/msgq_mock_adapter.sv`
- Create: `tb/tests/msgq_completion_test.sv`
- Modify: `src/msgq/msgq_pkg.sv`
- Modify: `tb/msgq_test_pkg.sv`

**Interfaces:**
- Consumes: GQ timed query task and generic index/phase codec.
- Produces: address-free MSGQ callbacks and modulo-current-pointer progress.

- [ ] **Step 1: Write failing adapter and pointer tests**

Create a mock trace with events `RESET`, `CONFIGURE`, `ENABLE`, `PUBLISH`, `WAIT_IRQ`, `ACK_IRQ`, `READ_CURRENT_PTR`, `DISABLE`. Require `msgq_ptr_codec` to encode depth-128 initial tail 127 as `16'h007f` and wrap 128 as `16'h8000`.

For completion with depth 8, require:

```text
head=0 current=0 -> count=0
head=0 current=3 -> count=3
head=7 current=2 -> count=3
current=8 -> valid=0
adapter read valid=0 -> valid=0
```

Write three independent ring entries before returning current 2 so the completion task must unpack the same three pending entry objects in logical order.

- [ ] **Step 2: Run the completion test and verify types are missing**

```bash
scripts/run_vcs_remote.sh msgq_completion_test msgq
```

Expected: compile failure for the adapter, pointer codec, and completion source.

- [ ] **Step 3: Define the semantic adapter**

`msgq_reg_adapter` extends `gq_hw_adapter` and declares:

```systemverilog
pure virtual task configure_msgq_registers(
    int unsigned queue_id, gq_addr_t base, int unsigned depth,
    int unsigned entry_size);
pure virtual task disable_msgq_registers(int unsigned queue_id);
pure virtual task write_msgq_initial_tail(
    int unsigned queue_id, bit [15:0] tail);
pure virtual task wait_msgq_irq(int unsigned queue_id);
pure virtual task ack_msgq_irq(int unsigned queue_id);
pure virtual task read_msgq_current_ptr(
    int unsigned queue_id, output bit valid,
    output bit [15:0] current_ptr);
```

Map the generic callbacks to these tasks, require RX role, reject raw tail upper 16 bits, and keep all address/HID/FID/MSI-X mapping inside user implementations.

- [ ] **Step 4: Implement current-pointer completion**

`msgq_completion` stores `queue_id`, casts the adapter to `msgq_reg_adapter`, calls `read_msgq_current_ptr`, rejects invalid reads or `current_ptr>=depth`, computes:

```systemverilog
completed_count = (int'(current_ptr) - int'(logical_head % depth) + depth)
                  % depth;
```

Before returning valid, read and unpack exactly those contiguous logical entries from `ring_base + ((logical_head+i)%depth)*desc_size`. A short read, null entry, or failed unpack returns `valid=0` and count zero.

- [ ] **Step 5: Run completion/error/wrap cases**

```bash
scripts/run_vcs_remote.sh msgq_completion_test msgq
```

Expected: pointer arithmetic, entry unpack order, invalid pointer, and failed read all pass; only real IRQ paths ACK.

- [ ] **Step 6: Commit MSGQ hardware boundary**

```bash
git add src/msgq/msgq_reg_adapter.sv src/msgq/msgq_completion.sv \
  src/msgq/msgq_ptr_codec.sv src/msgq/msgq_pkg.sv \
  tb/mocks/msgq_mock_adapter.sv tb/tests/msgq_completion_test.sv \
  tb/msgq_test_pkg.sv
git commit -m "feat(msgq): query completion through semantic current pointer"
```

### Task 4: Entry Factory, Refill Profile, and Validated Business Defaults

**Files:**
- Create: `src/msgq/msgq_refill_profile.sv`
- Create: `src/msgq/msgq_env.sv`
- Create: `src/msgq/msgq_sequences.sv`
- Modify: `src/msgq/msgq_pkg.sv`
- Modify: `tb/tests/msgq_profile_test.sv`
- Modify: `tb/msgq_test_pkg.sv`

**Interfaces:**
- Consumes: GQ auto-recycle and MSGQ entry/completion/adapter types.
- Produces: standard MAC/1588 configurations and user raw-entry factory seam.

- [ ] **Step 1: Extend the failing profile matrix**

Require factory output and queue defaults:

```text
MAC-age: depth=128 desc_size=16 initial/high=127 auto-recycle IRQ.
EMP 1588: depth=32 desc_size=8 initial/high=31 auto-recycle IRQ.
Linux 1588: depth=128 desc_size=8 initial/high=127 auto-recycle IRQ.
All: poll min=50ns max=500ns factor=2 watchdog=1us timeout=0.
```

Require a raw FSE profile without a user factory to fail validation. Register a test factory returning a derived 24-byte raw entry and require create/pack/unpack to preserve all 24 bytes.

- [ ] **Step 2: Run profile tests and verify factory/configuration gaps**

```bash
scripts/run_vcs_remote.sh msgq_profile_test msgq
```

Expected: standard profiles and custom factory types are unresolved.

- [ ] **Step 3: Define the factory and refill profile**

Use this extension contract:

```systemverilog
virtual class msgq_entry_factory extends uvm_object;
    pure virtual function msgq_entry_base create_entry(
        int unsigned queue_id, gq_logical_seq_t logical_seq,
        int unsigned entry_size);
endclass
```

`msgq_refill_profile` extends `gq_refill_profile`, stores kind, format profile, entry size, strict flag, and optional factory. Its `create_desc()` creates concrete MAC/1588 entries internally; other kinds require the user factory. Set `initial_post_count=high_watermark=depth-1`, `low_watermark=depth-2`, and `max_refill_batch=0`; GQ auto-recycle consumes the objects without tail writes.

- [ ] **Step 4: Add business configuration construction and RX sequence**

In `msgq_env.sv`, define:

```systemverilog
class msgq_env_cfg extends gq_env_cfg;
    function bit add_msgq(
        int unsigned queue_id, msgq_kind_e kind,
        msgq_format_profile_e format_profile,
        int unsigned raw_depth, int unsigned raw_entry_size,
        msgq_entry_factory factory, output string reason);
endclass
```

For concrete kinds, ignore raw dimensions and apply exact standard defaults. For raw kinds, require power-of-two depth, nonzero entry size, and nonnull factory. Create a `msgq_rx_start_sequence` that submits `GQ_START_RX` with the generated refill profile.

- [ ] **Step 5: Run profiles and independent package compile**

```bash
scripts/run_vcs_remote.sh msgq_profile_test msgq
make check-layout
```

Expected: standard and custom raw profiles pass; layout finds no repository-owned `.svh`.

- [ ] **Step 6: Commit profiles and extension seam**

```bash
git add src/msgq/msgq_refill_profile.sv src/msgq/msgq_env.sv \
  src/msgq/msgq_sequences.sv src/msgq/msgq_pkg.sv \
  tb/tests/msgq_profile_test.sv tb/msgq_test_pkg.sv
git commit -m "feat(msgq): add validated queue profiles and entry factories"
```

### Task 5: Driver-Conformance Flow, IRQ/Poll, and Auto-Recycle

**Files:**
- Create: `tb/mocks/msgq_mock_dut.sv`
- Create: `tb/tests/msgq_driver_conformance_test.sv`
- Modify: `tb/mocks/msgq_mock_adapter.sv`
- Modify: `tb/msgq_test_pkg.sv`

**Interfaces:**
- Consumes: complete MSGQ library and GQ wake/lifecycle behavior.
- Produces: evidence for Linux/EMP setup, consumption, wrap, and detection modes.

- [ ] **Step 1: Write failing MAC-age conformance scenario**

Start queue ID 0 with the standard MAC profile. Require trace `RESET,CONFIGURE(depth=128,size=16),ENABLE,PUBLISH(127)`. Snapshot ring bytes and publish count. Have the mock DUT write entries 126, 127, 0 and move current pointer from 126 to 1; after one IRQ require three decoded callbacks, pointer-order delivery, one ACK, unchanged ring bytes, and still one total publish.

- [ ] **Step 2: Write failing 1588 and raw scenarios**

Start active EMP 1588 with depth 32, initial tail 31, and parse two timestamp entries across slot 31 to 0. Start the Linux depth-128 variant and verify profile validation. Start a raw 24-byte queue with a test factory and verify only raw-byte equality and pointer progression.

- [ ] **Step 3: Add detection and race cases**

Run the MAC scenario once in fixed 10 ns Poll mode and once in IRQ mode. Add: lost IRQ recovered by 1 us watchdog with zero ACK, spurious IRQ with one ACK and zero delivery, invalid current pointer, failed current-pointer read, multiple completions per IRQ, and reset while `read_msgq_current_ptr` is blocked. Require stale reset-epoch results to deliver nothing.

- [ ] **Step 4: Run the driver-conformance suite**

```bash
ssh ubuntu@10.11.10.53 "bash -lc '
  cd /home/ubuntu/wn/icpu-kernel-driver &&
  git rev-parse HEAD &&
  sha256sum /home/ubuntu/Downloads/emp.zip
'"
scripts/run_vcs_remote.sh msgq_driver_conformance_test msgq
```

Expected: the first two output records contain `f2c9cd66b6e6b972055efe094b6277c5e362958d` and `dbc70200efdab93a96522a5115c9b81059b01fc512d587026b9b69b9db130cae`; all setup arguments/event order, parsing, wrap, no-refill-publish, Poll/IRQ/watchdog, and reset-race checks pass with zero UVM errors/fatals.

- [ ] **Step 5: Commit driver-conformance verification**

```bash
git add tb/mocks/msgq_mock_dut.sv tb/mocks/msgq_mock_adapter.sv \
  tb/tests/msgq_driver_conformance_test.sv tb/msgq_test_pkg.sv
git commit -m "test(msgq): verify driver queue lifecycle and detection"
```

### Task 6: Documentation and Independent/Combined Regression

**Files:**
- Modify: `README.md`
- Modify: `scripts/check_sv_layout.sh`

**Interfaces:**
- Consumes: all MSGQ tasks.
- Produces: documented extension rules and integration acceptance evidence.

- [ ] **Step 1: Document profiles and the non-conformance boundary**

Add a MSGQ section listing exact dimensions, timing defaults, modulo pointer formula, initial-only doorbell, auto-recycle behavior, and adapter callbacks. State explicitly that FSE/IACL/EACL/vDPA/notify expose raw fixed-size bytes and a factory seam without field semantics.

- [ ] **Step 2: Add layout requirements and address/business isolation scans**

Require `src/msgq/msgq_pkg.sv` and all eleven planned MSGQ `.sv` files in `check_sv_layout.sh`. Run:

```bash
make check-layout
rg -n "0x[0-9a-fA-F]+|CMDQ|TLPQ|mailbox_pkg|pcie_tl" src/msgq
```

Expected: layout exits zero; the isolation scan prints no matches.

- [ ] **Step 3: Run MSGQ and legacy GQ/mailbox regression**

```bash
for test_name in msgq_profile_test msgq_entry_test msgq_completion_test \
  msgq_driver_conformance_test; do
  scripts/run_vcs_remote.sh "$test_name" msgq
done
scripts/run_vcs_remote.sh gq_regression_test mailbox gq
scripts/run_vcs_remote.sh mailbox_wrap_test mailbox gq
```

Expected: every remote test exits zero with zero UVM errors/fatals; MSGQ compiles without other business packages.

- [ ] **Step 4: Commit documentation and layout gate**

```bash
git add README.md scripts/check_sv_layout.sh
git commit -m "docs(msgq): describe profiles and raw extension contract"
```

## Plan Completion Checks

- Map spec Sections 7, 10, 11, 12.2, 12.5, 12.6 and Acceptance Criteria 2, 3, 5, 9, 10 to a task and named assertion above.
- Run `rg -n 'T[B]D|T[O]DO|implement[[:space:]]+later|fill in detai[l]s|appropriate error handlin[g]|similar to Tas[k]' docs/superpowers/plans/2026-08-27-msgq-gq-business-library.md` and require no matches.
- Run `rg -n "msgq_entry_factory|read_msgq_current_ptr|MSGQ_PROFILE_EMP_ACTIVE|GQ_RX_AUTO_RECYCLE" docs/superpowers/plans/2026-08-27-msgq-gq-business-library.md src/msgq tb` and correct any type/member-name mismatch.
- Verify `git diff --check` and `git status --short` before handoff.
