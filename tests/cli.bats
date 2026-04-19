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
