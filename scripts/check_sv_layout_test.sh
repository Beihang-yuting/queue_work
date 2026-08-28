#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scanner="$repo_root/scripts/check_sv_layout.sh"
fixture_dir=$(mktemp -d /tmp/check_sv_layout_test.XXXXXX)

cleanup() {
    rm -rf -- "$fixture_dir"
}
trap cleanup EXIT

status=0

expect_reject() {
    local name=$1
    local source=$2
    local fixture="$fixture_dir/$name.sv"
    local output="$fixture_dir/$name.log"

    printf '%s\n' "$source" > "$fixture"
    "$scanner" --scan-tlpq-addresses-only "$fixture" >"$output" 2>&1
    local scanner_status=$?
    if ((scanner_status == 0)); then
        printf 'scanner falsely accepted %s\n' "$name" >&2
        status=1
    elif ((scanner_status != 1)); then
        printf 'scanner failed %s with unexpected status %d\n' \
            "$name" "$scanner_status" >&2
        status=1
    elif ! grep -Fq "$fixture:" "$output"; then
        printf 'scanner rejected %s without a source diagnostic\n' "$name" >&2
        status=1
    fi
}

expect_accept() {
    local name=$1
    local source=$2
    local fixture="$fixture_dir/$name.sv"
    local output="$fixture_dir/$name.log"

    printf '%s\n' "$source" > "$fixture"
    if ! "$scanner" --scan-tlpq-addresses-only "$fixture" >"$output" 2>&1; then
        printf 'scanner falsely rejected %s:\n' "$name" >&2
        sed 's/^/  /' "$output" >&2
        status=1
    fi
}

expect_reject semicolonless_define \
    '`define RX_CSR_ADDRESS 64'"'"'h1234_0000'

expect_reject continued_define \
    $'`define RX_CSR_ADDRESS \\\n+        64'"'"'h1234_0000'

expect_reject camel_case_identifier \
    'longint unsigned csrAddress = 64'"'"'h1234_0000;'

expect_reject existing_snake_case \
    'longint unsigned csr_address = 64'"'"'h1234_0000;'

expect_accept address_width_macro \
    '`define TLPQ_ADDR_WIDTH 64'

expect_accept comments_and_strings \
    $'module comments_and_strings;\n  string message = "csrAddress = 64'"'"'h1234_0000";\n  // `define RX_CSR_ADDRESS 64'"'"'h1234_0000\nendmodule'

exit "$status"
