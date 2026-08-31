#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
summary_checker="$repo_root/scripts/check_uvm_summary.sh"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/gq_uvm_summary_test.XXXXXX")

cleanup() {
    local status=$?
    rm -rf -- "$fixture_dir"
    return "$status"
}
trap cleanup EXIT

clean_log="$fixture_dir/clean.log"
fatal_log="$fixture_dir/fatal.log"
error_log="$fixture_dir/error.log"
warning_log="$fixture_dir/warning.log"
missing_log="$fixture_dir/missing.log"

cat >"$clean_log" <<'EOF'
UVM_INFO @ 0: reporter [RNTST] Running test clean_test...
Number of caught UVM_FATAL reports   :    1
Number of caught UVM_ERROR reports   :    2
Number of caught UVM_WARNING reports :    3
--- UVM Report Summary ---

** Report counts by severity
UVM_INFO :    5
UVM_WARNING :    0
UVM_ERROR :    0
UVM_FATAL :    0
** Report counts by id
EOF

cat >"$fatal_log" <<'EOF'
--- UVM Report Summary ---
** Report counts by severity
UVM_INFO :    1
UVM_WARNING :    0
UVM_ERROR :    0
UVM_FATAL :    0
** Report counts by id
UVM_INFO @ 1: reporter [CAUGHT] UVM_FATAL : 0
--- UVM Report Summary ---
** Report counts by severity
UVM_INFO :    2
UVM_WARNING :    0
UVM_ERROR :    0
UVM_FATAL :    1
** Report counts by id
EOF

cat >"$error_log" <<'EOF'
--- UVM Report Summary ---
** Report counts by severity
UVM_INFO :    2
UVM_WARNING :    0
UVM_ERROR :    2
UVM_FATAL :    0
** Report counts by id
EOF

cat >"$warning_log" <<'EOF'
--- UVM Report Summary ---
** Report counts by severity
UVM_INFO :    2
UVM_WARNING :    1
UVM_ERROR :    0
UVM_FATAL :    0
** Report counts by id
EOF

cat >"$missing_log" <<'EOF'
UVM_INFO @ 0: reporter [RNTST] Running test incomplete_test...
Number of caught UVM_FATAL reports   :    0
UVM_INFO @ 1: reporter [CAUGHT] UVM_ERROR : 0 UVM_FATAL : 0
EOF

# Reproduce the old wrapper contract: a command that prints a fatal summary
# but returns zero is accepted when only its process status is considered.
set +e
bash -c 'printf "%s\n" "$(cat "$1")"; exit 0' _ "$fatal_log" \
    >"$fixture_dir/legacy-output.log"
legacy_status=$?
set -e
if ((legacy_status != 0)); then
    printf 'legacy false-green reproduction returned %d, expected 0\n' \
        "$legacy_status" >&2
    exit 1
fi
printf 'reproduced legacy false-green: fatal summary with command status 0\n'

expect_status() {
    local expected=$1
    local case_name=$2
    local log_file=$3
    local actual

    set +e
    bash "$summary_checker" "$log_file" \
        >"$fixture_dir/$case_name.output" 2>&1
    actual=$?
    set -e
    if ((actual != expected)); then
        printf '%s fixture returned %d, expected %d\n' \
            "$case_name" "$actual" "$expected" >&2
        sed -n '1,120p' "$fixture_dir/$case_name.output" >&2
        return 1
    fi
}

expect_status 0 clean "$clean_log"
expect_status 1 fatal "$fatal_log"
expect_status 1 error "$error_log"
expect_status 1 warning "$warning_log"
expect_status 1 missing "$missing_log"

printf 'UVM summary validation fixtures passed\n'
