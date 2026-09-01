#!/usr/bin/env bats
#
# Tests for the generated boot helper scripts (the files ExecStart= points at).
#
# These are the only place the boot-time tuning lives, and nothing else checks
# them: they are emitted as text, so a typo in the generator ships a broken
# script that fails silently at boot. Each test extracts the script straight
# out of --report and treats it as the artifact it is — parse it, run it, and
# require it to stay quiet.

load helpers/extract_fn.sh

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SYS="$REPO/system_optimize.sh"
    NET="$REPO/network_optimize.sh"
    TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMPDIR_TEST"
}

# Pull one "RECOMMENDED FILE: <path>" block out of a --report capture.
extract_report_file() {
    local report=$1 path=$2
    awk -v want="RECOMMENDED FILE: $path" '
        index($0, want) == 1 { getline; found = 1; next }
        found && /^=+$/ { exit }
        found { print }
    ' "$report"
}

# Capture <script> --report --profile=<profile> and extract <path> from it.
generate_boot_script() {
    local script=$1 profile=$2 path=$3 out="$TMPDIR_TEST/boot.sh"
    "$script" --report --profile="$profile" >"$TMPDIR_TEST/report.txt" 2>&1
    extract_report_file "$TMPDIR_TEST/report.txt" "$path" >"$out"
    [ -s "$out" ] || {
        echo "no $path block in report" >&2
        return 1
    }
    printf '%s' "$out"
}

# ----- system_optimize boot script -----

@test "generated system boot script is valid bash" {
    local f
    f=$(generate_boot_script "$SYS" latency /usr/local/sbin/system-optimize-boot.sh)
    run bash -n "$f"
    [ "$status" -eq 0 ]
}

@test "generated system boot script runs silently and exits 0 unprivileged" {
    if [ "$EUID" -eq 0 ]; then skip "running as root would apply real changes"; fi
    local f
    f=$(generate_boot_script "$SYS" latency /usr/local/sbin/system-optimize-boot.sh)
    # Every sysfs write fails with EACCES here. They must all be swallowed:
    # a bare `>"$path" 2>/dev/null` leaks the redirect-open error to stderr and
    # would spam the journal on every boot.
    run bash "$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "generated system boot script includes the C-state loop only for low latency" {
    local f
    f=$(generate_boot_script "$SYS" latency /usr/local/sbin/system-optimize-boot.sh)
    grep -q 'cpuidle/state' "$f"

    f=$(generate_boot_script "$SYS" server /usr/local/sbin/system-optimize-boot.sh)
    ! grep -q 'cpuidle/state' "$f"
}

@test "generated system boot script bakes in literal tuning values" {
    local f
    f=$(generate_boot_script "$SYS" server /usr/local/sbin/system-optimize-boot.sh)
    # No unresolved generator variables may survive into the artifact.
    ! grep -qE '\$\{(PROFILE_|SERVICE_|TUNE_|OPT_)' "$f"
    # The values --verify reads back must be literals, not variable references.
    grep -qE '^write_sysfs /sys/kernel/mm/transparent_hugepage/enabled [a-z]+$' "$f"
    grep -qE '^write_sysfs /sys/devices/system/cpu/intel_pstate/no_turbo [01]$' "$f"
}

# ----- network_optimize boot script -----

@test "generated network boot script is valid bash" {
    local f
    f=$(generate_boot_script "$NET" server /usr/local/sbin/network-optimize-boot.sh)
    run bash -n "$f"
    [ "$status" -eq 0 ]
}

@test "generated network boot script runs silently and exits 0 unprivileged" {
    if [ "$EUID" -eq 0 ]; then skip "running as root would apply real changes"; fi
    local f
    f=$(generate_boot_script "$NET" server /usr/local/sbin/network-optimize-boot.sh)
    run bash "$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "generated network boot script computes the same mask as the live path" {
    local f
    f=$(generate_boot_script "$NET" server /usr/local/sbin/network-optimize-boot.sh)
    # cpu_mask_for_cores is the shared contract between the live apply path and
    # the boot script; check the copy in the artifact against known values.
    # The script cannot be sourced (it ends in `exit 0`), so pluck the function.
    eval "$(extract_fn "$f" cpu_mask_for_cores)"

    [ "$(cpu_mask_for_cores 1)" = "00000001" ]
    [ "$(cpu_mask_for_cores 4)" = "0000000f" ]
    [ "$(cpu_mask_for_cores 32)" = "ffffffff" ]
    [ "$(cpu_mask_for_cores 40)" = "000000ff,ffffffff" ]
    [ "$(cpu_mask_for_cores 64)" = "ffffffff,ffffffff" ]
    # Degenerate input must not produce an empty mask.
    [ "$(cpu_mask_for_cores 0)" = "00000001" ]
}

@test "generated network boot script agrees with the live path mask" {
    local f expected actual
    f=$(generate_boot_script "$NET" server /usr/local/sbin/network-optimize-boot.sh)
    # Same function name in both files; a drifting copy is the bug this catches.
    eval "$(extract_fn "$NET" cpu_mask_for_cores)"
    expected=$(cpu_mask_for_cores 28)
    unset -f cpu_mask_for_cores
    eval "$(extract_fn "$f" cpu_mask_for_cores)"
    actual=$(cpu_mask_for_cores 28)
    [ "$expected" = "$actual" ]
}

@test "generated network boot script skips virtual interfaces" {
    local f skip_re
    f=$(generate_boot_script "$NET" server /usr/local/sbin/network-optimize-boot.sh)
    skip_re=$(sed -n "s/^SKIP_IFACE_RE='\(.*\)'$/\1/p" "$f")
    [ -n "$skip_re" ]
    for iface in lo docker0 veth1a2b br-abc virbr0; do
        [[ "$iface" =~ $skip_re ]] || {
            echo "$iface not skipped by $skip_re" >&2
            return 1
        }
    done
    for iface in eth0 ens5 enp0s31f6; do
        if [[ "$iface" =~ $skip_re ]]; then
            echo "$iface wrongly skipped by $skip_re" >&2
            return 1
        fi
    done
}
