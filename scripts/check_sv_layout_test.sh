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

expect_dmaq_import_reject() {
    local name=$1
    local source=$2
    local fixture="$fixture_dir/$name.sv"
    local output="$fixture_dir/$name.log"

    printf '%s\n' "$source" > "$fixture"
    "$scanner" --scan-dmaq-imports-only "$fixture" >"$output" 2>&1
    local scanner_status=$?
    if ((scanner_status == 0)); then
        printf 'DMAQ import scanner falsely accepted %s\n' "$name" >&2
        status=1
    elif ((scanner_status != 1)); then
        printf 'DMAQ import scanner failed %s with unexpected status %d\n' \
            "$name" "$scanner_status" >&2
        status=1
    elif ! grep -Fq "$fixture:" "$output"; then
        printf 'DMAQ import scanner rejected %s without a source diagnostic\n' \
            "$name" >&2
        status=1
    fi
}

expect_dmaq_import_accept() {
    local name=$1
    local source=$2
    local fixture="$fixture_dir/$name.sv"
    local output="$fixture_dir/$name.log"

    printf '%s\n' "$source" > "$fixture"
    if ! "$scanner" --scan-dmaq-imports-only "$fixture" >"$output" 2>&1; then
        printf 'DMAQ import scanner falsely rejected %s:\n' "$name" >&2
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

expect_dmaq_import_reject compound_import \
    'import gq_pkg::*, mailbox_pkg::*;'

expect_dmaq_import_reject same_line_prefixed_import \
    'int unsigned marker = 0; import gq_pkg::*, cmdq_pkg::*;'

expect_dmaq_import_reject multiline_import \
    $'import uvm_pkg::*,\n    tlpq_pkg::*,\n    gq_pkg::*;'

expect_dmaq_import_reject escaped_import \
    'import \mailbox_pkg ::*;'

expect_dmaq_import_accept permitted_imports \
    'import uvm_pkg::*, host_mem_pkg::*, gq_pkg::*;'

expect_dmaq_import_accept import_text_in_comments_and_strings \
    $'module import_text;\n  string message = "import mailbox_pkg::*;";\n  // import msgq_pkg::*;\n  /* import cmdq_pkg::*, tlpq_pkg::*; */\n  import gq_pkg::*;\nendmodule'

exit "$status"
