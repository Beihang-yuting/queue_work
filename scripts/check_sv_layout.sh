#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

status=0

for command_name in find sort rg; do
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
    src/mailbox/mailbox_pkg.sv \
    tb/gq_test_pkg.sv; do
    if [[ ! -f "$required_file" ]]; then
        printf 'required package file not found: %s\n' "$required_file" >&2
        status=1
    fi
done

if ((status != 0)); then
    exit "$status"
fi

stale_files=()
if stale_files_output=$(
    find src tb/mocks tb/tests -type f -name '*.svh' -print | sort
); then
    if [[ -n "$stale_files_output" ]]; then
        mapfile -t stale_files <<< "$stale_files_output"
    fi
else
    scan_status=$?
    printf 'failed to scan for repository-owned .svh files (exit %d)\n' \
        "$scan_status" >&2
    exit "$scan_status"
fi
if ((${#stale_files[@]} != 0)); then
    printf 'repository-owned .svh files remain:\n' >&2
    printf '  %s\n' "${stale_files[@]}" >&2
    status=1
fi

all_svh_includes=()
include_pattern='`include[[:space:]]+"[^"]+\.svh"'
if all_svh_includes_output=$(
    rg -n "$include_pattern" \
        src/gq/gq_pkg.sv src/mailbox/mailbox_pkg.sv tb/gq_test_pkg.sv \
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
    rg -n "$guard_pattern" src tb/mocks tb/tests
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
