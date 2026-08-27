# TLPQ PCIe and Generic Queue Business Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an independent `tlpq` package with Host/Switch RX rings on GQ, PCIe TLP objects/codecs from pinned `pcie_work`, exact DPU buffer translation, and the separate register-driven TX path.

**Architecture:** Two independent GQ RX engines own depth-32 descriptor rings and one-at-a-time explicit refill. `tlpq_packet_bridge` is the only DPU-layout translator and delegates standard PCIe header encode/decode to `pcie_tl_codec`; TX is a semantic register adapter outside the GQ ring.

**Tech Stack:** SystemVerilog, UVM 1.2, GQ, `host_mem`, `pcie_work` `main@94930e1d69e7a059cd794eb08c5b2e97aa93dc27`, VCS, GNU Make, EMP `tlp.c/tlp.h` from archive SHA-256 `dbc70200...130cae`.

**Spec:** `docs/superpowers/specs/2026-08-27-msgq-cmdq-tlpq-gq-reuse-design.md`

## Global Constraints

- Complete the GQ extensible-completion plan before Task 1 and start from a clean worktree.
- All repository-owned SystemVerilog files use `.sv`; do not add `.svh` files and do not rename or copy files owned by `pcie_work`.
- Add `pcie_work` as a submodule at the exact pinned commit; do not duplicate its TLP transaction classes or standard codec.
- Compile only `pcie_tl_vip` helper packages, interface, and `pcie_tl_pkg`; exclude `svt_pcie_integration`.
- `tlpq_pkg` may depend on `gq_pkg`, `host_mem_pkg`, and `pcie_tl_pkg`, but not mailbox, MSGQ, or CMDQ.
- Host RX and Switch RX are independent depth-32, 16-byte-descriptor, 128-byte-buffer GQ engines with 31 initial entries and explicit refill batch one.
- Default detection is IRQ with 50 ns minimum, 500 ns maximum, 1 us watchdog, and disabled final RX timeout; fixed/adaptive Poll remains selectable.
- Register addresses and bus access stay in user-derived RX/TX adapters.
- Every golden vector uses independently written expected DPU DWORDs; an encode/decode round trip alone is not sufficient evidence.
- Run all simulations on `ubuntu@10.11.10.53` through a bash login shell.

---

## File Map

```text
.gitmodules                              pcie_work association
pcie_work/                               pinned submodule gitlink
src/tlpq/tlpq_pkg.sv                     public package
src/tlpq/tlpq_types.sv                   channel/constants/metadata
src/tlpq/tlpq_rx_desc.sv                 exact RX descriptor and buffer
src/tlpq/tlpq_completion.sv              writeback specialization
src/tlpq/tlpq_refill_profile.sv          31-entry/batch-one creation
src/tlpq/tlpq_ptr_codec.sv               bit-15 phase pointer
src/tlpq/tlpq_packet_bridge.sv            DPU layout <-> pcie codec
src/tlpq/tlpq_reg_adapter.sv              Host/Switch RX semantic adapter
src/tlpq/tlpq_tx_reg_adapter.sv           ready/data/keep/TUSER/SOP/EOP TX
src/tlpq/tlpq_env.sv                      two independent queue profiles
src/tlpq/tlpq_sequences.sv                RX start and TX send sequences
tb/tlpq_test_pkg.sv                       TLPQ-only test package
tb/mocks/tlpq_mock_adapter.sv             per-channel RX traces/IRQs
tb/mocks/tlpq_mock_dut.sv                 descriptor DMA completion
tb/mocks/tlpq_mock_tx_adapter.sv          TX register trace/ready behavior
tb/tests/tlpq_bridge_test.sv               independent golden vectors
tb/tests/tlpq_desc_test.sv                 descriptor layout/parse errors
tb/tests/tlpq_tx_test.sv                   chunk/keep/control behavior
tb/tests/tlpq_driver_conformance_test.sv   dual-ring setup/refill/wrap/races
```

### Task 1: Pin `pcie_work` and Compile the Required PCIe Package

**Files:**
- Modify: `.gitmodules`
- Add: `pcie_work/` gitlink
- Create: `src/tlpq/tlpq_pkg.sv`
- Create: `tb/tlpq_test_pkg.sv`
- Modify: `Makefile`
- Modify: `scripts/run_vcs_remote.sh`
- Modify: `tb/tb_top.sv`

**Interfaces:**
- Consumes: existing `host_mem` submodule and selectable-library Make wiring.
- Produces: `pcie_tl_pkg::pcie_tl_tlp` and `pcie_tl_pkg::pcie_tl_codec` before `tlpq_pkg` compilation.

- [ ] **Step 1: Register and pin the associated project**

Run:

```bash
git submodule add -b main https://github.com/Beihang-yuting/pcie_work.git pcie_work
git -C pcie_work checkout 94930e1d69e7a059cd794eb08c5b2e97aa93dc27
git submodule status pcie_work
```

Expected: output begins with a blank/space status marker followed by `94930e1d69e7a059cd794eb08c5b2e97aa93dc27`; `.gitmodules` records URL and branch `main` without credentials.

- [ ] **Step 2: Write a failing PCIe codec smoke compilation**

Create this minimal `src/tlpq/tlpq_pkg.sv`:

```systemverilog
`ifndef TLPQ_PKG_SV
`define TLPQ_PKG_SV
package tlpq_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import pcie_tl_pkg::*;
    import gq_pkg::*;
    `include "uvm_macros.svh"
endpackage
`endif
```

Then add a complete smoke test to `tb/tlpq_test_pkg.sv`:

```systemverilog
class tlpq_pcie_smoke_test extends uvm_test;
    `uvm_component_utils(tlpq_pcie_smoke_test)
    function new(string name = "tlpq_pcie_smoke_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction
    task run_phase(uvm_phase phase);
        pcie_tl_codec codec;
        pcie_tl_mem_tlp request;
        pcie_tl_tlp decoded;
        bit [7:0] encoded[];
        codec = pcie_tl_codec::type_id::create("codec");
        request = pcie_tl_mem_tlp::type_id::create("request");
        request.kind = TLP_MEM_RD;
        request.fmt = FMT_3DW_NO_DATA;
        request.type_f = TLP_TYPE_MEM_RD;
        request.length = 1;
        request.requester_id = 16'h0100;
        request.tag = 10'h012;
        request.addr = 64'h0000_0000_1000_0000;
        request.first_be = 4'hf;
        request.last_be = 0;
        request.is_64bit = 0;
        codec.encode(request, encoded);
        decoded = codec.decode(encoded);
        if (encoded.size() != 12 || decoded == null)
            `uvm_error("TLPQ_PCIE", "codec smoke failed")
    endtask
endclass
```

Before adding PCIe sources to Make, run `scripts/run_vcs_remote.sh tlpq_pcie_smoke_test tlpq`; expected failure is missing `pcie_tl_pkg`.

- [ ] **Step 3: Add exact PCIe compile order and include paths**

When `tlpq` is present in `LIB_LIST`, add:

```make
PCIE_ROOT := pcie_work/pcie_tl_vip
PCIE_INCDIRS := +incdir+$(PCIE_ROOT)/src \
  +incdir+$(PCIE_ROOT)/src/types +incdir+$(PCIE_ROOT)/src/shared \
  +incdir+$(PCIE_ROOT)/src/agent +incdir+$(PCIE_ROOT)/src/env \
  +incdir+$(PCIE_ROOT)/src/adapter +incdir+$(PCIE_ROOT)/src/switch \
  +incdir+$(PCIE_ROOT)/src/seq/base \
  +incdir+$(PCIE_ROOT)/src/seq/constraints \
  +incdir+$(PCIE_ROOT)/src/seq/scenario \
  +incdir+$(PCIE_ROOT)/src/seq/virtual
PCIE_SOURCES := $(PCIE_ROOT)/src/pcie_tl_if.sv \
  $(PCIE_ROOT)/src/shared/pcie_tl_bdf_utils_pkg.sv \
  $(PCIE_ROOT)/src/shared/pcie_tl_device_profile_pkg.sv \
  $(PCIE_ROOT)/src/pcie_tl_pkg.sv
```

Place `$(PCIE_SOURCES)` after `host_mem_pkg.sv` and before `gq_pkg.sv`; add `$(PCIE_INCDIRS)`. Do not compile any `pcie_work` tests or SVT sources. Before rsync, the remote script requires `pcie_work/pcie_tl_vip/src/pcie_tl_pkg.sv` to exist; its existing recursive rsync then copies the initialized submodule contents into the non-Git remote temporary tree.

- [ ] **Step 4: Add the minimal TLPQ test package/build selector and run smoke**

Use `tb/tlpq_test_pkg.sv` importing UVM, host memory, PCIe TL, GQ, and the minimal TLPQ package created in Step 2. Append:

```make
LIB_SOURCE_tlpq := src/tlpq/tlpq_pkg.sv
TEST_PACKAGE_tlpq := tb/tlpq_test_pkg.sv
TEST_DEFINE_tlpq := +define+QUEUE_TEST_TLPQ
```

Add the matching `tb_top.sv` conditional import, then run:

```bash
scripts/run_vcs_remote.sh tlpq_pcie_smoke_test tlpq
```

Expected: the codec constructs and VCS exits zero.

- [ ] **Step 5: Commit only the pinned dependency and build support**

```bash
git add .gitmodules pcie_work Makefile scripts/run_vcs_remote.sh \
  src/tlpq/tlpq_pkg.sv tb/tlpq_test_pkg.sv tb/tb_top.sv
git commit -m "build(tlpq): pin pcie transaction layer dependency"
```

### Task 2: TLPQ Types, Pointer, Completion, and Exact RX Descriptor

**Files:**
- Modify: `src/tlpq/tlpq_pkg.sv`
- Create: `src/tlpq/tlpq_types.sv`
- Create: `src/tlpq/tlpq_rx_desc.sv`
- Create: `src/tlpq/tlpq_completion.sv`
- Create: `src/tlpq/tlpq_ptr_codec.sv`
- Create: `tb/tests/tlpq_desc_test.sv`
- Modify: `tb/tlpq_test_pkg.sv`

**Interfaces:**
- Consumes: GQ descriptor ownership/writeback/pointer strategies and `pcie_tl_tlp` handle type.
- Produces: exact 16-byte RX descriptor with copied bytes, routing metadata, and decoded TLP slot.

- [ ] **Step 1: Write failing layout and ownership tests**

Require public constants/types:

```systemverilog
localparam int unsigned TLPQ_DEPTH = 32;
localparam int unsigned TLPQ_DESC_BYTES = 16;
localparam int unsigned TLPQ_BUFFER_BYTES = 128;
typedef enum bit { TLPQ_HOST, TLPQ_SWITCH } tlpq_channel_e;
```

Attach memory, prepare a descriptor, mark available, and require exact offsets:

```text
0x00 flags       u16 = AVAIL
0x02 buf_len     u16 = 128 before hardware completion
0x04 buf_addr    u64
0x0c host_id     bits 3:0; type bits 7:4; primary_bus bits 15:8
0x0e secondary_bus u8
0x0f subordinate_bus u8
```

Require one distinct 128-byte owned allocation per descriptor and a 16-byte pack.

- [ ] **Step 2: Add failing writeback/stability cases**

Allow hardware to change flags, completed length, host/type, and all three bus fields. Reject buffer-address changes and require missing `USED` to remain incomplete. Length validation and decoded-object assertions enter with the bridge connection in Task 4.

- [ ] **Step 3: Run descriptor tests and verify types are absent**

```bash
scripts/run_vcs_remote.sh tlpq_desc_test tlpq
```

Expected: unresolved TLPQ descriptor/strategy types.

- [ ] **Step 4: Add exact types and descriptor mechanics**

Define `TLPQ_DESC_AVAIL=16'h0001`, `TLPQ_DESC_USED=16'h0002`, queue IDs 0/1 for Host/Switch defaults, and:

```systemverilog
typedef struct packed {
    bit [3:0] host_id;
    bit [3:0] tlp_type;
    bit [7:0] primary_bus;
    bit [7:0] secondary_bus;
    bit [7:0] subordinate_bus;
} tlpq_route_metadata_t;
```

`tlpq_rx_desc` allocates and clears a 128-byte buffer, snapshots only the buffer address as stable, and permits hardware length/metadata changes. It stores copied `bit[7:0] dpu_bytes[]` and a `pcie_tl_tlp decoded_tlp`; Task 4 connects parsing to the bridge.

- [ ] **Step 5: Add public generic-strategy subclasses**

`tlpq_completion` extends `gq_desc_writeback_completion`. `tlpq_ptr_codec` extends `gq_index_phase_ptr_codec` with index width 15 and phase bit 15. Require pointer vectors 31=`16'h001f`, 32=`16'h8000`, and 64=`16'h0000`.

- [ ] **Step 6: Run descriptor, allocation, and pointer tests**

```bash
scripts/run_vcs_remote.sh tlpq_desc_test tlpq
```

Expected: layout, mutable/stable field, allocation, writeback, and pointer tests pass.

- [ ] **Step 7: Commit RX descriptor mechanics**

```bash
git add src/tlpq/tlpq_pkg.sv src/tlpq/tlpq_types.sv \
  src/tlpq/tlpq_rx_desc.sv src/tlpq/tlpq_completion.sv \
  src/tlpq/tlpq_ptr_codec.sv tb/tests/tlpq_desc_test.sv tb/tlpq_test_pkg.sv
git commit -m "feat(tlpq): add exact receive descriptor and strategies"
```

### Task 3: Independent Golden Vectors for the DPU Packet Bridge

**Files:**
- Create: `src/tlpq/tlpq_packet_bridge.sv`
- Create: `tb/tests/tlpq_bridge_test.sv`
- Modify: `src/tlpq/tlpq_pkg.sv`
- Modify: `tb/tlpq_test_pkg.sv`

**Interfaces:**
- Consumes: `pcie_tl_codec.encode(pcie_tl_tlp, output bit[7:0] bytes[])` and `decode(bit[7:0] bytes[])`.
- Produces: validated DPU-layout conversion without a local PCIe parser/class.

- [ ] **Step 1: Write independent 3DW and 4DW golden vectors**

For every test, explicitly construct the TLP object, call the PCIe codec once for its canonical bytes, and compare against a literal expected DPU DWORD array written in the test. Cover nine packets: Configuration Read/Write Type 0, Configuration Read/Write Type 1, Memory Read/Write, Message with Data, Completion, and Completion with Data.

At minimum require these layout relationships independently of round trip:

```text
3DW: DPU DW[0]=padding, DW[1]=canonical DW2,
     DW[2]=canonical DW1, DW[3]=canonical DW0.
4DW: DPU DW[0]=canonical DW3, DW[1]=canonical DW2,
     DW[2]=canonical DW1, DW[3]=canonical DW0.
payload DWORDs follow the four-DWORD DPU header contiguously.
```

Literal expected words account for the required per-DWORD byte ordering; do not compute expected words by calling bridge helpers.

- [ ] **Step 2: Add failing malformed-layout cases**

Reject DPU length below 16, non-DWORD-aligned byte count, header-declared data exceeding supplied bytes, a 3DW padding word that violates the selected strict policy, and codec output/null decode inconsistencies. Require an explanatory nonempty `reason` for each rejection.

- [ ] **Step 3: Run bridge tests and verify the bridge is absent**

```bash
scripts/run_vcs_remote.sh tlpq_bridge_test tlpq
```

Expected: VCS reports undefined `tlpq_packet_bridge`.

- [ ] **Step 4: Implement validated conversion methods**

Expose exactly:

```systemverilog
function bit codec_bytes_to_dpu(
    input bit [7:0] codec_bytes[],
    output bit [31:0] dpu_dwords[], output string reason);
function bit dpu_bytes_to_codec(
    input bit [7:0] dpu_bytes[],
    output bit [7:0] codec_bytes[], output string reason);
function bit encode_tlp(
    input pcie_tl_tlp tlp,
    output bit [31:0] dpu_dwords[], output string reason);
function bit decode_tlp(
    input bit [7:0] dpu_bytes[],
    output pcie_tl_tlp tlp, output string reason);
```

Use `pcie_tl_codec` only after validating array bounds. Determine 3DW/4DW from canonical Fmt, reverse only the header DWORD positions described above, preserve payload order, and explicitly convert bytes within every DWORD. `encode_tlp`/`decode_tlp` delegate the standard header work to the pinned codec.

- [ ] **Step 5: Run all golden and malformed vectors**

```bash
scripts/run_vcs_remote.sh tlpq_bridge_test tlpq
```

Expected: all nine literal arrays and all malformed reasons pass; a deliberate one-bit corruption in a literal expected DWORD makes the test fail.

- [ ] **Step 6: Commit the bridge and golden evidence**

```bash
git add src/tlpq/tlpq_packet_bridge.sv src/tlpq/tlpq_pkg.sv \
  tb/tests/tlpq_bridge_test.sv tb/tlpq_test_pkg.sv
git commit -m "feat(tlpq): bridge dpu buffers to pcie tlp codec"
```

### Task 4: Connect RX Descriptor Parsing and Batch-One Refill

**Files:**
- Create: `src/tlpq/tlpq_refill_profile.sv`
- Modify: `src/tlpq/tlpq_rx_desc.sv`
- Modify: `src/tlpq/tlpq_pkg.sv`
- Modify: `tb/tests/tlpq_desc_test.sv`
- Modify: `tb/tlpq_test_pkg.sv`

**Interfaces:**
- Consumes: Task 3 bridge and GQ bounded explicit refill.
- Produces: decoded descriptor completions and standard depth-minus-one RX profile.

- [ ] **Step 1: Enable failing descriptor-to-TLP assertions**

Write one independent DPU golden vector into the descriptor-owned buffer, update flags/length/metadata in the ring descriptor, and require `parse_completion()` to copy exact bytes, invoke the bridge, return the correct derived `pcie_tl_tlp`, and preserve routing metadata. Add malformed header and changed-buffer-address cases; neither may yield a decoded object.

- [ ] **Step 2: Add failing refill-profile defaults**

Require:

```systemverilog
profile.initial_post_count == 31
profile.low_watermark == 30
profile.high_watermark == 31
profile.max_refill_batch == 1
profile.restart_after_reset == 1
```

Require every `create_desc(queue_id,seq)` to return a fresh `tlpq_rx_desc` with a distinct owned buffer after GQ prepares it.

- [ ] **Step 3: Run descriptor test and observe missing bridge/refill integration**

```bash
scripts/run_vcs_remote.sh tlpq_desc_test tlpq
```

Expected: decoded object and refill profile assertions fail.

- [ ] **Step 4: Connect parse and add refill profile**

`tlpq_rx_desc.parse_completion()` reads only completed `buf_len` bytes, calls `tlpq_packet_bridge.decode_tlp`, stores the returned TLP, and returns false on any length/layout/codec failure. `tlpq_refill_profile` creates descriptors, uses the exact defaults above, and leaves explicit refill selected in queue configuration.

- [ ] **Step 5: Run descriptor/refill and bridge regression**

```bash
scripts/run_vcs_remote.sh tlpq_desc_test tlpq
scripts/run_vcs_remote.sh tlpq_bridge_test tlpq
```

Expected: valid decoding and every malformed/stable-field case pass; each created descriptor owns one buffer.

- [ ] **Step 6: Commit descriptor decode and refill profile**

```bash
git add src/tlpq/tlpq_refill_profile.sv src/tlpq/tlpq_rx_desc.sv \
  src/tlpq/tlpq_pkg.sv tb/tests/tlpq_desc_test.sv tb/tlpq_test_pkg.sv
git commit -m "feat(tlpq): decode receive completions and refill singly"
```

### Task 5: Host/Switch RX Semantic Adapter and Independent Environments

**Files:**
- Create: `src/tlpq/tlpq_reg_adapter.sv`
- Create: `src/tlpq/tlpq_env.sv`
- Create: `src/tlpq/tlpq_sequences.sv`
- Create: `tb/mocks/tlpq_mock_adapter.sv`
- Create: `tb/tests/tlpq_driver_conformance_test.sv`
- Modify: `src/tlpq/tlpq_pkg.sv`
- Modify: `tb/tlpq_test_pkg.sv`

**Interfaces:**
- Consumes: TLPQ descriptor/strategies/profile and GQ environment.
- Produces: independent Host/Switch configuration, IRQ, pointer, and RX-start APIs.

- [ ] **Step 1: Write failing semantic adapter trace tests**

Define per-channel expected setup:

```text
RESET(channel)
CONFIGURE(channel,base,depth=32,size=16,host_id,bdf,msix)
PUBLISH(channel,tail=31)
ENABLE(channel)
```

Require Host and Switch calls to have separate trace arrays, IRQ events, publish histories, and configuration metadata. No method argument or recorded event may contain a register address.

- [ ] **Step 2: Write failing standard environment assertions**

Add both channels to one `tlpq_env_cfg` and require two RX queue configs, distinct queue IDs, independent strategy objects, depth 32, size 16, explicit refill, max batch one, IRQ default, 50/500 ns Poll bounds, 1 us watchdog, and timeout zero. Reject duplicate channels, duplicate IDs, and a non-TLPQ adapter.

- [ ] **Step 3: Run the conformance test and verify adapter/env types are missing**

```bash
scripts/run_vcs_remote.sh tlpq_driver_conformance_test tlpq
```

Expected: unresolved `tlpq_reg_adapter` and `tlpq_env_cfg`.

- [ ] **Step 4: Define RX hardware metadata and semantic adapter**

Add:

```systemverilog
typedef struct packed {
    bit [2:0] host_id;
    bit [15:0] bdf;
    bit [12:0] msix_index;
    bit msix_valid;
} tlpq_rx_hw_cfg_t;
```

`tlpq_reg_adapter` extends `gq_hw_adapter`, maps queue IDs to channel/config, and declares:

```systemverilog
pure virtual task reset_tlpq_rx(tlpq_channel_e channel);
pure virtual task configure_tlpq_rx(
    tlpq_channel_e channel, gq_addr_t base, int unsigned depth,
    int unsigned desc_size, tlpq_rx_hw_cfg_t hw_cfg);
pure virtual task enable_tlpq_rx(tlpq_channel_e channel);
pure virtual task disable_tlpq_rx(tlpq_channel_e channel);
pure virtual task write_tlpq_rx_tail(
    tlpq_channel_e channel, bit [15:0] tail);
pure virtual task wait_tlpq_rx_irq(tlpq_channel_e channel);
pure virtual task ack_tlpq_rx_irq(tlpq_channel_e channel);
```

Generic callbacks require RX role, resolve queue ID to one channel, reject upper raw-tail bits, and preserve independent cancellation/IRQ state.

- [ ] **Step 5: Define environment and sequences**

`tlpq_env_cfg extends gq_env_cfg` and exposes:

```systemverilog
function bit add_tlpq_rx(
    tlpq_channel_e channel, int unsigned queue_id,
    tlpq_rx_hw_cfg_t hw_cfg, output string reason);
```

It builds exact standard GQ defaults and a fresh refill profile. `tlpq_rx_start_sequence` starts one selected queue; `tlpq_dual_rx_start_sequence` starts Host and Switch sequentially and reports each GQ response without sharing descriptors.

- [ ] **Step 6: Run setup/default/isolation tests**

```bash
scripts/run_vcs_remote.sh tlpq_driver_conformance_test tlpq
```

Expected: both traces and configurations pass with no cross-channel events.

- [ ] **Step 7: Commit independent RX adapters/environments**

```bash
git add src/tlpq/tlpq_reg_adapter.sv src/tlpq/tlpq_env.sv \
  src/tlpq/tlpq_sequences.sv src/tlpq/tlpq_pkg.sv \
  tb/mocks/tlpq_mock_adapter.sv tb/tests/tlpq_driver_conformance_test.sv \
  tb/tlpq_test_pkg.sv
git commit -m "feat(tlpq): configure independent host and switch receive queues"
```

### Task 6: Register-Driven TLP TX Channel

**Files:**
- Create: `src/tlpq/tlpq_tx_reg_adapter.sv`
- Create: `tb/mocks/tlpq_mock_tx_adapter.sv`
- Create: `tb/tests/tlpq_tx_test.sv`
- Modify: `src/tlpq/tlpq_sequences.sv`
- Modify: `src/tlpq/tlpq_pkg.sv`
- Modify: `tb/tlpq_test_pkg.sv`

**Interfaces:**
- Consumes: Task 3 `encode_tlp()` and `pcie_tl_tlp`.
- Produces: bounded ready wait and consecutive 16-DWORD register chunks outside GQ.

- [ ] **Step 1: Write failing single- and multi-chunk traces**

For a packet of 12 DWORDs require one chunk with keep `16'h0fff`, SOP=1, EOP=1, valid=1, and selected Host ID. For 20 DWORDs require two chunks: first words `[0:15]`, keep `16'hffff`, SOP=1/EOP=0; second words `[16:19]`, keep `16'h000f`, SOP=0/EOP=1. Require contiguous word indices so the reference C pointer skip is not reproduced.

- [ ] **Step 2: Add failing channel, ready, and encode errors**

Run the same trace for Host and Switch and require isolated registers/events. Hold ready low until 70 ns and require no data writes before ready. Hold ready low through the configured timeout and require failure with zero writes. Pass a null/malformed TLP and require encode failure with zero writes.

- [ ] **Step 3: Run TX tests and verify adapter is absent**

```bash
scripts/run_vcs_remote.sh tlpq_tx_test tlpq
```

Expected: unresolved `tlpq_tx_reg_adapter`.

- [ ] **Step 4: Define transport callbacks and send task**

Declare:

```systemverilog
pure virtual task wait_tlpq_tx_ready(
    tlpq_channel_e channel, time timeout, output bit ready);
pure virtual task write_tlpq_tx_data(
    tlpq_channel_e channel, int unsigned word_index, bit [31:0] data);
pure virtual task write_tlpq_tx_keep(
    tlpq_channel_e channel, bit [15:0] keep);
pure virtual task write_tlpq_tx_tuser(
    tlpq_channel_e channel, bit [2:0] host_id);
pure virtual task write_tlpq_tx_ctrl(
    tlpq_channel_e channel, bit sop, bit eop, bit valid);
```

Add concrete base task:

```systemverilog
task send_tlp(
    tlpq_channel_e channel, bit [2:0] host_id,
    pcie_tl_tlp tlp, time ready_timeout,
    output bit success, output string reason);
```

Encode via the bridge, wait ready for every chunk, write at most 16 consecutive DWORDs starting at register word index zero per chunk, then keep/TUSER/control. Stop immediately on timeout and return a nonempty reason.

- [ ] **Step 5: Add a thin TX sequence and run traces**

`tlpq_tx_sequence` carries channel, host ID, TLP, timeout, success, and reason, and calls a configured `tlpq_tx_reg_adapter`; it does not construct a GQ request. Run:

```bash
scripts/run_vcs_remote.sh tlpq_tx_test tlpq
```

Expected: single/multi-chunk, channel isolation, delayed ready, timeout, and malformed cases pass.

- [ ] **Step 6: Commit TX register path**

```bash
git add src/tlpq/tlpq_tx_reg_adapter.sv src/tlpq/tlpq_sequences.sv \
  src/tlpq/tlpq_pkg.sv tb/mocks/tlpq_mock_tx_adapter.sv \
  tb/tests/tlpq_tx_test.sv tb/tlpq_test_pkg.sv
git commit -m "feat(tlpq): send pcie tlps through register chunks"
```

### Task 7: Full Dual-Ring Driver-Conformance Scenarios

**Files:**
- Create: `tb/mocks/tlpq_mock_dut.sv`
- Modify: `tb/tests/tlpq_driver_conformance_test.sv`
- Modify: `tb/mocks/tlpq_mock_adapter.sv`
- Modify: `tb/tlpq_test_pkg.sv`

**Interfaces:**
- Consumes: complete TLPQ RX/TX library and GQ Poll/IRQ scheduling.
- Produces: setup, completion, refill, wrap, watchdog, and race evidence against EMP behavior.

- [ ] **Step 1: Add failing initial setup and one-at-a-time refill scenario**

Start Host and Switch; require 31 descriptors and one initial tail `16'h001f` per channel. Complete three Host descriptors before one IRQ. Require three decoded callbacks and three additional Host publish events advancing one descriptor each, with no Switch publish or callback. Then complete two Switch descriptors and require the inverse isolation.

- [ ] **Step 2: Add failing independent wrap scenarios**

Advance Host across slot 31 to 0 and require Host tail `16'h8000` while Switch remains pre-wrap. Then wrap Switch separately and require its own `16'h8000`. Assert each replacement descriptor has a new 128-byte buffer and the retired buffer is freed exactly once.

- [ ] **Step 3: Add Poll/IRQ/watchdog and malformed cases**

For each channel test fixed 10 ns Poll and IRQ. Add batch completion on one IRQ, lost IRQ recovered at 1 us with no ACK, spurious IRQ with one ACK/no delivery, simultaneous Host/Switch IRQs with one ACK each, changed buffer address, zero/oversized length, malformed DPU bytes, reset during query, and cleanup during blocked ACK.

- [ ] **Step 4: Run the full RX conformance suite**

```bash
ssh ubuntu@10.11.10.53 "bash -lc '
  sha256sum /home/ubuntu/Downloads/emp.zip
'"
scripts/run_vcs_remote.sh tlpq_driver_conformance_test tlpq
```

Expected: the hash record contains `dbc70200efdab93a96522a5115c9b81059b01fc512d587026b9b69b9db130cae`; dual setup, batch-one refill, independent wrap/interrupts, detection modes, malformed handling, reset/cleanup, and ownership checks pass with zero UVM errors/fatals.

- [ ] **Step 5: Commit full RX conformance tests**

```bash
git add tb/mocks/tlpq_mock_dut.sv tb/mocks/tlpq_mock_adapter.sv \
  tb/tests/tlpq_driver_conformance_test.sv tb/tlpq_test_pkg.sv
git commit -m "test(tlpq): verify dual receive queue driver behavior"
```

### Task 8: Documentation, Isolation, and Complete Combined Regression

**Files:**
- Modify: `README.md`
- Modify: `scripts/check_sv_layout.sh`

**Interfaces:**
- Consumes: all TLPQ tasks plus installed MSGQ/CMDQ libraries when available.
- Produces: final repository acceptance gate.

- [ ] **Step 1: Document dependency, bridge, RX, and TX contracts**

Document the pinned submodule/compile order, nine golden-vector categories, 3DW/4DW DPU layout, exact descriptor table, Host/Switch independence, 31-entry/batch-one refill, IRQ/Poll defaults, and TX ready/chunk/keep/TUSER/SOP/EOP behavior. State that users implement address mapping through semantic adapters.

- [ ] **Step 2: Extend layout and dependency isolation gates**

Require all eleven planned `src/tlpq/*.sv` files and the initialized `pcie_work` gitlink. Run:

```bash
make check-layout
test "$(git -C pcie_work rev-parse HEAD)" = \
  94930e1d69e7a059cd794eb08c5b2e97aa93dc27
rg -n "0x[0-9a-fA-F]+|MSGQ|CMDQ|mailbox_pkg" src/tlpq
rg -n "class[[:space:]]+pcie_tl_tlp|class[[:space:]]+pcie_tl_codec" src/tlpq
```

Expected: layout and pin checks exit zero; both isolation/duplication scans print no matches.

- [ ] **Step 3: Run TLPQ and legacy regression**

```bash
for test_name in tlpq_pcie_smoke_test tlpq_bridge_test tlpq_desc_test \
  tlpq_tx_test tlpq_driver_conformance_test; do
  scripts/run_vcs_remote.sh "$test_name" tlpq
done
scripts/run_vcs_remote.sh gq_regression_test mailbox gq
scripts/run_vcs_remote.sh mailbox_wrap_test mailbox gq
```

Expected: every remote VCS run exits zero with zero UVM errors/fatals.

- [ ] **Step 4: Compile every business package together**

After the MSGQ and CMDQ plans are complete, run:

```bash
scripts/run_vcs_remote.sh gq_smoke_test mailbox,msgq,cmdq,tlpq gq
```

Expected: compile order is host memory, PCIe helpers/interface/package, GQ, mailbox, MSGQ, CMDQ, TLPQ, selected test package/top; VCS exits zero without cross-business dependency errors.

- [ ] **Step 5: Commit final documentation/layout gate**

```bash
git add README.md scripts/check_sv_layout.sh
git commit -m "docs(tlpq): publish pcie bridge and dual queue contracts"
```

## Plan Completion Checks

- Map spec Sections 4, 5, 9, 10, 11, 12.4-12.6 and Acceptance Criteria 2, 3, 7-10 to a task and exact assertion above.
- Run `rg -n 'T[B]D|T[O]DO|implement[[:space:]]+later|fill in detai[l]s|appropriate error handlin[g]|similar to Tas[k]' docs/superpowers/plans/2026-08-27-tlpq-pcie-gq-business-library.md` and require no matches.
- Run `rg -n "tlpq_rx_hw_cfg_t|tlpq_channel_e|decode_tlp|send_tlp|max_refill_batch|pcie_tl_tlp" docs/superpowers/plans/2026-08-27-tlpq-pcie-gq-business-library.md src/tlpq tb` and correct every spelling/type mismatch.
- Run `git diff --check`, `git submodule status`, and `git status --short` before handoff.
