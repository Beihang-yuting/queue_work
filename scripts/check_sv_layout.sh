#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

status=0

for command_name in find sort grep git; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'required command not found: %s\n' "$command_name" >&2
        status=1
    fi
done

for required_dir in src tb/mocks tb/tests; do
    if [[ ! -d "$required_dir" ]]; then
        printf 'required directory not found: %s\n' "$required_dir" >&2
        status=1
    fi
done

for required_file in \
    src/gq/gq_pkg.sv \
    src/gq/gq_desc_writeback_completion.sv \
    src/gq/gq_index_phase_ptr_codec.sv \
    src/mailbox/mailbox_pkg.sv \
    src/cmdq/cmdq_pkg.sv \
    src/cmdq/cmdq_types.sv \
    src/cmdq/cmdq_tx_desc.sv \
    src/cmdq/cmdq_completion.sv \
    src/cmdq/cmdq_ptr_codec.sv \
    src/cmdq/cmdq_reg_adapter.sv \
    src/cmdq/cmdq_env.sv \
    src/cmdq/cmdq_sequences.sv \
    src/msgq/msgq_pkg.sv \
    src/msgq/msgq_types.sv \
    src/msgq/msgq_entry_base.sv \
    src/msgq/msgq_raw_entry.sv \
    src/msgq/msgq_mac_age_entry.sv \
    src/msgq/msgq_1588_entry.sv \
    src/msgq/msgq_completion.sv \
    src/msgq/msgq_ptr_codec.sv \
    src/msgq/msgq_refill_profile.sv \
    src/msgq/msgq_reg_adapter.sv \
    src/msgq/msgq_env.sv \
    src/msgq/msgq_sequences.sv \
    src/tlpq/tlpq_pkg.sv \
    src/tlpq/tlpq_types.sv \
    src/tlpq/tlpq_packet_bridge.sv \
    src/tlpq/tlpq_rx_desc.sv \
    src/tlpq/tlpq_completion.sv \
    src/tlpq/tlpq_ptr_codec.sv \
    src/tlpq/tlpq_refill_profile.sv \
    src/tlpq/tlpq_reg_adapter.sv \
    src/tlpq/tlpq_tx_reg_adapter.sv \
    src/tlpq/tlpq_env.sv \
    src/tlpq/tlpq_sequences.sv \
    tb/gq_test_pkg.sv; do
    if [[ ! -f "$required_file" ]]; then
        printf 'required package file not found: %s\n' "$required_file" >&2
        status=1
    fi
done

required_tlpq_files=(
    src/tlpq/tlpq_completion.sv
    src/tlpq/tlpq_env.sv
    src/tlpq/tlpq_packet_bridge.sv
    src/tlpq/tlpq_pkg.sv
    src/tlpq/tlpq_ptr_codec.sv
    src/tlpq/tlpq_refill_profile.sv
    src/tlpq/tlpq_reg_adapter.sv
    src/tlpq/tlpq_rx_desc.sv
    src/tlpq/tlpq_sequences.sv
    src/tlpq/tlpq_tx_reg_adapter.sv
    src/tlpq/tlpq_types.sv
)
actual_tlpq_files=()
if [[ -d src/tlpq ]]; then
    mapfile -t actual_tlpq_files < <(
        find src/tlpq -maxdepth 1 -type f -name '*.sv' -print | sort
    )
fi
if ((${#actual_tlpq_files[@]} != ${#required_tlpq_files[@]})); then
    printf 'src/tlpq must contain exactly the %d planned .sv files\n' \
        "${#required_tlpq_files[@]}" >&2
    status=1
else
    for ((i = 0; i < ${#required_tlpq_files[@]}; i++)); do
        if [[ ${actual_tlpq_files[i]} != "${required_tlpq_files[i]}" ]]; then
            printf 'unexpected src/tlpq .sv layout: got %s, expected %s\n' \
                "${actual_tlpq_files[i]}" "${required_tlpq_files[i]}" >&2
            status=1
        fi
    done
fi

pcie_work_pin=94930e1d69e7a059cd794eb08c5b2e97aa93dc27
expected_pcie_gitlink=$'160000 94930e1d69e7a059cd794eb08c5b2e97aa93dc27 0\tpcie_work'
actual_pcie_gitlink=$(git ls-files --stage -- pcie_work)
if [[ $actual_pcie_gitlink != "$expected_pcie_gitlink" ]]; then
    printf 'pcie_work must be a gitlink pinned at %s\n' \
        "$pcie_work_pin" >&2
    status=1
fi
if ! actual_pcie_head=$(git -C pcie_work rev-parse HEAD 2>/dev/null); then
    printf 'pcie_work submodule is not initialized\n' >&2
    status=1
elif [[ $actual_pcie_head != "$pcie_work_pin" ]]; then
    printf 'initialized pcie_work HEAD is %s, expected %s\n' \
        "$actual_pcie_head" "$pcie_work_pin" >&2
    status=1
fi

if ((status != 0)); then
    exit "$status"
fi

stale_files=()
if stale_files_output=$(
    find src tb -type f \
        \( -name '*.svh' -o -name '*.v' -o -name '*.vh' \) -print | sort
); then
    if [[ -n "$stale_files_output" ]]; then
        mapfile -t stale_files <<< "$stale_files_output"
    fi
else
    scan_status=$?
    printf 'failed to scan repository-owned HDL extensions (exit %d)\n' \
        "$scan_status" >&2
    exit "$scan_status"
fi
if ((${#stale_files[@]} != 0)); then
    printf 'repository-owned HDL files must all use the .sv extension:\n' >&2
    printf '  %s\n' "${stale_files[@]}" >&2
    status=1
fi

tlpq_isolation_matches=()
tlpq_isolation_pattern='0x[0-9a-fA-F]+|MSGQ|CMDQ|mailbox_pkg'
if tlpq_isolation_output=$(
    grep -nEH "$tlpq_isolation_pattern" src/tlpq/*.sv
); then
    mapfile -t tlpq_isolation_matches <<< "$tlpq_isolation_output"
else
    scan_status=$?
    if ((scan_status != 1)); then
        printf 'failed to scan TLPQ dependency isolation (exit %d)\n' \
            "$scan_status" >&2
        exit "$scan_status"
    fi
fi
if ((${#tlpq_isolation_matches[@]} != 0)); then
    printf 'TLPQ register-address or business-library dependencies remain:\n' >&2
    printf '  %s\n' "${tlpq_isolation_matches[@]}" >&2
    status=1
fi

tlpq_codec_definitions=()
tlpq_codec_pattern='class[[:space:]]+pcie_tl_(tlp|codec)'
if tlpq_codec_output=$(
    grep -nEH "$tlpq_codec_pattern" src/tlpq/*.sv
); then
    mapfile -t tlpq_codec_definitions <<< "$tlpq_codec_output"
else
    scan_status=$?
    if ((scan_status != 1)); then
        printf 'failed to scan TLPQ PCIe codec duplication (exit %d)\n' \
            "$scan_status" >&2
        exit "$scan_status"
    fi
fi
if ((${#tlpq_codec_definitions[@]} != 0)); then
    printf 'TLPQ must use pcie_work PCIe TLP/codec classes:\n' >&2
    printf '  %s\n' "${tlpq_codec_definitions[@]}" >&2
    status=1
fi

all_svh_includes=()
include_pattern='`include[[:space:]]+"[^"]+\.svh"'
if all_svh_includes_output=$(
    find src tb -type f -name '*.sv' \
        -exec grep -nEH "$include_pattern" {} +
); then
    mapfile -t all_svh_includes <<< "$all_svh_includes_output"
else
    scan_status=$?
    if ((scan_status != 1)); then
        printf 'failed to scan for repository-owned .svh includes (exit %d)\n' \
            "$scan_status" >&2
        exit "$scan_status"
    fi
fi

stale_includes=()
uvm_include_pattern=':[0-9]+:[[:space:]]*`include[[:space:]]+"uvm_macros\.svh"[[:space:]]*$'
for include_line in "${all_svh_includes[@]}"; do
    if [[ "$include_line" =~ $uvm_include_pattern ]]; then
        continue
    fi
    stale_includes+=("$include_line")
done
if ((${#stale_includes[@]} != 0)); then
    printf 'repository-owned .svh includes remain:\n' >&2
    printf '  %s\n' "${stale_includes[@]}" >&2
    status=1
fi

stale_guards=()
guard_pattern='^[[:space:]]*`(ifndef|define)[[:space:]]+[A-Z0-9_]+_SVH[[:space:]]*$'
if stale_guards_output=$(
    find src tb -type f -name '*.sv' \
        -exec grep -nEH "$guard_pattern" {} +
); then
    mapfile -t stale_guards <<< "$stale_guards_output"
else
    scan_status=$?
    if ((scan_status != 1)); then
        printf 'failed to scan for SVH include guards (exit %d)\n' \
            "$scan_status" >&2
        exit "$scan_status"
    fi
fi
if ((${#stale_guards[@]} != 0)); then
    printf 'SVH include guards remain:\n' >&2
    printf '  %s\n' "${stale_guards[@]}" >&2
    status=1
fi

exit "$status"
