# TLPQ Residual Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four final-review residuals by publishing corrected `pcie_work` Completion decode and TLP clone behavior, advancing the queue project pin, and hardening the local address gate and clone contract.

**Architecture:** The PCIe transaction model remains the sole owner of standard TLP semantics. Completion requester/Tag decode and subtype deep-copy behavior are fixed and regression-tested in `pcie_work`; the queue project consumes one published feature-branch commit without a local compatibility repair. The local layout gate gains lexical coverage for semicolonless defines and camelCase address identifiers, while the design documentation records the corrected dependency contract.

**Tech Stack:** SystemVerilog, UVM 1.2, Bash, Perl, Git submodules, VCS W-2024.09-SP1 on `ubuntu@10.11.10.53`.

**Spec:** `docs/superpowers/specs/2026-08-27-msgq-cmdq-tlpq-gq-reuse-design.md`

## Execution status

This plan has been executed. The queue project consumes the remotely reachable
`pcie_work` revision `a86860d0551af62b21a8faffadc7097e8118bb07`, which contains
the corrected Completion decode, complete 10-bit Tag codec, and detached TLP
copy contract. Per user authorization, that revision was fast-forwarded to
`pcie_work/main`; the superproject work was then committed as `de2ae44` and
fast-forwarded locally to `feature/generic-queue-uvm`.

The checkbox steps below are retained as the historical implementation record.
Where an earlier step describes the old pin, absent upper Tag bits, or an
unpublished feature branch, the executed result above supersedes that wording.

## Global Constraints

- All repository-owned HDL files use `.sv`; no new `.svh`, `.v`, or `.vh` file is allowed.
- Standard PCIe TLP encode/decode/copy semantics stay in `pcie_work`; `src/tlpq` must not add a local parser or Completion repair.
- Simulations run on `ubuntu@10.11.10.53` through a Bash login shell with the host VCS/license environment.
- The upstream fix is published at the exact remotely reachable revision
  `a86860d0551af62b21a8faffadc7097e8118bb07`, now fast-forwarded to
  `pcie_work/main` with no force update. The queue superproject was merged
  locally only, and has not been pushed.
- The superproject advances only to the exact published, remotely reachable `pcie_work` commit and remains clean after the pin update.

---

### Task 1: Correct and test upstream Completion decode

**Files:**
- Modify: `pcie_work/pcie_tl_vip/tests/pcie_tl_virtio_fix_regression_test.sv`
- Modify: `pcie_work/pcie_tl_vip/src/shared/pcie_tl_codec.sv`

**Interfaces:**
- Consumes: `pcie_tl_codec.encode()` Completion layout `{DW1 completer/status/count, DW2 requester/tag/lower_addr}`.
- Produces: `pcie_tl_codec.decode()` with Completion `requester_id` and
  `tag[7:0]` taken from DW2 for Cpl, CplD, CplLk, and CplDLk, while Tag
  `tag[9:8]` is reconstructed from DW0 bits 23 and 19.

- [x] **Step 1: Add the failing Completion round-trip regression**

Add `check_completion_codec_fields()` to `pcie_tl_virtio_fix_unit_test` and call it from `run_phase()`. Use literal Cpl and CplD objects whose requester/Tag deliberately differ from DW1-derived values:

```systemverilog
original.requester_id = 16'h1357;
original.tag          = 10'h0a6;
original.completer_id = 16'h89ab;
codec.encode(original, bytes);
decoded = codec.decode(bytes);
if (decoded.requester_id != 16'h1357 || decoded.tag != 10'h0a6)
    `uvm_error("FIX_CPL_CODEC", "Completion requester/Tag did not decode from DW2")
```

Repeat with CplD requester `16'h2468`, Tag `10'h0b7`, completer `16'h9abc`, and an eight-byte literal payload. Cast to `pcie_tl_cpl_tlp` and retain assertions for kind, completer ID, requester ID, Tag, and payload.

- [x] **Step 2: Run RED on the simulation host**

Copy the detached `pcie_work` tree to a validated `/tmp/pcie_work.*` directory on `10.11.10.53`, rewrite only the temporary filelist's absolute local roots, and run:

```bash
vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  -f filelist.remote.f -o simv -l compile.log
./simv +UVM_TESTNAME=pcie_tl_virtio_fix_unit_test \
  +UVM_VERBOSITY=UVM_MEDIUM +TAG_BIT=8 -l run.log
```

Expected: compile succeeds and the UVM summary contains at least one `FIX_CPL_CODEC` error.

- [x] **Step 3: Implement the minimal decode correction**

In the Completion arm of `fill_type_specific()` add the DW2 decode and retain
the upper Tag bits decoded from DW0:

```systemverilog
tlp.requester_id   = dw2[31:16];
tlp.tag[7:0]       = dw2[15:8];
cpl.lower_addr     = dw2[6:0];
```

Do not change non-Completion common decoding. The current wire codec carries
the complete 10-bit Tag using DW0[23], DW0[19], and the type-specific low byte.

- [x] **Step 4: Run GREEN on the simulation host**

Run the same unit test from Step 2. Expected: command exit 0 and final UVM warning/error/fatal counts `0/0/0`.

---

### Task 2: Complete and test upstream TLP deep-copy semantics

**Files:**
- Modify: `pcie_work/pcie_tl_vip/tests/pcie_tl_virtio_fix_regression_test.sv`
- Modify: `pcie_work/pcie_tl_vip/src/types/pcie_tl_prefix.sv`
- Modify: `pcie_work/pcie_tl_vip/src/types/pcie_tl_tlp.sv`

**Interfaces:**
- Consumes: UVM `uvm_object::clone()` through a base `pcie_tl_tlp` handle.
- Produces: same-runtime-subtype detached copies of every current TLP subclass, including common `at`, subtype fields, dynamic byte arrays, and independent prefix objects. Runtime read-back state remains intentionally uncopied.

- [x] **Step 1: Add the failing clone regression**

Add `check_tlp_clone_semantics()` to the same upstream unit test and call it from `run_phase()`. Clone through base handles and require literal values for all previously uncovered state:

```systemverilog
pcie_tl_tlp base_src;
pcie_tl_tlp base_clone;
pcie_tl_cfg_tlp cfg_src;
pcie_tl_cfg_tlp cfg_clone;

cfg_src = pcie_tl_cfg_tlp::type_id::create("clone_cfg_src");
cfg_src.at           = 2'b10;
cfg_src.completer_id = 16'hcafe;
cfg_src.reg_num      = 10'h155;
cfg_src.first_be     = 4'ha;
cfg_src.prefixes.push_back(pcie_tl_prefix::create_pasid(20'h54321));
cfg_src.has_prefix = 1;
base_src = cfg_src;
if (!$cast(base_clone, base_src.clone()) || !$cast(cfg_clone, base_clone))
    `uvm_error("FIX_TLP_CLONE", "Config clone lost runtime subtype")
```

Require `at`, all Config fields, exact prefix data, and a distinct prefix handle; mutate the source prefix and require the clone to remain unchanged. Add corresponding literal-field checks for IO (`addr`, `first_be`), Message (`msg_code`, `msg_addr`, `target_id`), Vendor (`vendor_id`, `vendor_data[]` plus source mutation), and LTR (both values/scales/requirement bits). Existing Memory, Completion, and Atomic `do_copy()` implementations remain covered by their existing tests.

- [x] **Step 2: Run RED on the simulation host**

Run `pcie_tl_virtio_fix_unit_test` as in Task 1. Expected: `FIX_TLP_CLONE` errors for missing common/subtype fields and non-detached prefixes.

- [x] **Step 3: Implement minimal deep-copy coverage**

Add `at` to `pcie_tl_tlp.do_copy()`. Clone each prefix object into a fresh queue entry. Add `pcie_tl_prefix.do_copy()` for `prefix_type/raw_dw`. Add subtype `do_copy()` methods with only their declared semantic fields:

```systemverilog
virtual function void do_copy(uvm_object rhs);
    pcie_tl_cfg_tlp rhs_;
    super.do_copy(rhs);
    if (!$cast(rhs_, rhs)) return;
    this.completer_id = rhs_.completer_id;
    this.reg_num      = rhs_.reg_num;
    this.first_be     = rhs_.first_be;
endfunction
```

Apply the same pattern to IO, Message, Vendor, and LTR. Allocate Vendor dynamic bytes with `new[rhs_.vendor_data.size()](rhs_.vendor_data)`.

- [x] **Step 4: Run GREEN and the upstream smoke regression**

Run `pcie_tl_virtio_fix_unit_test` and the registered
`pcie_tl_smoke_mem_test` on `.53`. Expected: both exit 0 with final UVM
warning/error/fatal counts `0/0/0`.

- [x] **Step 5: Commit and publish the upstream fix**

The upstream fix was committed and published, then fast-forwarded to
`pcie_work/main` as authorized by the user. Verify reachability with:

```bash
new_pin=$(git rev-parse HEAD)
git ls-remote origin refs/heads/fix/tlp-codec-copy-contract | grep "$new_pin"
```

---

### Task 3: Advance the queue-project pin and harden local gates

**Files:**
- Modify: `pcie_work` gitlink
- Modify: `scripts/check_sv_layout.sh`
- Create: `scripts/check_sv_layout_test.sh`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-27-msgq-cmdq-tlpq-gq-reuse-design.md`
- Modify: `docs/superpowers/plans/2026-08-27-tlpq-pcie-gq-business-library.md`
- Modify: `.superpowers/sdd/2026-08-27-tlpq-pcie-gq-business-library/progress.md`

**Interfaces:**
- Consumes: remotely reachable upstream SHA produced by Task 2.
- Produces: exact pin enforcement, rejection of semicolonless address macros
  and camelCase address identifiers, a width-macro false-positive regression,
  and an accurate direct-TLP clone contract.

- [x] **Step 1: Add the failing layout-gate regression**

Create `scripts/check_sv_layout_test.sh`. It uses `mktemp -d`, writes isolated `.sv` fixtures, and requires `--scan-tlpq-addresses-only` to reject:

```systemverilog
`define RX_CSR_ADDRESS 64'h1234_0000
```

and:

```systemverilog
longint unsigned csrAddress = 64'h1234_0000;
```

It also requires comment/string-only occurrences to remain accepted. Run it before the scanner change; expected: nonzero test-script exit because both bad fixtures are falsely accepted.

- [x] **Step 2: Implement scanner coverage and run GREEN**

Normalize camel/Pascal identifier boundaries before the existing address-token match:

```perl
$identifier =~ s/([A-Z]+)([A-Z][a-z])/$1_$2/g;
$identifier =~ s/([a-z0-9])([A-Z])/$1_$2/g;
```

Scan each logical preprocessor `define` directive independently of semicolon-delimited statements, including backslash continuations, while preserving comment/string masking. Run `scripts/check_sv_layout_test.sh`; expected: exit 0.

- [x] **Step 3: Update the exact dependency pin and contracts**

Stage the published submodule SHA. Replace the old SHA in the layout gate, README, binding spec, and original TLPQ plan with the exact `git -C pcie_work rev-parse HEAD` output. Document that direct TLP retention is supported by the new pin's detached subtype/prefix deep-copy contract and that Completion requester/Tag decode comes from DW2.

- [x] **Step 4: Append the decision ledger**

Append RED/GREEN evidence, published branch/SHA, pin advance, scanner mutations, and the user authorization to the existing SDD progress ledger. Preserve all historical rulings unchanged and add a new ruling describing the cost of advancing to an off-main but published feature-branch commit.

- [x] **Step 5: Commit the superproject residual closure**

Commit the gitlink, scanner/test, docs, plan, and ledger without merging or pushing the superproject branch.

---

### Task 4: Fresh integrated verification and handoff

**Files:**
- Verify only; no production file is added in this task.

**Interfaces:**
- Consumes: Tasks 1-3 committed state.
- Produces: fresh local and `.53` evidence for generic merge readiness.

- [x] **Step 1: Run local structural gates**

```bash
bash -n scripts/check_sv_layout.sh
bash -n scripts/check_sv_layout_test.sh
scripts/check_sv_layout_test.sh
make check-layout
git diff --check
git submodule status
```

Expected: all commands exit 0; the PCIe gitlink has a leading space and the exact published SHA; no repository-owned `.svh`, `.v`, or `.vh` file exists.

- [x] **Step 2: Run focused TLPQ simulations on `.53`**

Run `tlpq_pcie_smoke_test`, `tlpq_bridge_test`, `tlpq_desc_test`, `tlpq_tx_test`, and `tlpq_driver_conformance_test` through `scripts/run_vcs_remote.sh`. Expected: every command exits 0 with final UVM warning/error/fatal counts `0/0/0`.

- [x] **Step 3: Run the four-business combined regression on `.53`**

```bash
scripts/run_vcs_remote.sh gq_smoke_test mailbox,msgq,cmdq,tlpq gq
```

Expected: exit 0 and final UVM warning/error/fatal counts `0/0/0`.

- [x] **Step 4: Audit repository state and rulings**

Require clean upstream and superproject worktrees, confirm the published upstream ref with `git ls-remote`, list all `Ruling:` ledger lines with their costs, and record both commit SHAs. The superproject was fast-forwarded locally to `feature/generic-queue-uvm`; it was not pushed.
