#!/usr/bin/env bats
#
# Unit tests for the read-only probe helpers used by the --report path.
#
# Two classes of bug live here:
#   * greedy sed that silently captures nothing, so the report prints a
#     hard-coded fallback while claiming it detected the real value;
#   * command substitution under `set -euo pipefail`, where a missing tool
#     (127) or a no-match grep (1) propagates out of the pipeline and kills
#     the whole script mid-report.
# Both are invisible unless the helper is exercised directly.

load helpers/extract_fn.sh

setup() {
    SYS="$BATS_TEST_DIRNAME/../system_optimize.sh"
    TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMPDIR_TEST"
}

# ----- sar_interval_from_cron -----

sar_fixture() {
    printf '%s\n' "$@" >"$TMPDIR_TEST/sysstat"
    printf '%s' "$TMPDIR_TEST/sysstat"
}

@test "sar_interval_from_cron reads the interval from a Debian cron.d/sysstat" {
    eval "$(extract_fn "$SYS" sar_interval_from_cron)"
    local f
    f=$(sar_fixture \
        'PATH=/usr/lib/sysstat:/usr/sbin:/usr/bin:/sbin:/bin' \
        '5-55/10 * * * * root command -v debian-sa1 > /dev/null && debian-sa1 1 1' \
        '53 23 * * * root command -v debian-sa1 > /dev/null && debian-sa1 60 2')
    run sar_interval_from_cron "$f"
    [ "$status" -eq 0 ]
    [ "$output" = "10" ]
}

@test "sar_interval_from_cron reads a non-default interval" {
    eval "$(extract_fn "$SYS" sar_interval_from_cron)"
    local f
    f=$(sar_fixture \
        'PATH=/usr/lib/sysstat:/usr/sbin:/usr/bin:/sbin:/bin' \
        '*/2 * * * * root /usr/lib/sysstat/debian-sa1 1 1')
    run sar_interval_from_cron "$f"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "sar_interval_from_cron handles the RHEL sysstat layout" {
    eval "$(extract_fn "$SYS" sar_interval_from_cron)"
    local f
    f=$(sar_fixture \
        '*/10 * * * * root /usr/lib64/sa/sa1 1 1' \
        '53 23 * * * root /usr/lib64/sa/sa2 -A')
    run sar_interval_from_cron "$f"
    [ "$status" -eq 0 ]
    [ "$output" = "10" ]
}

@test "sar_interval_from_cron emits nothing for a missing file" {
    eval "$(extract_fn "$SYS" sar_interval_from_cron)"
    run sar_interval_from_cron "$TMPDIR_TEST/does-not-exist"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "sar_interval_from_cron emits nothing when no schedule is present" {
    eval "$(extract_fn "$SYS" sar_interval_from_cron)"
    local f
    f=$(sar_fixture '# all commented out' 'PATH=/usr/lib/sysstat')
    run sar_interval_from_cron "$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ----- xfs_log_line -----
# Runs under the same strict mode as the script, with xfs_info stubbed.

@test "xfs_log_line survives a no-match under pipefail" {
    run bash -c "
        set -euo pipefail
        $(extract_fn "$SYS" xfs_log_line)
        xfs_info() { printf 'meta-data=/dev/sda1 isize=512\n'; }
        v=\$(xfs_log_line /mnt)
        echo \"survived rc=\$? value=[\$v]\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived"* ]]
    [[ "$output" == *"value=[]"* ]]
}

@test "xfs_log_line survives a failing xfs_info under pipefail" {
    run bash -c "
        set -euo pipefail
        $(extract_fn "$SYS" xfs_log_line)
        xfs_info() { return 1; }
        v=\$(xfs_log_line /mnt)
        echo \"survived value=[\$v]\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived"* ]]
}

@test "xfs_log_line returns the log line when present" {
    run bash -c "
        set -euo pipefail
        $(extract_fn "$SYS" xfs_log_line)
        xfs_info() { printf 'data     =  bsize=4096\nlog      =internal log bsize=4096 blocks=2560\n'; }
        xfs_log_line /mnt
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"internal log"* ]]
}

# ----- btrfs_uuid_for -----

@test "btrfs_uuid_for survives a missing btrfs binary under pipefail" {
    run bash -c "
        set -euo pipefail
        $(extract_fn "$SYS" btrfs_uuid_for)
        btrfs() { return 127; }
        v=\$(btrfs_uuid_for /mnt)
        echo \"survived value=[\$v]\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived"* ]]
    [[ "$output" == *"value=[]"* ]]
}

@test "btrfs_uuid_for extracts the filesystem uuid" {
    run bash -c "
        set -euo pipefail
        $(extract_fn "$SYS" btrfs_uuid_for)
        btrfs() { printf \"Label: none  uuid: 3f2b1c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d\n\"; }
        btrfs_uuid_for /mnt
    "
    [ "$status" -eq 0 ]
    [ "$output" = "3f2b1c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d" ]
}
