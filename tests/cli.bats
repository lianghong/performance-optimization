#!/usr/bin/env bats
#
# Black-box CLI tests. These run both scripts in --dry-run/--report/--help
# modes and verify exit codes, error messages, and input validation.
# No root required, no real changes made.

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SYS="$REPO/system_optimize.sh"
    NET="$REPO/network_optimize.sh"
}

# ----- --help -----

@test "system_optimize --help exits 0 and lists profiles" {
    run "$SYS" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--profile"* ]]
    [[ "$output" == *"server"* ]]
    [[ "$output" == *"workstation"* ]]
    [[ "$output" == *"latency"* ]]
}

@test "network_optimize --help exits 0 and lists congestion option" {
    run "$NET" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--profile"* ]]
    [[ "$output" == *"--congestion"* ]]
}

# ----- Unknown flags -----

@test "system_optimize rejects unknown option" {
    run "$SYS" --nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "network_optimize rejects unknown option" {
    run "$NET" --nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
}

# ----- Profile validation -----

@test "system_optimize rejects invalid profile" {
    run "$SYS" --dry-run --profile=bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"profile"* ]]
}

@test "network_optimize rejects invalid profile" {
    run "$NET" --dry-run --profile=bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"profile"* ]]
}

# ----- All valid profiles dry-run cleanly -----

@test "system_optimize dry-runs every profile without error" {
    for p in server vm workstation laptop latency auto; do
        run "$SYS" --dry-run --profile="$p"
        [ "$status" -eq 0 ] || { echo "profile=$p failed: $output" >&2; return 1; }
    done
}

@test "network_optimize dry-runs every profile without error" {
    for p in server vm workstation laptop latency auto; do
        run "$NET" --dry-run --profile="$p"
        [ "$status" -eq 0 ] || { echo "profile=$p failed: $output" >&2; return 1; }
    done
}

# ----- --report mode -----

@test "system_optimize --report contains sysctl snippet" {
    run "$SYS" --report --profile=server
    [ "$status" -eq 0 ]
    [[ "$output" == *"vm.swappiness"* ]]
    [[ "$output" == *"fs.file-max"* ]]
}

@test "network_optimize --report contains tcp sysctl" {
    run "$NET" --report --profile=server
    [ "$status" -eq 0 ]
    [[ "$output" == *"net.core.rmem_max"* ]] || [[ "$output" == *"net.ipv4.tcp"* ]]
}

# ----- Generated systemd unit contract -----
#
# Two invariants, both learned the hard way:
#
# 1. No inline shell in ExecStart=. systemd substitutes ${NAME} before exec
#    (undefined -> empty string) and reads a bare % as a specifier, so an
#    embedded shell program silently mutates. Boot logic lives in a generated
#    helper script instead, and ExecStart= just names it.
# 2. Every ExecStart= must be failure-tolerant ('-' prefix). Per
#    systemd.service(5): in a Type=oneshot unit, if one command fails and is
#    not prefixed with '-', the remaining lines are not executed and the unit
#    is considered failed.

exec_start_lines() {
    printf '%s\n' "$output" | grep '^ExecStart=' || true
}

assert_no_inline_shell() {
    local lines
    lines=$(exec_start_lines)
    [ -n "$lines" ] || { echo "no ExecStart= lines in report" >&2; return 1; }
    if grep -q -- '-c' <<<"$lines"; then
        echo "inline shell in ExecStart=: $lines" >&2
        return 1
    fi
    if grep -q -- '\${' <<<"$lines"; then
        echo "systemd erases \${...} in ExecStart=: $lines" >&2
        return 1
    fi
    if grep -q -- '%' <<<"$lines"; then
        echo "bare % is a systemd specifier in ExecStart=: $lines" >&2
        return 1
    fi
}

assert_execstart_failure_tolerant() {
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "${line#ExecStart=}" in
            -*) ;;
            *)
                echo "ExecStart= is not failure-tolerant: $line" >&2
                return 1
                ;;
        esac
    done < <(exec_start_lines)
}

@test "system_optimize unit has no inline shell in ExecStart" {
    run "$SYS" --report --profile=latency
    [ "$status" -eq 0 ]
    assert_no_inline_shell
}

@test "network_optimize unit has no inline shell in ExecStart" {
    run "$NET" --report --profile=server
    [ "$status" -eq 0 ]
    assert_no_inline_shell
}

@test "system_optimize unit ExecStart lines tolerate failure" {
    run "$SYS" --report --profile=latency
    [ "$status" -eq 0 ]
    assert_execstart_failure_tolerant
}

@test "network_optimize unit ExecStart lines tolerate failure" {
    run "$NET" --report --profile=server
    [ "$status" -eq 0 ]
    assert_execstart_failure_tolerant
}

# The boot helper must re-apply what the live path applied, or the post-reboot
# state silently diverges from what the script reported.

@test "network_optimize boot helper mirrors the live RPS path" {
    run "$NET" --report --profile=server
    [ "$status" -eq 0 ]
    # RFS per-queue setting, skipped by the old inline unit command.
    [[ "$output" == *"rps_flow_cnt"* ]]
    # Virtual interfaces must be excluded, as in the live path.
    [[ "$output" == *"veth"* ]]
    [[ "$output" == *"docker"* ]]
}

@test "network_optimize boot helper probes offload support per feature" {
    run "$NET" --report --profile=server
    [ "$status" -eq 0 ]
    # Must read current feature state rather than blindly setting gro/gso/tso.
    [[ "$output" == *"ethtool -k"* ]]
}

# ----- --isolate-cpus validation -----

@test "system_optimize rejects non-numeric --isolate-cpus" {
    run "$SYS" --dry-run --profile=server --isolate-cpus=abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"isolate-cpus"* ]]
}

@test "system_optimize rejects out-of-range --isolate-cpus" {
    run "$SYS" --dry-run --profile=server --isolate-cpus=99999
    [ "$status" -ne 0 ]
    [[ "$output" == *"exceeds available CPUs"* ]]
}

@test "system_optimize accepts valid single-cpu --isolate-cpus=0" {
    run "$SYS" --dry-run --profile=server --isolate-cpus=0
    [ "$status" -eq 0 ]
}

# ----- Requires-root guard -----

@test "system_optimize requires root when not in preview mode" {
    if [ "$EUID" -eq 0 ]; then skip "running as root"; fi
    run "$SYS" --profile=server
    [ "$status" -ne 0 ]
    [[ "$output" == *"root"* ]] || [[ "$output" == *"sudo"* ]]
}

@test "network_optimize requires root when not in preview mode" {
    if [ "$EUID" -eq 0 ]; then skip "running as root"; fi
    run "$NET" --profile=server
    [ "$status" -ne 0 ]
    [[ "$output" == *"root"* ]] || [[ "$output" == *"sudo"* ]]
}

# ----- --verify exit code contract -----
# --verify returns 0 if all settings match, 1 if drift detected.
# We don't know which one the CI host is in, so just assert exit is 0 or 1.

@test "system_optimize --verify exits 0 or 1" {
    run "$SYS" --verify
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "network_optimize --verify exits 0 or 1" {
    run "$NET" --verify
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}
