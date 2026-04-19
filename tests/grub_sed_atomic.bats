#!/usr/bin/env bats
#
# Unit tests for grub_sed_atomic — the helper that applies multiple sed
# expressions to a file via a temp-file-and-rename, so power loss mid-edit
# can't corrupt boot-critical files.

load helpers/extract_fn.sh

setup() {
    SYS="$BATS_TEST_DIRNAME/../system_optimize.sh"

    # Eval the helper into the current shell so we can call it directly.
    eval "$(extract_fn "$SYS" grub_sed_atomic)"
    # grub_sed_atomic references OPT_DRY_RUN/OPT_REPORT; default to 0.
    OPT_DRY_RUN=0
    OPT_REPORT=0

    # Per-test scratch file.
    TMPDIR_TEST="$(mktemp -d)"
    GRUB="$TMPDIR_TEST/grub"
    cat >"$GRUB" <<'EOF'
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash mitigations=auto"
GRUB_CMDLINE_LINUX=""
EOF
}

teardown() {
    rm -rf "$TMPDIR_TEST"
}

@test "applies a single sed expression" {
    run grub_sed_atomic "$GRUB" 's/mitigations=auto//g'
    [ "$status" -eq 0 ]
    run grep -c 'mitigations=auto' "$GRUB"
    [ "$output" = "0" ]
    run grep -c 'GRUB_CMDLINE_LINUX_DEFAULT' "$GRUB"
    [ "$output" = "1" ]
}

@test "applies multiple expressions in one atomic pass" {
    run grub_sed_atomic "$GRUB" \
        's/mitigations=[^ "]*//g' \
        "s|GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"mitigations=off |" \
        's/  */ /g'
    [ "$status" -eq 0 ]
    run grep -c 'mitigations=off' "$GRUB"
    [ "$output" = "1" ]
    # Double spaces collapsed.
    run grep -c '  ' "$GRUB"
    [ "$output" = "0" ]
}

@test "preserves file permissions across rewrite" {
    chmod 0640 "$GRUB"
    before=$(stat -c '%a' "$GRUB")
    run grub_sed_atomic "$GRUB" 's/quiet/loud/g'
    [ "$status" -eq 0 ]
    after=$(stat -c '%a' "$GRUB")
    [ "$before" = "$after" ]
}

@test "leaves original untouched on sed failure" {
    local before_content before_inode
    before_content=$(cat "$GRUB")
    before_inode=$(stat -c '%i' "$GRUB")

    # Invalid sed expression — should fail and roll back.
    run grub_sed_atomic "$GRUB" '!!!this is not valid sed!!!'
    [ "$status" -ne 0 ]

    # Content unchanged.
    [ "$(cat "$GRUB")" = "$before_content" ]
    # No stray .XXXXXX tempfiles left behind.
    run find "$TMPDIR_TEST" -maxdepth 1 -name 'grub.*' -not -name 'grub'
    [ -z "$output" ]
    # Original inode preserved (rename never happened).
    [ "$(stat -c '%i' "$GRUB")" = "$before_inode" ]
}

@test "dry-run mode does not modify the file" {
    OPT_DRY_RUN=1
    local before
    before=$(cat "$GRUB")
    run grub_sed_atomic "$GRUB" 's/quiet/loud/g'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN]"* ]]
    [ "$(cat "$GRUB")" = "$before" ]
}

@test "report mode is silent and makes no changes" {
    OPT_DRY_RUN=1
    OPT_REPORT=1
    local before
    before=$(cat "$GRUB")
    run grub_sed_atomic "$GRUB" 's/quiet/loud/g'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$GRUB")" = "$before" ]
}
