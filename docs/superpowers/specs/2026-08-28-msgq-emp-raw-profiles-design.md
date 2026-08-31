# EMP-Proven MSGQ Raw Profiles

**Date:** 2026-08-28
**Status:** Approved in design discussion; pending review of this written specification

## 1. Purpose

Extend the existing MSGQ business library with standard raw profiles for the
queue geometries and configuration metadata proven by the EMP firmware. FSE,
IACL, EACL, and vDPA gain convenient, validated configuration paths without
inventing payload fields. Notify remains on the existing user-defined raw path
because the archive contains notify registers but no complete notify queue
consumer.

This is a separate deliverable from DMAQ and is planned and verified only after
the DMAQ business library is complete.

## 2. Reference Sources

The design is based on EMP archive
`/home/ubuntu/Downloads/emp.zip` on `10.11.10.53`, SHA-256
`dbc70200efdab93a96522a5115c9b81059b01fc512d587026b9b69b9db130cae`.
Relevant files are:

- `emp/app/dpu/mailbox.c` and `mailbox.h` for the configuration request;
- `emp/app/dpu/af_mng.c` for FSE/IACL/EACL queue selection;
- `emp/app/dpu/ptp.c` for the active 1588 queue consumer;
- `emp/app/dpu/register.h` for queue-control geometry; and
- the current Linux DPU driver reference for the already implemented MAC-age
  payload profile.

EMP programs `msg_bnum_bwid=6` for FSE/IACL/EACL and 3 for vDPA, establishing
64-byte and 8-byte entries respectively. The register structures expose base,
depth, current/tail, mode, HID, FID, MSI-X, and sequence-ID-base fields. The
flow/vDPA mailbox handlers do not populate MSI-X, so this design carries MSI-X
only as optional adapter metadata for the already supported IRQ integration;
it does not claim that EMP actively configures it. EMP does not define a
complete software payload parser for these four raw profiles.

## 3. Scope

### 3.1 In scope

- Standard raw profile helpers for FSE, IACL, EACL, and vDPA.
- Fixed entry sizes: 64 bytes for FSE/IACL/EACL and 8 bytes for vDPA.
- Caller-selected nonzero power-of-two depth.
- A built-in raw-entry factory with no field-level interpretation.
- Queue metadata for mode, HID, FID, MSI-X, and sequence-ID base.
- Per-queue metadata isolation in multi-queue environments.
- Backward-compatible adapter dispatch for existing MSGQ subclasses.
- Existing current-pointer completion, IRQ/Poll/watchdog, and auto-recycle
  behavior.
- Remote VCS conformance and regression.

### 3.2 Out of scope

- Guessing payload fields for FSE, IACL, EACL, or vDPA.
- A standard notify queue geometry or parser.
- Hard-coded register addresses or automatic resource-manager policy.
- Changing MAC-age or 1588 payload parsing.
- Treating queue depth as fixed where EMP obtains it from the mailbox request.

## 4. Standard Raw Geometry

The standard helpers enforce:

| Kind | Entry size | Depth | Payload contract |
| --- | ---: | --- | --- |
| `MSGQ_FSE` | 64 bytes | caller power of two | raw bytes |
| `MSGQ_IACL` | 64 bytes | caller power of two | raw bytes |
| `MSGQ_EACL` | 64 bytes | caller power of two | raw bytes |
| `MSGQ_VDPA` | 8 bytes | caller power of two | raw bytes |

Depth must be at least two because MSGQ keeps one sentinel slot and initially
posts `depth-1` entries. The entry-size logarithm is derived from kind, never
accepted as caller policy in the standard helper.

`MSGQ_NOTIFY` continues to require the existing explicit raw depth, entry size,
and factory. Existing custom raw construction remains available for nonstandard
hardware revisions.

## 5. Built-In Raw Factory

`msgq_raw_entry_factory` derives from `msgq_entry_factory` and creates
`msgq_raw_entry` objects of the requested fixed size. Each object:

- packs to zero-filled bytes for initial ring clearing;
- accepts exactly one fixed-size raw completion snapshot;
- preserves the raw bytes for synchronous analysis callbacks;
- owns no separate allocation; and
- assigns no semantic fields to the payload.

Callers may supply a custom factory through the existing generic API when they
have an external payload definition. The standard EMP helper uses the built-in
factory so raw profiles do not require boilerplate.

## 6. Hardware Metadata and Adapter Compatibility

`msgq_hw_cfg_t` carries unsigned integer fields for queue mode, HID, FID, and
MSI-X index, plus a one-bit MSI-X-valid flag and a `gq_addr_t` sequence-ID base.
Using integer inputs allows validation before a concrete adapter narrows them
to the hardware widths:

- 3-bit queue mode;
- 3-bit queue HID;
- 10-bit queue FID;
- 16-bit MSI-X index and valid bit; and
- 64-bit sequence-ID base.

`msg_bnum_bwid` is derived from kind: 6 for FSE/IACL/EACL and 3 for vDPA.
Base address, depth, entry size, and initial tail remain generic queue
arguments. A concrete adapter maps these semantic values to its RAL, PCIe,
MMIO, or backdoor implementation.

Metadata is registered by queue ID before environment ownership transfer and
is immutable after successful addition. Duplicate IDs or inconsistent kind
metadata are rejected without modifying an existing queue.

To preserve existing adapter subclasses, `msgq_reg_adapter` retains the current
`configure_msgq_registers(queue_id,base,depth,entry_size)` callback and adds a
virtual EMP-profile callback that receives kind and `msgq_hw_cfg_t`. Its base
implementation delegates to the legacy callback. An EMP-aware adapter may
override the new callback; an existing adapter continues to compile and uses
its prior behavior.

## 7. Environment API

`msgq_env_cfg` adds a standard helper conceptually equivalent to:

```systemverilog
function bit add_emp_raw_msgq(
    int unsigned queue_id,
    msgq_kind_e kind,
    int unsigned depth,
    msgq_hw_cfg_t hw_cfg,
    output string reason);
```

The helper accepts only FSE, IACL, EACL, and vDPA. It derives entry size,
installs the built-in raw factory, creates the existing current-pointer
completion source and shared pointer codec, registers hardware metadata, and
uses the established standard timing:

- IRQ mode with adaptive Poll support;
- 50 ns minimum, 500 ns maximum, backoff factor 2;
- 1 us lost-IRQ watchdog;
- completion timeout zero for an indefinitely idle event queue; and
- `GQ_RX_AUTO_RECYCLE` with a `depth-1` outstanding window.

Initialization clears fixed ring slots and publishes initial tail `depth-1`
once. Normal completion advances the logical window through the hardware
current pointer and performs no descriptor rewrite or refill publication.

## 8. Error Handling

The helper rejects:

- MAC-age, 1588, notify, or an unknown kind;
- depth below two or a non-power-of-two depth;
- metadata outside its declared field widths;
- a duplicate queue ID;
- a non-MSGQ adapter; or
- failure to create or validate any strategy/profile object.

Raw payload bytes are never rejected for field content. Only exact byte count
is enforced. Current-pointer samples retain the existing `valid/count`
protocol checks, reset epochs, cleanup cancellation, and no-leak guarantees.

## 9. Verification

Directed tests require:

- exact derived entry size and `msg_bnum_bwid` for all four kinds;
- built-in raw factory creation, zero initial bytes, exact raw snapshot, and
  wrong-size rejection;
- independent per-queue kind and metadata mapping;
- legacy adapter fallback and EMP-aware callback traces;
- invalid kind/depth/metadata/duplicate rejection without partial mutation;
- initial tail `depth-1`, current-pointer wrap, Poll, IRQ, watchdog, reset,
  cleanup, and zero leaks; and
- no field-level assertion on FSE/IACL/EACL/vDPA payload content.

The MSGQ-only suite and all existing GQ, Mailbox, CMDQ, DMAQ, and TLPQ non-SVT
regressions run on `ubuntu@10.11.10.53`. Static gates enforce `.sv` file naming,
package isolation, valid build selection, and clean diffs.

## 10. Acceptance Criteria

The extension is complete when:

1. FSE/IACL/EACL use validated 64-byte raw entries;
2. vDPA uses validated 8-byte raw entries;
3. standard callers no longer need to provide a raw factory;
4. semantic EMP metadata reaches an adapter without hard-coded addresses;
5. existing MSGQ adapters and MAC-age/1588 profiles remain compatible;
6. notify remains explicitly user-defined; and
7. all directed and compatibility gates finish with zero unexpected UVM
   warnings, errors, or fatals.
