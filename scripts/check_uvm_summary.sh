#!/usr/bin/env bash
# scripts/check_uvm_summary.sh: 校验 VCS/UVM 日志包含唯一且干净的最终摘要。
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 LOG_FILE" >&2
    exit 2
fi

log_file=$1
if [[ ! -r $log_file ]]; then
    printf 'UVM log is not readable: %s\n' "$log_file" >&2
    exit 2
fi

if ! counts=$(awk '
    {
        sub(/\r$/, "")
    }
    $0 == "--- UVM Report Summary ---" {
        summary_seen = 1
        severity_section = 0
        severity_marker = 0
        id_marker = 0
        have_warning = 0
        have_error = 0
        have_fatal = 0
        next
    }
    summary_seen && $0 == "** Report counts by severity" {
        severity_section = 1
        severity_marker = 1
        next
    }
    summary_seen && $0 == "** Report counts by id" {
        severity_section = 0
        id_marker = 1
        next
    }
    severity_section &&
        $0 ~ /^UVM_WARNING[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*$/ {
        value = $0
        sub(/^UVM_WARNING[[:space:]]*:[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
        warning_count = value + 0
        have_warning = 1
        next
    }
    severity_section &&
        $0 ~ /^UVM_ERROR[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*$/ {
        value = $0
        sub(/^UVM_ERROR[[:space:]]*:[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
        error_count = value + 0
        have_error = 1
        next
    }
    severity_section &&
        $0 ~ /^UVM_FATAL[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*$/ {
        value = $0
        sub(/^UVM_FATAL[[:space:]]*:[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
        fatal_count = value + 0
        have_fatal = 1
        next
    }
    END {
        if (!summary_seen || !severity_marker || !id_marker ||
            !have_warning || !have_error || !have_fatal)
            exit 1
        printf "%d %d %d\n", warning_count, error_count, fatal_count
    }
' "$log_file"); then
    printf 'missing or incomplete final UVM report summary in %s\n' \
        "$log_file" >&2
    exit 1
fi

read -r warning_count error_count fatal_count <<<"$counts"
if ((warning_count != 0 || error_count != 0 || fatal_count != 0)); then
    printf 'non-pristine final UVM summary: warning=%d error=%d fatal=%d\n' \
        "$warning_count" "$error_count" "$fatal_count" >&2
    exit 1
fi
