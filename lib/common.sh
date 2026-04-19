#!/usr/bin/env bash
# lib/common.sh — shared helpers for system_optimize.sh and network_optimize.sh.
#
# This file is sourced, not executed. It defines only functions and constants
# (no top-level side effects) so either script can pull it in safely. Callers
# set OPT_DRY_RUN / OPT_REPORT / OPT_VERBOSE / BACKUP_DIR before invoking the
# helpers that reference them.
#
# Do not add --dry-run/--report/--verify mode switches that only one script
# uses; keep this library to logic that is genuinely identical across both.

# Re-sourcing guard: both scripts already set `set -euo pipefail`, so a
# double-source would redefine functions (fine) but would also repeat any
# readonly declarations (not fine). Guard with a sentinel.
if [[ -n "${_SYSOPT_COMMON_LOADED:-}" ]]; then
    return 0
fi
_SYSOPT_COMMON_LOADED=1

# Default the option flags so this library is sourceable during tests even
# when the caller has not parsed CLI args yet. Real callers overwrite them.
: "${OPT_DRY_RUN:=0}"
: "${OPT_REPORT:=0}"
: "${OPT_VERBOSE:=0}"
: "${BACKUP_DIR:=}"

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------
log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}
verbose() {
    [[ ${OPT_VERBOSE:-0} -eq 1 ]] && printf 'VERBOSE: %s\n' "$*" >&2 || true
}

#-------------------------------------------------------------------------------
# Input validation
#-------------------------------------------------------------------------------
validate_input() {
    local input=$1 pattern=$2 desc=$3
    if [[ ! "${input}" =~ ${pattern} ]]; then
        die "Invalid ${desc}: '${input}'"
    fi
}

validate_dir() {
    local path=$1 desc=$2
    if [[ ! -d "${path}" ]]; then
        die "${desc} does not exist or is not a directory: ${path}"
    fi
}

#-------------------------------------------------------------------------------
# Side-effect helpers — respect --dry-run / --report
#-------------------------------------------------------------------------------

# Run a command, or just print it under --dry-run. Silent under --report.
run() {
    if [[ ${OPT_DRY_RUN} -eq 1 ]]; then
        [[ ${OPT_REPORT} -eq 1 ]] && return 0
        printf '[DRY-RUN]'
        printf ' %s' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Like run, but swallow stdout/stderr in non-dry-run mode.
run_quiet() {
    if [[ ${OPT_DRY_RUN} -eq 1 ]]; then
        [[ ${OPT_REPORT} -eq 1 ]] && return 0
        printf '[DRY-RUN]'
        printf ' %s' "$@"
        printf '\n'
    else
        "$@" >/dev/null 2>&1
    fi
}

# Write a single value to procfs/sysfs. Returns 1 on write failure so callers
# can decide whether to complain; write_value_quiet suppresses the error.
write_value() {
    local path=$1 value=$2
    if [[ ${OPT_DRY_RUN} -eq 1 ]]; then
        [[ ${OPT_REPORT} -eq 1 ]] && return 0
        printf '[DRY-RUN] write %s <= %s\n' "${path}" "${value}"
        return 0
    fi
    if ! printf '%s\n' "${value}" >"${path}" 2>/dev/null; then
        verbose "Failed to write '${value}' to ${path}"
        return 1
    fi
    return 0
}

write_value_quiet() {
    write_value "$1" "$2" 2>/dev/null || true
}

# Write file content from stdin (respects --dry-run/--report).
write_file() {
    local path=$1
    if [[ ${OPT_DRY_RUN} -eq 1 ]]; then
        if [[ ${OPT_REPORT} -eq 1 ]]; then
            log ""
            log "================================================================================"
            log "RECOMMENDED FILE: ${path}"
            log "================================================================================"
            cat
            log ""
            return 0
        fi
        log "[DRY-RUN] write file: ${path}"
        cat >/dev/null
        return 0
    fi
    cat >"${path}"
}

# Append stdin to a file (respects --dry-run/--report).
append_file() {
    local path=$1
    if [[ ${OPT_DRY_RUN} -eq 1 ]]; then
        if [[ ${OPT_REPORT} -eq 1 ]]; then
            log ""
            log "================================================================================"
            log "RECOMMENDED APPEND: ${path}"
            log "================================================================================"
            cat
            log ""
            return 0
        fi
        log "[DRY-RUN] append file: ${path}"
        cat >/dev/null
        return 0
    fi
    cat >>"${path}"
}

#-------------------------------------------------------------------------------
# Verify helpers (--verify drift detection)
#-------------------------------------------------------------------------------
verify_sysctl() {
    local key=$1 expected=$2
    local actual
    actual=$(sysctl -n "${key}" 2>/dev/null) || actual="[not found]"
    expected=$(echo "${expected}" | xargs)
    actual=$(echo "${actual}" | xargs)
    if [[ "${actual}" == "${expected}" ]]; then
        printf '  ✓ %-45s = %s\n' "${key}" "${actual}"
        return 0
    else
        printf '  ✗ %-45s expected: %s\n' "${key}" "${expected}"
        printf '    %-45s     got: %s\n' "" "${actual}"
        return 1
    fi
}

verify_sysfs() {
    local path=$1 expected=$2
    if [[ ! -f "${path}" ]]; then
        printf '  - %-45s [not present]\n' "${path##*/sys/}"
        return 0  # Missing sysfs path is not a failure (hardware may differ)
    fi
    local actual
    actual=$(cat "${path}" 2>/dev/null) || actual="[unreadable]"
    if [[ "${actual}" == *"[${expected}]"* ]]; then
        printf '  ✓ %-45s = %s\n' "${path##*/sys/}" "${expected}"
        return 0
    elif [[ "${actual}" == "${expected}" ]]; then
        printf '  ✓ %-45s = %s\n' "${path##*/sys/}" "${actual}"
        return 0
    else
        printf '  ✗ %-45s expected: %s\n' "${path##*/sys/}" "${expected}"
        printf '    %-45s     got: %s\n' "" "${actual}"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Backup / restore — callers must define BACKUP_ROOT and BACKUP_PREFIX
#-------------------------------------------------------------------------------
latest_backup_dir() {
    local name
    name=$(find "${BACKUP_ROOT}" -maxdepth 1 -type d -name "${BACKUP_PREFIX}-*" -printf '%T@ %f\n' 2>/dev/null | sort -nr | head -n1 | awk '{print $2}')
    [[ -n "${name}" && -d "${BACKUP_ROOT}/${name}" ]] && echo "${BACKUP_ROOT}/${name}"
}

backup_file() {
    local path=$1
    [[ -z "${BACKUP_DIR}" ]] && return 0
    [[ -e "${path}" ]] || return 0
    local dest_dir
    dest_dir="${BACKUP_DIR}/files$(dirname "${path}")"
    run mkdir -p "${dest_dir}"
    run cp -a "${path}" "${dest_dir}/"
    log "  Backed up: ${path}"
}

restore_or_remove() {
    local path=$1 restore_dir=$2
    local backup_path=""
    [[ -n "${restore_dir}" ]] && backup_path="${restore_dir}/files${path}"

    if [[ -n "${backup_path}" && -f "${backup_path}" ]]; then
        log "  Restoring: ${path}"
        run mkdir -p "$(dirname "${path}")"
        run cp -a "${backup_path}" "${path}"
        return 0
    fi

    if [[ -e "${path}" ]]; then
        log "  Removing: ${path}"
        run rm -f "${path}"
        return 0
    fi
    return 1
}

#-------------------------------------------------------------------------------
# /etc/os-release parser (sets ID/VERSION_ID/NAME/PRETTY_NAME in caller scope)
#-------------------------------------------------------------------------------
parse_os_release() {
    local file=${1:-/etc/os-release}
    [[ -f "${file}" ]] || return 0
    local _key _val
    # shellcheck disable=SC2034  # ID/VERSION_ID/NAME/PRETTY_NAME set for caller
    while IFS='=' read -r _key _val; do
        _val="${_val%\"}"; _val="${_val#\"}"
        _val="${_val%\'}"; _val="${_val#\'}"
        case "${_key}" in
            ID) ID="${_val}" ;;
            VERSION_ID) VERSION_ID="${_val}" ;;
            PRETTY_NAME) PRETTY_NAME="${_val}" ;;
            NAME) NAME="${_val}" ;;
        esac
    done < <(grep -E '^(ID|VERSION_ID|PRETTY_NAME|NAME)=' "${file}" 2>/dev/null)
}
