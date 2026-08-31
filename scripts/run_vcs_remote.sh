#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 || ! $1 =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "usage: $0 TEST [LIBRARIES [TEST_SUITE]]" >&2
    exit 2
fi

test_name=$1
libraries=${2:-mailbox}
test_suite=${3:-}

if [[ ! $libraries =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]]; then
    echo "invalid library selection: $libraries" >&2
    exit 2
fi

if [[ -z $test_suite ]]; then
    if [[ $libraries == mailbox || $libraries == *,* ]]; then
        test_suite=gq
    else
        test_suite=$libraries
    fi
fi

if [[ ! $test_suite =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "invalid test suite: $test_suite" >&2
    exit 2
fi

remote_host=ubuntu@10.11.10.53
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
summary_checker="$repo_root/scripts/check_uvm_summary.sh"
pcie_tl_pkg="$repo_root/pcie_work/pcie_tl_vip/src/pcie_tl_pkg.sv"
log_file=

if [[ ! -f $pcie_tl_pkg ]]; then
    echo "required initialized PCIe package not found: $pcie_tl_pkg" >&2
    exit 1
fi

cleanup() {
    local status=$?
    if [[ -n $log_file ]]; then
        rm -f -- "$log_file"
    fi
    ssh "$remote_host" "rm -rf -- '$remote_dir'" || true
    return "$status"
}

remote_dir=$(ssh "$remote_host" 'mktemp -d /tmp/gq_uvm.XXXXXX')
if [[ ! $remote_dir =~ ^/tmp/gq_uvm\.[A-Za-z0-9]+$ ]]; then
    echo "unexpected remote temporary directory: $remote_dir" >&2
    exit 1
fi
trap cleanup EXIT
log_file=$(mktemp "${TMPDIR:-/tmp}/gq_uvm_summary.XXXXXX")

rsync -a \
    --exclude='.git' \
    --exclude='.git/' \
    --exclude='.superpowers/' \
    --exclude='build/' \
    -e ssh \
    "$repo_root/" "$remote_host:$remote_dir/"

set +e
ssh "$remote_host" \
    "cd '$remote_dir' && bash -lc 'bash -ic \"make run TEST=$test_name LIBS=$libraries TEST_SUITE=$test_suite\"'" \
    2>&1 | tee "$log_file"
pipeline_status=("${PIPESTATUS[@]}")
set -e

remote_status=${pipeline_status[0]}
tee_status=${pipeline_status[1]}
summary_status=0
"$summary_checker" "$log_file" || summary_status=$?

if ((remote_status != 0)); then
    printf 'remote VCS command failed with status %d\n' "$remote_status" >&2
    exit "$remote_status"
fi
if ((tee_status != 0)); then
    printf 'failed to capture remote VCS output (tee status %d)\n' \
        "$tee_status" >&2
    exit "$tee_status"
fi
exit "$summary_status"
