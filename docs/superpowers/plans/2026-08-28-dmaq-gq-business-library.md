# DMAQ Generic Queue Business Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an independent DMAQ UVM business library that reuses GQ, exactly packs the EMP 32-byte DMA descriptor, executes all three proven transfer directions, and supports configurable queue geometry and timing with EMP-compatible defaults.

**Architecture:** GQ gains a generic configurable initial logical sequence. DMAQ specializes GQ with a fixed 32-byte descriptor, bit-15 index/phase pointer, writeback completion, semantic register adapter, configurable one-ring environment profile, and a submit-one/wait-one transfer sequence; caller-provided source and destination addresses remain borrowed. The default depth/initial/timing values reproduce EMP, while validated overrides are explicitly user extensions.

**Tech Stack:** SystemVerilog, UVM 1.2, GQ, `host_mem`, GNU Make, Bash, VCS W-2024.09-SP1 on `ubuntu@10.11.10.53`, EMP archive SHA-256 `dbc70200efdab93a96522a5115c9b81059b01fc512d587026b9b69b9db130cae`.

**Spec:** `docs/superpowers/specs/2026-08-28-dmaq-gq-business-library-design.md`

## Global Constraints

- Before Task 1, use `superpowers:using-git-worktrees` and execute this plan in an isolated worktree created from commit `6022696` or a descendant containing only reviewed documentation changes.
- All repository-owned HDL files use `.sv`; do not create a `.svh` file.
- `dmaq_pkg` may import only `uvm_pkg`, `host_mem_pkg`, and `gq_pkg`; it must not depend on Mailbox, MSGQ, CMDQ, TLPQ, or PCIe packages.
- `DMAQ_DESC_BYTES` is always 32 and is not user-configurable.
- The environment defaults are depth 32, initial logical sequence 31, fixed Poll interval 10 ns, and final completion timeout 500 ns.
- User depth must be a power of two in 2..32768; user initial logical sequence must be below depth; Poll interval must be nonzero; final timeout must exceed Poll interval.
- The sequence timeout defaults to 500 ns, must be nonzero, and may be overridden independently per transfer.
- The EMP default first uses slot 31 and publishes `16'h8000`; a custom profile follows the same index/phase formula using its configured depth and initial sequence.
- Publish exactly once when logical tail advances. Polling, timeout, IRQ watchdog, and completion waiting never rewrite an unchanged tail.
- Source and destination addresses are caller-owned borrowed values. DMAQ never allocates, copies, frees, or range-interprets the business buffers.
- Length is exactly one descriptor and must lie in 1..65535; only descriptor flags may change during writeback.
- Register addresses and transport behavior remain entirely in user-derived `dmaq_reg_adapter` implementations.
- The standard profile is Poll. IRQ/ACK/watchdog are supported GQ extensions and are not described as EMP-validated DMAQ behavior.
- Run every simulation on `ubuntu@10.11.10.53` through `scripts/run_vcs_remote.sh`, which enters the host Bash login/interactive environment. Do not run SVT.
- Preserve submodule pins `host_mem=3b9e000d5df4d10efbb3029f43605e0362e0caca` and `pcie_work=a86860d0551af62b21a8faffadc7097e8118bb07`.

---

## File Map

```text
src/gq/gq_queue_cfg.sv                    generic initial logical sequence setting
src/gq/gq_queue_engine.sv                 initialize/reset/cleanup state application
src/dmaq/dmaq_pkg.sv                      independent public DMAQ package
src/dmaq/dmaq_types.sv                    constants, endpoint, operation, result, metadata
src/dmaq/dmaq_tx_desc.sv                  fixed 32-byte borrowed-address descriptor
src/dmaq/dmaq_completion.sv               contiguous USED writeback completion
src/dmaq/dmaq_ptr_codec.sv                configurable-depth bit-15 phase pointer
src/dmaq/dmaq_reg_adapter.sv               semantic reset/config/tail/IRQ API
src/dmaq/dmaq_env.sv                       configurable one-ring profile with EMP defaults
src/dmaq/dmaq_sequences.sv                 submit-one/inclusive-wait transfer API
tb/dmaq_test_pkg.sv                        DMAQ-only test package
tb/mocks/dmaq_mock_adapter.sv              semantic trace, tail history, IRQ cancellation
tb/mocks/dmaq_mock_dut.sv                  slot inspection and flags-only completion
tb/tests/dmaq_desc_test.sv                 layout, validation, corruption, ownership tests
tb/tests/dmaq_sequence_test.sv             profile and synchronous sequence tests
tb/tests/dmaq_driver_conformance_test.sv   real-engine EMP/default and extension flows
Makefile                                   independent DMAQ library/test selection
tb/tb_top.sv                               conditional DMAQ test-package import
scripts/check_sv_layout.sh                 recursive DMAQ file and isolation gate
README.md                                  public contract and usage
```

### Task 1: Generic Initial Logical Sequence

**Files:**
- Modify: `src/gq/gq_queue_cfg.sv`
- Modify: `src/gq/gq_queue_engine.sv`
- Modify: `tb/tests/gq_config_test.sv`

**Interfaces:**
- Consumes: existing `gq_logical_seq_t`, `gq_queue_cfg.depth`, engine lifecycle locks, and `head_seq()`/`tail_seq()` accessors.
- Produces: `gq_queue_cfg.initial_logical_seq`; initialization, reset, cleanup, diagnostics, submission, and accessors all observe that same starting value.

- [ ] **Step 1: Add failing configuration and lifecycle assertions**

In `gq_config_test`, require the new field to default to zero, accept the last slot, reject a value equal to depth, and configure the existing lifecycle engine with start 7:

```systemverilog
if (cfg.initial_logical_seq != 0)
    `uvm_fatal("CFG_INITIAL_SEQ", "default initial logical sequence is not zero")
cfg.initial_logical_seq = 31;
if (!cfg.validate(reason))
    `uvm_fatal("CFG_INITIAL_SEQ", {"valid initial sequence rejected: ", reason})
cfg.initial_logical_seq = 32;
expect_invalid(cfg, "initial logical sequence equal to depth");
cfg.initial_logical_seq = 0;

lifecycle_cfg.initial_logical_seq = 7;
```

After `lifecycle_engine.initialize()`, after `assert_reset()`, after `release_reset()`, and after `cleanup()`, assert `head_seq()==7`, `tail_seq()==7`, and `outstanding_count()==0`. Keep the existing mailbox environments at their default zero and locate one engine through the existing component hierarchy:

```systemverilog
uvm_component default_component;
gq_queue_engine default_engine;

default_component = uvm_root::get().find("uvm_test_top.env.tx_3.engine");
if (!$cast(default_engine, default_component) ||
    default_engine.head_seq() != 0 || default_engine.tail_seq() != 0)
    `uvm_fatal("CFG_INITIAL_SEQ", "default GQ queue did not start at zero")
```

- [ ] **Step 2: Run the RED GQ test**

Run:

```bash
scripts/run_vcs_remote.sh gq_config_test mailbox gq
```

Expected: VCS compilation fails because `gq_queue_cfg` has no member named `initial_logical_seq`.

- [ ] **Step 3: Add and validate the generic configuration field**

Add the field and default in `gq_queue_cfg`:

```systemverilog
gq_logical_seq_t initial_logical_seq;

function new(string name = "gq_queue_cfg");
    super.new(name);
    initial_logical_seq = 0;
    // Preserve every existing constructor assignment.
endfunction
```

After the existing power-of-two depth check and before strategy validation, add:

```systemverilog
if (initial_logical_seq >= depth) begin
    reason = $sformatf(
        "initial logical sequence must be below depth (initial=%0d depth=%0d)",
        initial_logical_seq, depth);
    return 0;
end
```

- [ ] **Step 4: Apply the value at each lifecycle origin**

When a successful `initialize()` publishes newly configured ring ownership under `state_lock`, set both sequences before marking the engine ready:

```systemverilog
logical_head_seq = cfg.initial_logical_seq;
logical_tail_seq = cfg.initial_logical_seq;
```

In `release_queue_resources()`, replace both hard-coded zero assignments with the same two assignments. Do not add offsets in submit, completion, diagnostics, or accessors: those paths already use the absolute logical head/tail and must continue doing so.

- [ ] **Step 5: Run focused and compatibility GQ tests**

Run:

```bash
scripts/run_vcs_remote.sh gq_config_test mailbox gq
scripts/run_vcs_remote.sh gq_reset_test mailbox gq
scripts/run_vcs_remote.sh gq_regression_test mailbox gq
```

Expected: all three commands exit zero with a final UVM summary containing zero warnings, errors, and fatals; start 7 survives reset/cleanup and all default queues still start at zero.

- [ ] **Step 6: Commit the generic extension**

```bash
git add src/gq/gq_queue_cfg.sv src/gq/gq_queue_engine.sv \
  tb/tests/gq_config_test.sv
git commit -m "feat(gq): configure initial logical sequence"
```

### Task 2: Independent Package, Public Types, and Exact Descriptor

**Files:**
- Create: `src/dmaq/dmaq_pkg.sv`
- Create: `src/dmaq/dmaq_types.sv`
- Create: `src/dmaq/dmaq_tx_desc.sv`
- Create: `tb/dmaq_test_pkg.sv`
- Create: `tb/tests/dmaq_desc_test.sv`
- Modify: `Makefile`
- Modify: `tb/tb_top.sv`

**Interfaces:**
- Consumes: `gq_desc_base` descriptor hooks and `gq_addr_t`.
- Produces: `dmaq_endpoint_t`, operation/result enums, BDF helpers, hardware metadata, constants, and `dmaq_tx_desc` with a persistent completion event and no owned allocation.

- [ ] **Step 1: Write failing public-type and BDF tests**

Create `dmaq_desc_test` and require these exact declarations and helper results:

```systemverilog
if (DMAQ_DEFAULT_DEPTH != 32 ||
    DMAQ_DEFAULT_INITIAL_LOGICAL_SEQ != 31 ||
    DMAQ_DESC_BYTES != 32 ||
    DMAQ_DEFAULT_POLL_INTERVAL != 10ns ||
    DMAQ_DEFAULT_COMPLETION_TIMEOUT != 500ns)
    `uvm_fatal("DMAQ_CONSTANTS", "DMAQ public defaults diverged")

if (dmaq_ep_bdf(4'ha, 8'hbc, 1'b1) != 16'h1bca ||
    dmaq_ep_bdf(4'h3, 8'h25, 1'b0) != 16'h0253 ||
    dmaq_switch_bdf(16'hd4e5) != 16'hd4e5)
    `uvm_fatal("DMAQ_BDF", "BDF helper encoding diverged")
```

Define the endpoint type used by all later tasks as:

```systemverilog
typedef struct packed {
    dmaq_endpoint_role_e role;
    gq_addr_t            address;
    bit [15:0]           host_id;
    bit [15:0]           bdf_raw;
} dmaq_endpoint_t;
```

- [ ] **Step 2: Write three independent failing descriptor vectors**

For AF-to-Host, use length `16'h1234`, source `{AF,64'h1122334455667788,16'h99aa,16'h1bca}`, destination `{HOST,64'h8877665544332211,16'hbbcc,16'hddee}`, and require:

```systemverilog
byte expected_af_to_host[] = '{
    8'h01,8'h00, 8'hee,8'hdd, 8'hcc,8'hbb, 8'h34,8'h12,
    8'h11,8'h22,8'h33,8'h44,8'h55,8'h66,8'h77,8'h88,
    8'h88,8'h77,8'h66,8'h55,8'h44,8'h33,8'h22,8'h11,
    8'hca,8'h1b, 8'haa,8'h99, 8'h34,8'h12, 8'h00,8'h00};
```

For Host-to-AF, use length 1, source `{HOST,64'h0102030405060708,16'h4433,16'h2211}`, destination `{AF,64'h1020304050607080,16'h8877,16'h6655}`, and require:

```systemverilog
byte expected_host_to_af[] = '{
    8'h01,8'h00, 8'h55,8'h66, 8'h77,8'h88, 8'h01,8'h00,
    8'h80,8'h70,8'h60,8'h50,8'h40,8'h30,8'h20,8'h10,
    8'h08,8'h07,8'h06,8'h05,8'h04,8'h03,8'h02,8'h01,
    8'h11,8'h22, 8'h33,8'h44, 8'h01,8'h00, 8'h00,8'h00};
```

For Host-to-Host, use length 65535, source `{HOST,64'hf0e0d0c0b0a09080,16'h1357,16'habcd}`, destination `{HOST,64'h0f1e2d3c4b5a6978,16'hbeef,16'h2468}`, and require:

```systemverilog
byte expected_host_to_host[] = '{
    8'h01,8'h00, 8'h68,8'h24, 8'hef,8'hbe, 8'hff,8'hff,
    8'h78,8'h69,8'h5a,8'h4b,8'h3c,8'h2d,8'h1e,8'h0f,
    8'h80,8'h90,8'ha0,8'hb0,8'hc0,8'hd0,8'he0,8'hf0,
    8'hcd,8'hab, 8'h57,8'h13, 8'hff,8'hff, 8'h00,8'h00};
```

Each descriptor must `prepare()`, `mark_available(phase)`, pack to exactly 32 bytes, match its vector byte-for-byte, and report `owned_allocation_count()==0`.

- [ ] **Step 3: Add failing role, length, one-shot, and mutation tests**

Require valid role pairs only:

```systemverilog
DMAQ_AF_TO_HOST:   source.role == DMAQ_ENDPOINT_AF &&
                   destination.role == DMAQ_ENDPOINT_HOST
DMAQ_HOST_TO_AF:   source.role == DMAQ_ENDPOINT_HOST &&
                   destination.role == DMAQ_ENDPOINT_AF
DMAQ_HOST_TO_HOST: source.role == DMAQ_ENDPOINT_HOST &&
                   destination.role == DMAQ_ENDPOINT_HOST
```

Require length 1 and 65535 accepted, length 0 and 65536 rejected, and a second `prepare()` rejected. Starting from valid packed bytes, independently flip one byte in each stable field group—destination BDF, destination host ID, destination length, destination address, source address, source BDF, source host ID, source length, and reserved—and require `unpack()` false. Change only flags from `AVAIL` to `AVAIL|USED`, require `unpack()` true, `is_complete()` true, `parse_completion()` true, and `completion_event.is_on()` after parsing.

- [ ] **Step 4: Run the RED independent build**

Run:

```bash
scripts/run_vcs_remote.sh dmaq_desc_test dmaq
```

Expected: Make rejects unknown `LIBS=dmaq` or VCS reports missing `dmaq_pkg`; the new test cannot pass before the package/build maps exist.

- [ ] **Step 5: Implement constants, types, helpers, and fixed descriptor**

Define:

```systemverilog
localparam int unsigned DMAQ_DEFAULT_DEPTH = 32;
localparam gq_logical_seq_t DMAQ_DEFAULT_INITIAL_LOGICAL_SEQ = 31;
localparam int unsigned DMAQ_DESC_BYTES = 32;
localparam time DMAQ_DEFAULT_POLL_INTERVAL = 10ns;
localparam time DMAQ_DEFAULT_COMPLETION_TIMEOUT = 500ns;
localparam bit [15:0] DMAQ_DESC_AVAIL = 16'h0001;
localparam bit [15:0] DMAQ_DESC_USED  = 16'h0002;

typedef enum int {DMAQ_AF_TO_HOST, DMAQ_HOST_TO_AF, DMAQ_HOST_TO_HOST}
    dmaq_operation_e;
typedef enum bit {DMAQ_ENDPOINT_AF, DMAQ_ENDPOINT_HOST}
    dmaq_endpoint_role_e;
typedef enum int {DMAQ_RESULT_OK, DMAQ_RESULT_SUBMIT_ERROR,
                  DMAQ_RESULT_TIMEOUT} dmaq_result_status_e;
typedef struct packed {
    bit [31:0] queue_hid;
    bit [15:0] queue_bdf;
    bit [15:0] msix_index;
    bit        msix_valid;
} dmaq_hw_cfg_t;
```

Implement `dmaq_ep_bdf(function_number,vf_number,vf_valid)` as `{3'b000,vf_valid,vf_number,function_number}` and `dmaq_switch_bdf(raw_bdf)` as identity. Implement `dmaq_tx_desc` with public `operation`, `source`, `destination`, `int unsigned transfer_length`, `flags`, and `uvm_event completion_event`. Snapshot every stable field during one-shot `prepare()`, set both wire lengths from the validated integer, force reserved zero, allow only flags to differ in `unpack()`, and trigger the persistent event only after a valid USED completion.

- [ ] **Step 6: Add independent build/test selection**

Add:

```make
LIB_SOURCE_dmaq := src/dmaq/dmaq_pkg.sv
TEST_PACKAGE_dmaq := tb/dmaq_test_pkg.sv
TEST_DEFINE_dmaq := +define+QUEUE_TEST_DMAQ
```

Add to `tb_top.sv`:

```systemverilog
`ifdef QUEUE_TEST_DMAQ
    import dmaq_test_pkg::*;
`endif
```

`dmaq_pkg.sv` imports only the permitted packages and includes `dmaq_types.sv` before `dmaq_tx_desc.sv`. `dmaq_test_pkg.sv` imports `dmaq_pkg` and initially includes `host_mem_manager.sv` and `dmaq_desc_test.sv`.

- [ ] **Step 7: Run descriptor RED-to-GREEN verification**

Run:

```bash
scripts/run_vcs_remote.sh dmaq_desc_test dmaq
```

Expected: constants, BDF helpers, all three vectors, role/length rejection, flags-only writeback, persistent completion, and zero owned allocations pass with a pristine UVM summary.

- [ ] **Step 8: Commit the descriptor package**

```bash
git add src/dmaq/dmaq_pkg.sv src/dmaq/dmaq_types.sv \
  src/dmaq/dmaq_tx_desc.sv tb/dmaq_test_pkg.sv \
  tb/tests/dmaq_desc_test.sv Makefile tb/tb_top.sv
git commit -m "feat(dmaq): add exact borrowed-address descriptor"
```

### Task 3: Pointer, Completion, Semantic Adapter, and Configurable Environment

**Files:**
- Create: `src/dmaq/dmaq_ptr_codec.sv`
- Create: `src/dmaq/dmaq_completion.sv`
- Create: `src/dmaq/dmaq_reg_adapter.sv`
- Create: `src/dmaq/dmaq_env.sv`
- Create: `tb/mocks/dmaq_mock_adapter.sv`
- Create: `tb/tests/dmaq_sequence_test.sv`
- Modify: `src/dmaq/dmaq_pkg.sv`
- Modify: `tb/dmaq_test_pkg.sv`

**Interfaces:**
- Consumes: Task 1 `initial_logical_seq`, Task 2 fixed descriptor, `gq_index_phase_ptr_codec`, `gq_desc_writeback_completion`, `gq_hw_adapter`, and `gq_env_cfg`.
- Produces: `dmaq_ptr_codec`, `dmaq_completion`, semantic adapter callbacks, `dmaq_env_cfg.add_dmaq(queue_id,hw_cfg,reason)`, and a traceable mock adapter.

- [ ] **Step 1: Write failing pointer and contiguous-completion assertions**

Require default and custom depth vectors:

```systemverilog
if (codec.encode_publish(31, 32, 32) != 32'h0000_8000 ||
    codec.encode_publish(32, 33, 32) != 32'h0000_8001 ||
    codec.encode_publish(63, 64, 32) != 32'h0000_0000 ||
    codec.encode_publish(5, 6, 64)   != 32'h0000_0006 ||
    codec.encode_publish(63, 64, 64) != 32'h0000_8000)
    `uvm_fatal("DMAQ_PTR", "index/phase encoding diverged")
```

Place three prepared descriptors in logical order in host memory, mark the first and second USED but leave the third AVAIL, and require `dmaq_completion.query_completed()` to return `valid=1,completed_count=2`. Corrupt a stable byte in the first pending descriptor and require `valid=0,completed_count=0`.

- [ ] **Step 2: Write failing default and custom environment assertions**

Create a default `dmaq_env_cfg`, add queue 0, and require:

```systemverilog
cfg.role == GQ_TX
cfg.depth == 32
cfg.initial_logical_seq == 31
cfg.desc_size == DMAQ_DESC_BYTES
cfg.alignment == 64
cfg.status_area_size == 0
cfg.wait_mode == GQ_POLL
cfg.poll_policy == GQ_POLL_FIXED
cfg.poll_min_interval == 10ns
cfg.poll_max_interval == 10ns
cfg.poll_backoff_factor == 1
cfg.irq_watchdog_interval == 0
cfg.completion_timeout == 500ns
```

Create a separate environment, set `depth=64`, `initial_logical_seq=5`, `poll_interval=25ns`, and `completion_timeout=750ns` before `add_dmaq()`, then require those exact values in its GQ queue and require descriptor size still 32.

- [ ] **Step 3: Add failing invalid-profile and metadata-atomicity cases**

For independent new environment/adapter instances, reject depth 0, 1, 48, and 65536; reject initial sequence equal to depth; reject poll interval 0; reject final timeout equal to or below poll interval; reject null and non-DMAQ adapters. After a successful add, attempt a duplicate with distinct hardware metadata and require the existing queue count and `adapter.hw_cfg` to remain unchanged.

Use one helper that calls `add_dmaq()` and requires a nonempty reason without adding a queue or changing metadata:

```systemverilog
function void expect_profile_reject(dmaq_env_cfg candidate,
                                    dmaq_mock_adapter candidate_adapter,
                                    dmaq_hw_cfg_t requested_hw_cfg,
                                    string label);
    dmaq_hw_cfg_t before_hw_cfg;
    string reason;

    before_hw_cfg = candidate_adapter.hw_cfg;
    if (candidate.add_dmaq(0, requested_hw_cfg, reason) || reason == "" ||
        candidate.queues.num() != 0 || candidate_adapter.hw_cfg != before_hw_cfg)
        `uvm_fatal("DMAQ_PROFILE_REJECT", {label, " was not atomic"})
endfunction
```

- [ ] **Step 4: Add failing semantic trace and fixed-size adapter cases**

Require this order and content for queue 7:

```text
RESET(queue=7)
CONFIGURE(queue=7,base=0x0000000120000000,depth=64,size=32,hid=0x89abcdef,bdf=0x1234,msix=0x0055,valid=1)
ENABLE(queue=7)
PUBLISH(queue=7,tail=0x0006)
DISABLE(queue=7)
```

Require TX role, descriptor size 32, nonzero upper raw-tail bits rejected with no semantic callback, and descriptor size 16/64 rejected with no configure callback. Exercise `wait_irq()` and `ack_irq()` through persistent mock events.

- [ ] **Step 5: Run the RED profile test**

Run:

```bash
scripts/run_vcs_remote.sh dmaq_sequence_test dmaq
```

Expected: VCS reports unresolved `dmaq_ptr_codec`, `dmaq_completion`, `dmaq_reg_adapter`, or `dmaq_env_cfg`.

- [ ] **Step 6: Implement thin pointer and completion strategies**

Implement:

```systemverilog
class dmaq_ptr_codec extends gq_index_phase_ptr_codec;
    `uvm_object_utils(dmaq_ptr_codec)
    function new(string name = "dmaq_ptr_codec");
        super.new(name, 15, 15);
    endfunction
endclass

class dmaq_completion extends gq_desc_writeback_completion;
    `uvm_object_utils(dmaq_completion)
    function new(string name = "dmaq_completion");
        super.new(name);
    endfunction
endclass
```

Do not override generic completion ordering; descriptor `unpack()` supplies DMAQ stable-field enforcement.

- [ ] **Step 7: Implement the address-free adapter**

Declare these pure semantic callbacks:

```systemverilog
pure virtual task reset_dmaq(int unsigned queue_id);
pure virtual task configure_dmaq_registers(
    int unsigned queue_id, gq_addr_t base, int unsigned depth,
    int unsigned desc_size, dmaq_hw_cfg_t hw_cfg);
pure virtual task enable_dmaq(int unsigned queue_id);
pure virtual task disable_dmaq(int unsigned queue_id);
pure virtual task write_dmaq_tail(int unsigned queue_id, bit [15:0] tail);
pure virtual task wait_dmaq_irq(int unsigned queue_id);
pure virtual task ack_dmaq_irq(int unsigned queue_id);
```

Generic configure validates TX and `desc_size==DMAQ_DESC_BYTES`, then calls reset/configure/enable. Publish rejects upper bits and otherwise calls `write_dmaq_tail()` once. Disable, wait, and ACK delegate exactly once. No class field or callback accepts a register address.

- [ ] **Step 8: Implement validated environment defaults and overrides**

Define public fields with exact constructor defaults:

```systemverilog
depth = DMAQ_DEFAULT_DEPTH;
initial_logical_seq = DMAQ_DEFAULT_INITIAL_LOGICAL_SEQ;
poll_interval = DMAQ_DEFAULT_POLL_INTERVAL;
completion_timeout = DMAQ_DEFAULT_COMPLETION_TIMEOUT;
```

`add_dmaq()` first casts the adapter, rejects an existing queue, validates all four fields, creates a TX `gq_queue_cfg` with fixed descriptor size 32 and exact timing, installs `dmaq_ptr_codec`/`dmaq_completion`, validates that queue, then calls `add_queue()`. Only after successful ownership transfer assign `installed_adapter.hw_cfg = hw_cfg`; no failure path mutates adapter metadata.

- [ ] **Step 9: Implement the mock adapter and run GREEN verification**

The mock records per-queue configured base/depth/size/metadata, tail history, callback counts, and trace strings. `trigger_irq()` uses a persistent `uvm_event`; `disable_dmaq()` triggers a cancellation event so a blocked `wait_dmaq_irq()` returns during reset/cleanup; `ack_dmaq_irq()` clears the IRQ event.

Run:

```bash
scripts/run_vcs_remote.sh dmaq_sequence_test dmaq
scripts/run_vcs_remote.sh dmaq_desc_test dmaq
```

Expected: default/custom profiles, invalid-profile atomicity, pointer vectors, contiguous completion, semantic order, fixed descriptor size, and IRQ delegation pass.

- [ ] **Step 10: Commit strategies, adapter, and environment**

```bash
git add src/dmaq/dmaq_ptr_codec.sv src/dmaq/dmaq_completion.sv \
  src/dmaq/dmaq_reg_adapter.sv src/dmaq/dmaq_env.sv \
  src/dmaq/dmaq_pkg.sv tb/mocks/dmaq_mock_adapter.sv \
  tb/tests/dmaq_sequence_test.sv tb/dmaq_test_pkg.sv
git commit -m "feat(dmaq): configure pointer completion and register profile"
```

### Task 4: Synchronous Transfer Sequence

**Files:**
- Create: `src/dmaq/dmaq_sequences.sv`
- Modify: `src/dmaq/dmaq_pkg.sv`
- Modify: `tb/tests/dmaq_sequence_test.sv`

**Interfaces:**
- Consumes: `gq_request`, `gq_response`, `dmaq_tx_desc.completion_event`, and Task 2 endpoint/operation/result types.
- Produces: `dmaq_transfer_sequence` with public operation/source/destination/length/timeout inputs and deterministic result status.

- [ ] **Step 1: Add a failing scripted-driver contract**

In `dmaq_sequence_test.sv`, define `dmaq_scripted_driver extends uvm_driver #(gq_request,gq_response)`. It must require exactly one `GQ_SUBMIT` descriptor, compare all sequence inputs, and return one of three scripts:

```systemverilog
if (return_submit_error || !desc.prepare()) begin
    response.status = GQ_RESOURCE_ERROR;
    response.committed_count = 0;
end else begin
    response.status = GQ_OK;
    response.committed_count = 1;
    if (complete_before_response) begin
        desc.mark_available(1'b0);
        desc.flags = DMAQ_DESC_AVAIL | DMAQ_DESC_USED;
        if (!desc.parse_completion())
            `uvm_fatal("DMAQ_SCRIPT", "early completion parse failed")
    end
end
```

For delayed completion, fork a branch that waits `completion_delay`, optionally waits one NBA and one `#1step`, then sets USED and parses. The descriptor owns no allocation, so the driver must never allocate or free source/destination addresses.

After every successful `prepare()`, call `desc.mark_available(1'b0)` before either completion script so both early and delayed paths begin from `AVAIL=1,USED=0`.

- [ ] **Step 2: Add failing submit, persistent-event, and timeout tests**

Require:

- a valid AF-to-Host request becomes `DMAQ_RESULT_OK` even when completion is triggered before the response returns;
- driver submission error becomes `DMAQ_RESULT_SUBMIT_ERROR` without waiting;
- invalid role pairing and lengths 0/65536 become `DMAQ_RESULT_SUBMIT_ERROR`;
- `completion_timeout=0` becomes `DMAQ_RESULT_SUBMIT_ERROR` without issuing a request;
- no completion by a configured 75 ns deadline becomes `DMAQ_RESULT_TIMEOUT` and leaves the endpoint structs unchanged;
- a completion in the inclusive deadline slot wins, while one `#1step` later loses.

Use explicit sequence settings so the driver checks the same public types later used by the real engine:

```systemverilog
seq.operation = DMAQ_AF_TO_HOST;
seq.source = '{DMAQ_ENDPOINT_AF, 64'h1111_2222_3333_4444,
               16'h0053, 16'h0123};
seq.destination = '{DMAQ_ENDPOINT_HOST, 64'haaaa_bbbb_cccc_dddd,
                    16'h0097, 16'h4567};
seq.transfer_length = 4096;
seq.completion_timeout = 75ns;
```

- [ ] **Step 3: Run the RED sequence test**

Run:

```bash
scripts/run_vcs_remote.sh dmaq_sequence_test dmaq
```

Expected: `dmaq_transfer_sequence` is undefined or sequence-result assertions fail.

- [ ] **Step 4: Implement the public transfer sequence**

Expose:

```systemverilog
class dmaq_transfer_sequence extends uvm_sequence #(gq_request, gq_response);
    `uvm_object_utils(dmaq_transfer_sequence)
    dmaq_operation_e operation;
    dmaq_endpoint_t source;
    dmaq_endpoint_t destination;
    int unsigned transfer_length;
    time completion_timeout;
    dmaq_result_status_e result_status;
endclass
```

The constructor sets timeout 500 ns and result `DMAQ_RESULT_SUBMIT_ERROR`. `body()` rejects zero timeout, creates exactly one descriptor, copies every public input, submits one request, and waits only after `GQ_OK/committed_count==1`. Use the CMDQ region-stable pattern: record `deadline_at=$realtime+completion_timeout`, race the persistent completion event against the delay, wait `#1step` after the delay, and accept completion when `completion_at<=deadline_at`. Do not cancel or mutate engine ownership on sequence timeout.

- [ ] **Step 5: Run all synchronous result cases**

Run:

```bash
scripts/run_vcs_remote.sh dmaq_sequence_test dmaq
```

Expected: early persistent completion, submit error, validation error, zero timeout, ordinary timeout, inclusive deadline, and one-step-late cases pass with deterministic status and zero owned allocations.

- [ ] **Step 6: Commit the sequence**

```bash
git add src/dmaq/dmaq_sequences.sv src/dmaq/dmaq_pkg.sv \
  tb/tests/dmaq_sequence_test.sv
git commit -m "feat(dmaq): add synchronous transfer sequence"
```

### Task 5: Real-GQ Driver Conformance, Poll/IRQ, Reset, and Races

**Files:**
- Create: `tb/mocks/dmaq_mock_dut.sv`
- Create: `tb/tests/dmaq_driver_conformance_test.sv`
- Modify: `tb/mocks/dmaq_mock_adapter.sv`
- Modify: `tb/dmaq_test_pkg.sv`

**Interfaces:**
- Consumes: complete DMAQ library, real `gq_queue_engine`, `gq_driver`, `gq_sequencer`, completion worker, and host-memory manager.
- Produces: driver-business conformance evidence for default EMP flow and validated custom/IRQ extensions.

- [ ] **Step 1: Build failing mock-DUT slot and completion helpers**

Define `dmaq_mock_dut` with:

```systemverilog
function void read_slot(gq_queue_engine engine,
                        gq_logical_seq_t logical_seq,
                        int unsigned depth,
                        ref byte raw[]);
function bit complete_slot(gq_queue_engine engine,
                           gq_logical_seq_t logical_seq,
                           int unsigned depth,
                           int stable_corrupt_offset = -1);
```

`read_slot()` uses `engine.ring_base()+((logical_seq%depth)*DMAQ_DESC_BYTES)`. `complete_slot()` reads 32 bytes, changes only bytes 0..1 to `DMAQ_DESC_AVAIL|DMAQ_DESC_USED`, optionally flips exactly one requested stable byte for a negative test, and writes the slot back. Add `dmaq_mock_completion extends dmaq_completion` to record every query time and ACK count at query.

- [ ] **Step 2: Add failing setup and all three transfer flows**

For a default queue require head/tail 31 and outstanding zero immediately after initialization. Start a real completion worker and sequence/driver. For AF-to-Host, Host-to-AF, and Host-to-Host:

1. start one `dmaq_transfer_sequence`;
2. wait for one new tail callback;
3. read logical slot 31/32/33 as appropriate and compare against an independently constructed 32-byte vector;
4. assert the sequence is still blocked while flags contain only AVAIL;
5. complete the slot in the mock DUT;
6. require result OK, callback delivery once, head advancement once, and zero business-buffer allocation/free calls.

Before first publish require trace order reset, configure `(depth=32,size=32)`, enable, then `PUBLISH(queue=0,tail=0x8000)`.

Create each flow from a literal role table so an operation cannot accidentally reuse another operation's endpoint roles:

```systemverilog
dmaq_operation_e operations[3] = '{
    DMAQ_AF_TO_HOST, DMAQ_HOST_TO_AF, DMAQ_HOST_TO_HOST};
dmaq_endpoint_role_e source_roles[3] = '{
    DMAQ_ENDPOINT_AF, DMAQ_ENDPOINT_HOST, DMAQ_ENDPOINT_HOST};
dmaq_endpoint_role_e destination_roles[3] = '{
    DMAQ_ENDPOINT_HOST, DMAQ_ENDPOINT_AF, DMAQ_ENDPOINT_HOST};
```

- [ ] **Step 3: Add failing tail-on-change and wrap assertions**

After the first publication, wait 100 ns without completion and require tail history size remains one. Then repeatedly complete and submit until logical tail reaches 64. Require the exact publication series:

```systemverilog
published_tails[0][0]  == 16'h8000;
published_tails[0][1]  == 16'h8001;
published_tails[0][31] == 16'h801f;
published_tails[0][32] == 16'h0000;
```

Every submission adds exactly one history entry. Poll queries, engine timeout checks, sequence timeout, and idle time add none.

- [ ] **Step 4: Add failing custom geometry and timing assertions**

Create an independent queue with depth 64, initial sequence 5, Poll 25 ns, and final timeout 750 ns. Require head/tail 5, first descriptor at physical slot 5, first raw tail `16'h0006`, and query times separated by exactly 25 ns while pending. Assert reset teardown returns both sequences to 5 and release preserves the custom profile. Also instantiate a depth-32/default-zero GQ queue and require it still begins and resets to zero.

Construct the custom configuration with the public extension fields rather than modifying engine internals:

```systemverilog
custom_cfg.depth = 64;
custom_cfg.initial_logical_seq = 5;
custom_cfg.poll_min_interval = 25ns;
custom_cfg.poll_max_interval = 25ns;
custom_cfg.poll_backoff_factor = 1;
custom_cfg.completion_timeout = 750ns;
custom_cfg.desc_size = DMAQ_DESC_BYTES;
```

- [ ] **Step 5: Add failing inclusive default timeout cases**

Run three independent default-profile transfers whose DUT completion is scheduled:

```text
before deadline: 490 ns -> DMAQ_RESULT_OK
at deadline:     500 ns in the deadline time slot -> DMAQ_RESULT_OK
after deadline:  500 ns plus #1step -> DMAQ_RESULT_TIMEOUT
```

Catch only the expected `GQ_COMPLETION_TIMEOUT` report for the late case. After sequence timeout, require head/tail, descriptor bytes, and tail history unchanged; then complete late and require the engine retires the descriptor normally without changing the already returned sequence status.

The report catcher must also require the default initial sequence reached the generic diagnostic path:

```systemverilog
if (get_id() == "GQ_COMPLETION_TIMEOUT" &&
    uvm_re_match(".*head=31.*slot=31.*", get_message()) != 0)
    `uvm_fatal("DMAQ_TIMEOUT_DIAGNOSTIC",
               "timeout diagnostic lost configured logical identity")
```

- [ ] **Step 6: Add failing corruption, IRQ, watchdog, and reset cases**

Require all of the following:

- a stable-field-corrupted USED descriptor is not retired and reports the expected invalid-query diagnostic;
- real IRQ completion queries then ACKs exactly once;
- a spurious IRQ with no USED descriptor still ACKs exactly once and retires zero;
- lost IRQ reaches a nonzero watchdog, queries completion, and does not claim EMP validation;
- reset while `wait_dmaq_irq()` is blocked causes adapter disable/cancellation, no stale ACK, no retirement, and worker recovery after release;
- reset while completion query or ACK is blocked changes epoch immediately but does not free the ring until the external callback returns;
- cleanup while tail publication is blocked calls disable, waits for the exact publish callback to return, exposes no post-disable tail write, and frees the ring exactly once;
- `host_mem_manager.leak_check()` passes and none of the borrowed endpoint addresses were passed to `free()`.

Build the IRQ extension explicitly with the DMAQ strategies and fixed descriptor size:

```systemverilog
irq_cfg.wait_mode = GQ_IRQ;
irq_cfg.irq_watchdog_interval = 100ns;
irq_cfg.poll_min_interval = 10ns;
irq_cfg.poll_max_interval = 10ns;
irq_cfg.completion_timeout = 500ns;
irq_cfg.desc_size = DMAQ_DESC_BYTES;
irq_cfg.ptr_codec = dmaq_ptr_codec::type_id::create("irq_ptr_codec");
irq_cfg.completion_source = irq_completion;
```

- [ ] **Step 7: Run the RED conformance test**

Run:

```bash
scripts/run_vcs_remote.sh dmaq_driver_conformance_test dmaq
```

Expected: compilation fails before mock DUT/conformance classes exist or the new setup, tail, timing, IRQ, and lifecycle assertions fail.

- [ ] **Step 8: Complete mocks and make the real-engine suite GREEN**

Implement only test control required by Steps 1–6. Tail callbacks inspect committed memory but never complete a descriptor automatically unless a test explicitly enables a scheduled completion. Adapter disable is the cancellation boundary for blocked tail/IRQ operations; all block/release controls use persistent `uvm_event` objects so tests cannot lose wakeups.

Run:

```bash
ssh ubuntu@10.11.10.53 \
  "bash -lc 'sha256sum /home/ubuntu/Downloads/emp.zip'"
scripts/run_vcs_remote.sh dmaq_driver_conformance_test dmaq
scripts/run_vcs_remote.sh dmaq_sequence_test dmaq
scripts/run_vcs_remote.sh dmaq_desc_test dmaq
```

Expected: the archive hash is exactly `dbc70200efdab93a96522a5115c9b81059b01fc512d587026b9b69b9db130cae`; all DMAQ tests exit zero with zero unexpected UVM warnings/errors/fatals.

- [ ] **Step 9: Commit driver conformance**

```bash
git add tb/mocks/dmaq_mock_dut.sv tb/mocks/dmaq_mock_adapter.sv \
  tb/tests/dmaq_driver_conformance_test.sv tb/dmaq_test_pkg.sv
git commit -m "test(dmaq): verify EMP transfer and queue lifecycle"
```

### Task 6: Documentation, Layout, Isolation, and Full Non-SVT Regression

**Files:**
- Modify: `README.md`
- Modify: `scripts/check_sv_layout.sh`

**Interfaces:**
- Consumes: all previous tasks and existing build/test runner.
- Produces: public usage documentation, recursive `.sv`/package-isolation gates, and complete non-SVT regression evidence.

- [ ] **Step 1: Document the public DMAQ contract**

Add a README DMAQ section containing:

- the exact 32-byte offset table and flags-only mutable rule;
- endpoint roles and the three accepted operation pairs;
- BDF helper bit layout and raw Switch identity;
- caller-owned address/lifetime rule and length 1..65535;
- `dmaq_env_cfg` default fields and a custom example:

```systemverilog
dmaq_env_cfg cfg = dmaq_env_cfg::type_id::create("cfg");
cfg.depth = 64;
cfg.initial_logical_seq = 5;
cfg.poll_interval = 25ns;
cfg.completion_timeout = 750ns;
if (!cfg.add_dmaq(0, hw_cfg, reason))
    `uvm_fatal("DMAQ_CFG", reason)
```

- fixed 32-byte descriptor size even under custom geometry;
- default first slot/tail 31/`16'h8000` and custom pointer formula;
- per-sequence timeout override and late-completion ownership;
- semantic adapter callbacks, Poll default, optional IRQ extension, and the no-unchanged-tail rule;
- independent command `make run TEST=dmaq_driver_conformance_test LIBS=dmaq TEST_SUITE=dmaq`.

- [ ] **Step 2: Extend recursive layout and isolation gates**

Require exactly these production files to exist with `.sv` suffix:

```text
dmaq_pkg.sv dmaq_types.sv dmaq_tx_desc.sv dmaq_completion.sv
dmaq_ptr_codec.sv dmaq_reg_adapter.sv dmaq_env.sv dmaq_sequences.sv
```

Make the gate fail if `src/dmaq` contains a `.svh`, imports another business package, or omits one required file. Preserve the existing TLPQ address-literal scanner and its tests.

- [ ] **Step 3: Run local static/build-selection checks**

Run:

```bash
make check-layout
make -n run TEST=dmaq_desc_test LIBS=dmaq TEST_SUITE=dmaq
rg -n 'import[[:space:]]+(mailbox|msgq|cmdq|tlpq|pcie)' src/dmaq && exit 1 || true
find src/dmaq -type f ! -name '*.sv' -print
git diff --check
git submodule status
```

Expected: layout and dry-run pass; dependency and non-`.sv` scans print nothing; diff check passes; submodule hashes match the Global Constraints.

- [ ] **Step 4: Run the complete DMAQ suite**

```bash
for test_name in dmaq_desc_test dmaq_sequence_test \
  dmaq_driver_conformance_test; do
  scripts/run_vcs_remote.sh "$test_name" dmaq
done
```

Expected: all three tests exit zero with pristine UVM summaries.

- [ ] **Step 5: Run all existing GQ/Mailbox tests without SVT**

```bash
for test_name in \
  gq_timing_config_test gq_wait_policy_test gq_worker_wakeup_test \
  gq_config_test gq_index_phase_ptr_codec_test mailbox_desc_test \
  mailbox_ptr_codec_test mailbox_reg_adapter_test mailbox_wrap_test \
  gq_submit_test gq_completion_test gq_async_completion_test \
  gq_refill_test gq_auto_recycle_test gq_refill_batch_test \
  gq_reset_test gq_regression_test; do
  scripts/run_vcs_remote.sh "$test_name" mailbox gq
done
```

Expected: every command exits zero with zero UVM warnings, errors, and fatals.

- [ ] **Step 6: Run all existing MSGQ/CMDQ/TLPQ tests without SVT**

```bash
for test_name in msgq_entry_test msgq_profile_test \
  msgq_completion_test msgq_driver_conformance_test; do
  scripts/run_vcs_remote.sh "$test_name" msgq
done

for test_name in cmdq_desc_test cmdq_sequence_test \
  cmdq_driver_conformance_test; do
  scripts/run_vcs_remote.sh "$test_name" cmdq
done

for test_name in tlpq_desc_test tlpq_tx_test tlpq_bridge_test \
  tlpq_driver_conformance_test; do
  scripts/run_vcs_remote.sh "$test_name" tlpq
done
```

Expected: every non-SVT business test exits zero with a pristine UVM summary; TLPQ uses pinned `pcie_work` commit `a86860d0551af62b21a8faffadc7097e8118bb07`.

- [ ] **Step 7: Commit documentation and static gates**

```bash
git add README.md scripts/check_sv_layout.sh
git commit -m "docs(dmaq): publish configurable transfer queue contract"
```

## Plan Completion Checks

- Map spec Sections 3–10 and every Section 11 verification bullet to a named task/step above; add a concrete assertion if any bullet has no owner.
- Confirm descriptor size is written as `DMAQ_DESC_BYTES==32` in Tasks 2, 3, 5, and 6 and no public `desc_size` profile field exists.
- Confirm `depth`, `initial_logical_seq`, `poll_interval`, and environment/sequence `completion_timeout` names and types are identical in Tasks 1, 3, 4, 5, and README instructions.
- Confirm the default 32/31 profile and custom 64/5 profile have independent pointer, reset, adapter, and timing assertions.
- Run `rg -n 'T[B]D|T[O]DO|implement[[:space:]]+later|fill in detai[l]s|appropriate error handlin[g]|similar to Tas[k]' docs/superpowers/plans/2026-08-28-dmaq-gq-business-library.md` and require no matches.
- Run `rg -n 'DMAQ_DEFAULT_DEPTH|DMAQ_DEFAULT_INITIAL_LOGICAL_SEQ|DMAQ_DESC_BYTES|dmaq_endpoint_t|dmaq_hw_cfg_t|dmaq_transfer_sequence|write_dmaq_tail' docs/superpowers/plans/2026-08-28-dmaq-gq-business-library.md docs/superpowers/specs/2026-08-28-dmaq-gq-business-library-design.md` and correct every spelling/type mismatch.
- Run `git diff --check`, `make check-layout`, `git submodule status`, and `git status --short` before execution handoff.
