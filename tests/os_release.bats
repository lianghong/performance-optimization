#!/usr/bin/env bats
#
# Tests for the /etc/os-release parser (replaces the old `eval`-based
# approach in both scripts). We extract and execute just the parsing block
# against fixture files, then assert the expected variables are set.

parse_os_release() {
    local file=$1
    ID=""; VERSION_ID=""; PRETTY_NAME=""; NAME=""
    if [[ -f "$file" ]]; then
        while IFS='=' read -r _key _val; do
            _val="${_val%\"}"; _val="${_val#\"}"
            _val="${_val%\'}"; _val="${_val#\'}"
            case "${_key}" in
                ID) ID="${_val}" ;;
                VERSION_ID) VERSION_ID="${_val}" ;;
                PRETTY_NAME) PRETTY_NAME="${_val}" ;;
                NAME) NAME="${_val}" ;;
            esac
        done < <(grep -E '^(ID|VERSION_ID|PRETTY_NAME|NAME)=' "$file" 2>/dev/null)
        unset _key _val
    fi
}

setup() {
    FIXTURE="$(mktemp)"
}

teardown() {
    rm -f "$FIXTURE"
}

@test "parses Ubuntu 24.04 os-release" {
    cat >"$FIXTURE" <<'EOF'
PRETTY_NAME="Ubuntu 24.04 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
ID=ubuntu
HOME_URL="https://www.ubuntu.com/"
EOF
    parse_os_release "$FIXTURE"
    [ "$ID" = "ubuntu" ]
    [ "$VERSION_ID" = "24.04" ]
    [ "$NAME" = "Ubuntu" ]
    [ "$PRETTY_NAME" = "Ubuntu 24.04 LTS" ]
}

@test "parses RHEL os-release" {
    cat >"$FIXTURE" <<'EOF'
NAME="Red Hat Enterprise Linux"
VERSION="9.3 (Plow)"
ID="rhel"
VERSION_ID="9.3"
PRETTY_NAME="Red Hat Enterprise Linux 9.3 (Plow)"
EOF
    parse_os_release "$FIXTURE"
    [ "$ID" = "rhel" ]
    [ "$VERSION_ID" = "9.3" ]
    [ "$PRETTY_NAME" = "Red Hat Enterprise Linux 9.3 (Plow)" ]
}

@test "parses Amazon Linux 2023 os-release" {
    cat >"$FIXTURE" <<'EOF'
NAME="Amazon Linux"
VERSION="2023"
ID="amzn"
ID_LIKE="fedora"
VERSION_ID="2023"
PRETTY_NAME="Amazon Linux 2023"
EOF
    parse_os_release "$FIXTURE"
    [ "$ID" = "amzn" ]
    [ "$VERSION_ID" = "2023" ]
}

@test "handles unquoted values (Arch style)" {
    cat >"$FIXTURE" <<'EOF'
NAME="Arch Linux"
ID=arch
PRETTY_NAME="Arch Linux"
EOF
    parse_os_release "$FIXTURE"
    [ "$ID" = "arch" ]
    [ "$NAME" = "Arch Linux" ]
}

@test "does not execute injected shell code" {
    # An attacker who controls /etc/os-release content must not achieve RCE.
    # The grep whitelist + while-read parser should completely ignore the
    # attempted command substitution.
    cat >"$FIXTURE" <<'EOF'
ID="ubuntu"
MALICIOUS=$(touch /tmp/bats-injection-canary-$$)
EOF
    parse_os_release "$FIXTURE"
    [ "$ID" = "ubuntu" ]
    [ ! -e "/tmp/bats-injection-canary-$$" ]
}

@test "missing file leaves variables empty" {
    parse_os_release "/nonexistent/path"
    [ -z "$ID" ]
    [ -z "$VERSION_ID" ]
}
