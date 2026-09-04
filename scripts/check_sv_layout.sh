#!/usr/bin/env bash
# scripts/check_sv_layout.sh: 仓库自有 SystemVerilog 源码的布局和依赖隔离静态检查。
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

scan_tlpq_address_literals() {
    perl - "$@" <<'PERL'
use strict;
use warnings;

sub mask_sv_noncode {
    my ($text) = @_;
    my $masked = '';
    my $state = 'code';
    my $length = length($text);
    my $i = 0;

    while ($i < $length) {
        my $ch = substr($text, $i, 1);
        my $next = ($i + 1 < $length) ? substr($text, $i + 1, 1) : '';

        if ($state eq 'code') {
            if ($ch eq '/' && $next eq '/') {
                $masked .= '  ';
                $i += 2;
                $state = 'line_comment';
                next;
            }
            if ($ch eq '/' && $next eq '*') {
                $masked .= '  ';
                $i += 2;
                $state = 'block_comment';
                next;
            }
            if ($ch eq '"') {
                $masked .= ' ';
                $i++;
                $state = 'string';
                next;
            }
            $masked .= $ch;
            $i++;
            next;
        }

        if ($state eq 'line_comment') {
            if ($ch eq "\n") {
                $masked .= "\n";
                $state = 'code';
            } else {
                $masked .= ' ';
            }
            $i++;
            next;
        }

        if ($state eq 'block_comment') {
            if ($ch eq '*' && $next eq '/') {
                $masked .= '  ';
                $i += 2;
                $state = 'code';
                next;
            }
            $masked .= ($ch eq "\n") ? "\n" : ' ';
            $i++;
            next;
        }

        if ($ch eq '\\' && $next ne '') {
            $masked .= ' ';
            $masked .= ($next eq "\n") ? "\n" : ' ';
            $i += 2;
            next;
        }
        if ($ch eq '"') {
            $masked .= ' ';
            $i++;
            $state = 'code';
            next;
        }
        $masked .= ($ch eq "\n") ? "\n" : ' ';
        $i++;
    }
    return $masked;
}

sub address_identifier {
    my ($identifier) = @_;
    # Normalize ordinary camelCase/PascalCase boundaries before applying the
    # semantic token match. This catches csrAddress and RXCsrAddress without
    # turning unrelated substrings such as addressable into address tokens.
    $identifier =~ s/([A-Z]+)([A-Z][a-z])/$1_$2/g;
    $identifier =~ s/([a-z0-9])([A-Z])/$1_$2/g;
    return lc($identifier) =~
        /(?:^|_)(?:addr|address|base|offset|register|reg|mmio|csr|bar)(?:_|$)/;
}

sub whitelisted_statement {
    my ($semantic, $raw) = @_;
    my $normalized = $semantic;
    $normalized =~ s/^\s+|\s+$//g;
    $normalized =~ s/\s+/ /g;

    # Finite built-in whitelist: descriptor buffer handles use zero only as
    # detached/unprepared state, never as a hardware register mapping.
    return 1 if $normalized =~
        /^(?:this\.)?(?:buf_addr|prepared_buf_addr)\s*=\s*0\s*;$/;

    # Explicit exceptions remain visible in source review and are restricted
    # to these semantic categories rather than accepting arbitrary markers.
    return 1 if $raw =~
        /TLPQ_LAYOUT_ALLOW_ADDR_LITERAL:\s*(?:protocol-constant|descriptor-layout|buffer-sentinel)\b/;
    return 0;
}

sub scan_statement {
    my ($file, $line, $statement, $raw_statement) = @_;
    my $semantic = $statement;

    # Numeric declaration widths, packed ranges, and array indices are layout,
    # not address values. Remove balanced innermost brackets before tokenizing.
    1 while $semantic =~ s/\[[^\[\]]*\]/ /g;

    my $has_c_hex = $semantic =~
        /(?<![A-Za-z0-9_\$])0[xX][0-9a-fA-F_]+/;
    my $relation_probe = $semantic;
    # A function's trailing `return 0;`/`return 1'b0;` is a status result, not
    # an address value participating in the preceding condition. Preserve
    # compound return expressions so literal/address comparisons still fail.
    $relation_probe =~ s{
        \breturn\s+
        (?:
            0[xX][0-9a-fA-F_]+ |
            (?:[0-9][0-9_]*\s*)?'\s*[sS]?\s*[bBoOdDhH]\s*[0-9a-fA-F_xXzZ?]+ |
            [0-9][0-9_]*
        )
        \s*;
    }{ }gx;
    my @identifiers = $relation_probe =~ /[A-Za-z_\$][A-Za-z0-9_\$]*/g;
    my @address_identifiers = grep { address_identifier($_) } @identifiers;
    my $has_address_identifier = @address_identifiers != 0;

    my $literal_probe = $relation_probe;
    my $has_sv_based = $literal_probe =~
        /(?<![A-Za-z0-9_\$])(?:[0-9][0-9_]*\s*)?'\s*[sS]?\s*[bBoOdDhH]\s*[0-9a-fA-F_xXzZ?]+/;
    $literal_probe =~ s/(?<![A-Za-z0-9_\$])0[xX][0-9a-fA-F_]+/ /g;
    $literal_probe =~ s/(?<![A-Za-z0-9_\$])(?:[0-9][0-9_]*\s*)?'\s*[sS]?\s*[bBoOdDhH]\s*[0-9a-fA-F_xXzZ?]+/ /g;
    my $has_unsized_decimal = $literal_probe =~
        /(?<![A-Za-z0-9_\$'])[0-9][0-9_]*(?![A-Za-z0-9_\$])/;

    # Width metadata may legitimately contain an address token and a plain
    # decimal (for example `define TLPQ_ADDR_WIDTH 64). It is not a register
    # mapping. Based and C-style hexadecimal literals remain prohibited.
    my $only_address_width_identifiers = @address_identifiers != 0;
    for my $identifier (@address_identifiers) {
        my $normalized = $identifier;
        $normalized =~ s/([A-Z]+)([A-Z][a-z])/$1_$2/g;
        $normalized =~ s/([a-z0-9])([A-Z])/$1_$2/g;
        if (lc($normalized) !~ /(?:^|_)width(?:_|$)/) {
            $only_address_width_identifiers = 0;
            last;
        }
    }
    return if !$has_c_hex && !$has_sv_based && $has_unsized_decimal &&
        $only_address_width_identifiers;

    return unless $has_c_hex ||
        ($has_address_identifier && ($has_sv_based || $has_unsized_decimal));
    return if !$has_c_hex &&
        whitelisted_statement($semantic, $raw_statement);

    my $display = $semantic;
    $display =~ s/^\s+|\s+$//g;
    $display =~ s/\s+/ /g;
    $display = substr($display, 0, 240) . '...' if length($display) > 240;
    print "$file:$line:$display\n";
}

for my $file (@ARGV) {
    open my $fh, '<', $file or die "cannot read $file: $!\n";
    local $/;
    my $raw = <$fh>;
    close $fh or die "cannot close $file: $!\n";
    my $masked = mask_sv_noncode($raw);

    # Preprocessor definitions are line-oriented and need no terminating
    # semicolon. Scan each logical `define (including backslash continuations)
    # before the ordinary statement pass, then blank it from that pass while
    # preserving line numbers.
    my @masked_lines = split /\n/, $masked, -1;
    my @raw_lines = split /\n/, $raw, -1;
    for (my $i = 0; $i < @masked_lines; $i++) {
        next unless $masked_lines[$i] =~ /^\s*`define\b/;
        my $start = $i;
        my $logical_masked = $masked_lines[$i];
        my $logical_raw = $raw_lines[$i];
        while ($logical_masked =~ /\\\s*$/ && $i + 1 < @masked_lines) {
            $i++;
            $logical_masked .= "\n" . $masked_lines[$i];
            $logical_raw .= "\n" . $raw_lines[$i];
        }
        scan_statement($file, $start + 1, $logical_masked, $logical_raw);
        for my $line_index ($start .. $i) {
            $masked_lines[$line_index] =~ s/./ /g;
        }
    }
    $masked = join "\n", @masked_lines;

    my $cursor = 0;
    my $line = 1;

    while ($masked =~ /;/g) {
        my $end = pos($masked);
        my $statement = substr($masked, $cursor, $end - $cursor);
        my $raw_statement = substr($raw, $cursor, $end - $cursor);
        my $leading = $statement;
        my $statement_line = $line;
        if ($leading =~ /\S/) {
            my $prefix = substr($leading, 0, $-[0]);
            $statement_line += ($prefix =~ tr/\n//);
        }
        scan_statement($file, $statement_line, $statement, $raw_statement);
        $line += ($statement =~ tr/\n//);
        $cursor = $end;
    }
}
PERL
}

scan_dmaq_business_imports() {
    perl - "$@" <<'PERL'
use strict;
use warnings;

sub mask_sv_noncode {
    my ($text) = @_;
    my $masked = '';
    my $state = 'code';
    my $length = length($text);
    my $i = 0;

    while ($i < $length) {
        my $ch = substr($text, $i, 1);
        my $next = ($i + 1 < $length) ? substr($text, $i + 1, 1) : '';

        if ($state eq 'code') {
            if ($ch eq '/' && $next eq '/') {
                $masked .= '  ';
                $i += 2;
                $state = 'line_comment';
                next;
            }
            if ($ch eq '/' && $next eq '*') {
                $masked .= '  ';
                $i += 2;
                $state = 'block_comment';
                next;
            }
            if ($ch eq '"') {
                $masked .= ' ';
                $i++;
                $state = 'string';
                next;
            }
            $masked .= $ch;
            $i++;
            next;
        }

        if ($state eq 'line_comment') {
            if ($ch eq "\n") {
                $masked .= "\n";
                $state = 'code';
            } else {
                $masked .= ' ';
            }
            $i++;
            next;
        }

        if ($state eq 'block_comment') {
            if ($ch eq '*' && $next eq '/') {
                $masked .= '  ';
                $i += 2;
                $state = 'code';
                next;
            }
            $masked .= ($ch eq "\n") ? "\n" : ' ';
            $i++;
            next;
        }

        if ($ch eq '\\' && $next ne '') {
            $masked .= ' ';
            $masked .= ($next eq "\n") ? "\n" : ' ';
            $i += 2;
            next;
        }
        if ($ch eq '"') {
            $masked .= ' ';
            $i++;
            $state = 'code';
            next;
        }
        $masked .= ($ch eq "\n") ? "\n" : ' ';
        $i++;
    }
    return $masked;
}

sub forbidden_business_package {
    my ($package_name) = @_;
    return $package_name =~
        /^(?:mailbox_pkg|msgq_pkg|cmdq_pkg|tlpq_pkg|pcie(?:_[A-Za-z0-9_\$]+)*_pkg)$/i;
}

for my $file (@ARGV) {
    open my $fh, '<', $file or die "cannot read $file: $!\n";
    local $/;
    my $raw = <$fh>;
    close $fh or die "cannot close $file: $!\n";
    my $masked = mask_sv_noncode($raw);

    while ($masked =~ /\bimport\b(.*?);/sg) {
        my $declaration_start = $-[0];
        my $declaration_end = $+[0];
        my $body = $1;
        my $line = 1 + (substr($masked, 0, $declaration_start) =~ tr/\n//);
        my $display = substr(
            $raw, $declaration_start, $declaration_end - $declaration_start);
        $display =~ s/\/\*.*?\*\// /sg;
        $display =~ s{//[^\n]*}{ }g;
        $display =~ s/^\s+|\s+$//g;
        $display =~ s/\s+/ /g;

        for my $item (split /,/, $body) {
            my $package_name;
            if ($item =~
                /^\s*([A-Za-z_\$][A-Za-z0-9_\$]*)\s*::/s) {
                $package_name = $1;
            } elsif ($item =~ /^\s*(\\\S+)\s+::/s) {
                $package_name = $1;
                $package_name =~ s/^\\//;
            } else {
                next;
            }
            next unless forbidden_business_package($package_name);
            print "$file:$line:forbidden DMAQ import $package_name in $display\n";
        }
    }
}
PERL
}

if [[ ${1:-} == --scan-dmaq-imports-only ]]; then
    shift
    if (($# == 0)); then
        printf '%s requires at least one SystemVerilog file\n' \
            '--scan-dmaq-imports-only' >&2
        exit 2
    fi
    if ! command -v perl >/dev/null 2>&1; then
        printf 'required command not found: perl\n' >&2
        exit 2
    fi
    if ! dmaq_business_output=$(scan_dmaq_business_imports "$@"); then
        printf 'failed to scan DMAQ business isolation\n' >&2
        exit 2
    fi
    if [[ -n $dmaq_business_output ]]; then
        printf 'DMAQ business-library dependencies remain:\n' >&2
        printf '  %s\n' "$dmaq_business_output" >&2
        exit 1
    fi
    exit 0
fi

if [[ ${1:-} == --scan-tlpq-addresses-only ]]; then
    shift
    if (($# == 0)); then
        printf '%s requires at least one SystemVerilog file\n' \
            '--scan-tlpq-addresses-only' >&2
        exit 2
    fi
    if ! command -v perl >/dev/null 2>&1; then
        printf 'required command not found: perl\n' >&2
        exit 2
    fi
    if ! tlpq_address_output=$(scan_tlpq_address_literals "$@"); then
        printf 'failed to scan TLPQ register-address literals\n' >&2
        exit 2
    fi
    if [[ -n $tlpq_address_output ]]; then
        printf 'TLPQ register-address literals remain:\n' >&2
        printf '  %s\n' "$tlpq_address_output" >&2
        exit 1
    fi
    exit 0
fi

status=0

for command_name in find sort grep git perl; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'required command not found: %s\n' "$command_name" >&2
        status=1
    fi
done

for required_dir in src src/dmaq tb/mocks tb/tests; do
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
    src/dmaq/dmaq_pkg.sv \
    src/dmaq/dmaq_types.sv \
    src/dmaq/dmaq_tx_desc.sv \
    src/dmaq/dmaq_completion.sv \
    src/dmaq/dmaq_ptr_codec.sv \
    src/dmaq/dmaq_reg_adapter.sv \
    src/dmaq/dmaq_env.sv \
    src/dmaq/dmaq_sequences.sv \
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

required_dmaq_files=(
    src/dmaq/dmaq_completion.sv
    src/dmaq/dmaq_env.sv
    src/dmaq/dmaq_pkg.sv
    src/dmaq/dmaq_ptr_codec.sv
    src/dmaq/dmaq_reg_adapter.sv
    src/dmaq/dmaq_sequences.sv
    src/dmaq/dmaq_tx_desc.sv
    src/dmaq/dmaq_types.sv
)
dmaq_symlinks=()
if [[ -L src/dmaq ]]; then
    dmaq_symlinks+=(src/dmaq)
elif [[ -d src/dmaq ]]; then
    mapfile -t dmaq_symlinks < <(
        find src/dmaq -type l -print | sort
    )
fi
if ((${#dmaq_symlinks[@]} != 0)); then
    printf 'src/dmaq must not contain symbolic links:\n' >&2
    printf '  %s\n' "${dmaq_symlinks[@]}" >&2
    status=1
fi

dmaq_non_sv_files=()
if [[ -d src/dmaq ]]; then
    mapfile -t dmaq_non_sv_files < <(
        find src/dmaq -type f ! -name '*.sv' -print | sort
    )
fi
if ((${#dmaq_non_sv_files[@]} != 0)); then
    printf 'src/dmaq must contain only .sv files:\n' >&2
    printf '  %s\n' "${dmaq_non_sv_files[@]}" >&2
    status=1
fi

actual_dmaq_files=()
if [[ -d src/dmaq ]]; then
    mapfile -t actual_dmaq_files < <(
        find src/dmaq -type f -name '*.sv' -print | sort
    )
fi
if ((${#actual_dmaq_files[@]} != ${#required_dmaq_files[@]})); then
    printf 'src/dmaq must contain exactly the %d planned .sv files\n' \
        "${#required_dmaq_files[@]}" >&2
    status=1
else
    for ((i = 0; i < ${#required_dmaq_files[@]}; i++)); do
        if [[ ${actual_dmaq_files[i]} != "${required_dmaq_files[i]}" ]]; then
            printf 'unexpected src/dmaq .sv layout: got %s, expected %s\n' \
                "${actual_dmaq_files[i]}" "${required_dmaq_files[i]}" >&2
            status=1
        fi
    done
fi

dmaq_business_imports=()
if ! dmaq_business_import_output=$(
    scan_dmaq_business_imports "${actual_dmaq_files[@]}"
); then
    printf 'failed to scan DMAQ business isolation\n' >&2
    exit 2
fi
if [[ -n $dmaq_business_import_output ]]; then
    mapfile -t dmaq_business_imports <<< "$dmaq_business_import_output"
    printf 'DMAQ business-library dependencies remain:\n' >&2
    printf '  %s\n' "${dmaq_business_imports[@]}" >&2
    status=1
fi

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
tlpq_symlinks=()
if [[ -L src/tlpq ]]; then
    tlpq_symlinks+=(src/tlpq)
elif [[ -d src/tlpq ]]; then
    mapfile -t tlpq_symlinks < <(
        find src/tlpq -type l -print | sort
    )
fi
if ((${#tlpq_symlinks[@]} != 0)); then
    printf 'src/tlpq must not contain symbolic links:\n' >&2
    printf '  %s\n' "${tlpq_symlinks[@]}" >&2
    status=1
fi

actual_tlpq_files=()
if [[ -d src/tlpq ]]; then
    mapfile -t actual_tlpq_files < <(
        find src/tlpq -maxdepth 1 \
            \( -type f -o -type l \) -name '*.sv' -print | sort
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

pcie_work_pin=a86860d0551af62b21a8faffadc7097e8118bb07
expected_pcie_gitlink=$'160000 a86860d0551af62b21a8faffadc7097e8118bb07 0\tpcie_work'
actual_pcie_gitlink=$(git ls-files --stage -- pcie_work)
if [[ $actual_pcie_gitlink != "$expected_pcie_gitlink" ]]; then
    printf 'pcie_work must be a gitlink pinned at %s\n' \
        "$pcie_work_pin" >&2
    status=1
fi
if [[ -L pcie_work ]]; then
    printf 'pcie_work must be a real submodule worktree, not a symbolic link\n' \
        >&2
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

super_common_git_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
super_worktree_git_dir=$(cd "$(git rev-parse --git-dir)" && pwd -P)
if [[ $super_worktree_git_dir != "$super_common_git_dir" &&
      $super_worktree_git_dir != "$super_common_git_dir"/worktrees/* ]]; then
    printf 'superproject git dir is outside its common git dir: %s\n' \
        "$super_worktree_git_dir" >&2
    status=1
fi
expected_pcie_git_dir="$super_worktree_git_dir/modules/pcie_work"
if actual_pcie_git_dir_raw=$(
    git -C pcie_work rev-parse --absolute-git-dir 2>/dev/null
); then
    actual_pcie_git_dir=$(cd "$actual_pcie_git_dir_raw" && pwd -P)
    if [[ $actual_pcie_git_dir != "$expected_pcie_git_dir" ]]; then
        printf 'pcie_work git dir is %s, expected owned module %s\n' \
            "$actual_pcie_git_dir" "$expected_pcie_git_dir" >&2
        status=1
    fi
else
    printf 'failed to resolve initialized pcie_work git dir\n' >&2
    status=1
fi

if ! git -C pcie_work diff --quiet --; then
    printf 'pcie_work has unstaged changes\n' >&2
    status=1
fi
if ! git -C pcie_work diff --cached --quiet --; then
    printf 'pcie_work has staged changes\n' >&2
    status=1
fi
pcie_untracked=$(git -C pcie_work ls-files --others --exclude-standard)
if [[ -n $pcie_untracked ]]; then
    printf 'pcie_work has untracked files:\n%s\n' "$pcie_untracked" >&2
    status=1
fi

if ((status != 0)); then
    exit "$status"
fi

stale_files=()
mapfile -d '' -t stale_files < <(
    git ls-files -z -- '*.svh' '*.v' '*.vh'
)
if ((${#stale_files[@]} != 0)); then
    printf 'repository-owned HDL files must all use the .sv extension:\n' >&2
    printf '  %s\n' "${stale_files[@]}" >&2
    status=1
fi

tlpq_business_matches=()
tlpq_business_pattern='mailbox|msgq|cmdq'
if tlpq_business_output=$(
    grep -niEH "$tlpq_business_pattern" src/tlpq/*.sv
); then
    mapfile -t tlpq_business_matches <<< "$tlpq_business_output"
else
    scan_status=$?
    if ((scan_status != 1)); then
        printf 'failed to scan TLPQ business isolation (exit %d)\n' \
            "$scan_status" >&2
        exit "$scan_status"
    fi
fi
if ((${#tlpq_business_matches[@]} != 0)); then
    printf 'TLPQ business-library dependencies remain:\n' >&2
    printf '  %s\n' "${tlpq_business_matches[@]}" >&2
    status=1
fi

tlpq_address_matches=()
if ! tlpq_address_output=$(scan_tlpq_address_literals src/tlpq/*.sv); then
    printf 'failed to scan TLPQ register-address literals\n' >&2
    exit 2
fi
if [[ -n $tlpq_address_output ]]; then
    mapfile -t tlpq_address_matches <<< "$tlpq_address_output"
    printf 'TLPQ register-address literals remain:\n' >&2
    printf '  %s\n' "${tlpq_address_matches[@]}" >&2
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

tracked_sv_files=()
mapfile -d '' -t tracked_sv_files < <(
    git ls-files -z -- '*.sv'
)

all_svh_includes=()
include_pattern='`include[[:space:]]+"[^"]+\.svh"'
if ((${#tracked_sv_files[@]} != 0)); then
    if all_svh_includes_output=$(
        grep -nEH "$include_pattern" "${tracked_sv_files[@]}"
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
if ((${#tracked_sv_files[@]} != 0)); then
    if stale_guards_output=$(
        grep -nEH "$guard_pattern" "${tracked_sv_files[@]}"
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
fi
if ((${#stale_guards[@]} != 0)); then
    printf 'SVH include guards remain:\n' >&2
    printf '  %s\n' "${stale_guards[@]}" >&2
    status=1
fi

exit "$status"
