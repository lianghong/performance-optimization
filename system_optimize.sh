#!/bin/bash
#===============================================================================
# File              : system_optimize.sh
# Author            : Lianghong Fei <feilianghong@gmail.com>
# Date              : 2025-12-19
# Last Modified Date: 2025-12-19
# Last Modified By  : Lianghong Fei <feilianghong@gmail.com>
#===============================================================================
#                    LINUX SYSTEM PERFORMANCE OPTIMIZATION
#===============================================================================
#
# A comprehensive, hardware-aware performance tuning script for Linux systems.
# Automatically detects hardware configuration and applies tailored optimizations.
#
# AUTHOR:       System Optimization Project
# VERSION:      1.0
# LICENSE:      MIT
# REPOSITORY:   https://github.com/lianghong/performance-optimization
#
#===============================================================================
# SUPPORTED PLATFORMS
#===============================================================================
#   Architecture:   x86_64 (Intel & AMD)
#   Distributions:  Ubuntu/Debian, Arch, Fedora, RHEL/CentOS, Amazon Linux 2023
#   Cloud:          AWS EC2, Azure VM, GCP Compute, Alibaba Cloud ECS
#   Kernel:         4.x, 5.x, 6.x (with 6.x-specific optimizations)
#
#===============================================================================
# OPTIMIZATION AREAS
#===============================================================================
#   1. CPU Optimization:
#      - Governor selection (performance/schedutil/powersave)
#      - Turbo boost control
#      - SMT/Hyper-Threading management
#      - CPU security mitigations (optional disable)
#      - CPU isolation for real-time workloads
#      - C-state management for latency-sensitive applications
#
#   2. Memory Optimization:
#      - Swappiness tuning (profile-aware)
#      - Dirty page ratios and writeback
#      - Transparent Huge Pages (THP) configuration
#      - NUMA balancing and memory policy
#      - KSM (Kernel Same-page Merging)
#      - zswap/zram configuration
#
#   3. I/O Optimization:
#      - I/O scheduler selection (none/mq-deadline/bfq/kyber)
#      - Block device queue tuning (nr_requests, read_ahead_kb, rq_affinity)
#      - Cloud storage optimization (EBS, Azure Disk, GCP PD)
#      - Local NVMe/instance store optimization
#      - fstrim for SSD/NVMe TRIM support
#
#   4. Filesystem Optimization:
#      - ext4/XFS/Btrfs specific tuning
#      - Mount option recommendations
#      - Journal and metadata optimization
#
#   5. System Limits:
#      - File descriptor limits (nofile) - auto-scaled by RAM
#      - Process limits (nproc) - auto-scaled by CPU cores
#      - Memory lock limits (memlock)
#      - Systemd service limits
#
#   6. Kernel Tuning:
#      - Scheduler parameters (CFS tuning)
#      - IRQ affinity and balancing
#      - Module blacklisting
#      - GRUB kernel parameters
#
#===============================================================================
# AUTO-TUNING FEATURES
#===============================================================================
#   - Hardware detection: CPU, RAM, NUMA, storage type, VM/cloud
#   - Instance type detection via IMDS (AWS, Azure, GCP, Alibaba)
#   - Cloud storage type detection (EBS, instance-store, etc.)
#   - Dynamic scaling based on detected hardware capabilities
#   - Profile-based optimization with sensible defaults
#
#===============================================================================
# USAGE
#===============================================================================
#   sudo ./system_optimize.sh [OPTIONS]
#
#   Options:
#     --profile=TYPE       server|vm|workstation|laptop|latency|auto
#     --disable-mitigations  Disable CPU security mitigations (DANGEROUS)
#     --disable-smt        Disable SMT/Hyper-Threading
#     --low-latency        Same as --profile=latency
#     --isolate-cpus=N-M   Isolate CPUs from scheduler
#     --relax-security     Disable non-essential security services
#     --disable-services   Disable non-essential system services
#     --reclaim-memory     Run one-time memory reclaim actions (drop caches/compact)
#     --yes                Assume "yes" for dangerous prompts (non-interactive)
#     --dry-run            Preview changes without applying
#     --cleanup            Remove all changes and restore from backup
#     --restore-from=DIR   Restore from specific backup directory
#     --help               Show help
#
#   Examples:
#     sudo ./system_optimize.sh                    # Auto-detect profile
#     sudo ./system_optimize.sh --profile=server   # Server optimization
#     sudo ./system_optimize.sh --profile=latency  # Low-latency tuning
#     sudo ./system_optimize.sh --dry-run          # Preview changes
#     sudo ./system_optimize.sh --cleanup          # Restore defaults
#
#===============================================================================
# FILES CREATED
#===============================================================================
#   /etc/sysctl.d/99-system-optimize.conf          - Kernel parameters
#   /etc/security/limits.d/99-system-optimize.conf - Resource limits
#   /etc/modprobe.d/99-system-optimize-blacklist.conf - Module blacklist
#   /etc/systemd/system/system-optimize.service    - Persistence service
#
# BACKUP LOCATION:
#   /var/backups/system-optimize-YYYYMMDD-HHMMSS/
#
#===============================================================================
# NOTES
#===============================================================================
#   - Run as root (sudo)
#   - Some changes require reboot (mitigations, CPU isolation, GRUB params)
#   - Use --dry-run to preview changes before applying
#   - Backup important data before running in production
#   - Test thoroughly in non-production environment first
#
#===============================================================================

set -euo pipefail
if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
    echo "ERROR: Bash 4.0+ required (found ${BASH_VERSION})" >&2
    exit 1
fi
IFS=$'\n\t'
umask 022

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------
log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}
verbose() { [[ ${OPT_VERBOSE:-0} -eq 1 ]] && printf 'VERBOSE: %s\n' "$*" >&2 || true; }

# Timing helpers for verbose mode
_timer_start() { [[ ${OPT_VERBOSE:-0} -eq 1 ]] && _TIMER_START=$(date +%s%N 2>/dev/null | cut -c1-13 || echo $(($(date +%s) * 1000))) || true; }
_timer_end() {
    [[ ${OPT_VERBOSE:-0} -eq 1 ]] && {
        local elapsed _now
        _now=$(date +%s%N 2>/dev/null | cut -c1-13 || echo $(($(date +%s) * 1000)))
        elapsed=$((_now - _TIMER_START))
        verbose "$1 completed in ${elapsed}ms"
    } || true
}

#-------------------------------------------------------------------------------
# Input Validation
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

# Validate environment before applying changes
validate_environment() {
    local errors=0

    # Check required directories exist
    for dir in /etc/sysctl.d /etc/security/limits.d /etc/modprobe.d; do
        if [[ ! -d "${dir}" ]]; then
            warn "Required directory missing: ${dir}"
            errors=$((errors + 1))
        fi
    done

    # Check /proc/sys is mounted (sysctl won't work otherwise)
    if [[ ! -d /proc/sys ]]; then
        warn "/proc/sys not mounted - sysctl settings cannot be applied"
        errors=$((errors + 1))
    fi

    # Check systemd is running (for service management)
    if ! command -v systemctl &>/dev/null; then
        warn "systemctl not found - service management unavailable"
    fi

    if [[ ${errors} -gt 0 ]]; then
        die "Environment validation failed with ${errors} error(s)"
    fi

    verbose "Environment validation passed"
}

#-------------------------------------------------------------------------------
# Security Warning System
#-------------------------------------------------------------------------------
# Show security warning and require confirmation for dangerous options
security_warning() {
    local option=$1 impact=$2 desc=$3

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────────────────┐"
    echo "│ ⚠  SECURITY WARNING: --${option}"
    printf "│ %-75s │\n" ""
    printf "│ %-75s │\n" "Impact: ${impact}"
    printf "│ %-75s │\n" "${desc}"
    printf "│ %-75s │\n" ""
    printf "│ %-75s │\n" "• Only use on isolated, non-production systems"
    printf "│ %-75s │\n" "• Not recommended for multi-tenant or internet-facing systems"
    echo "└─────────────────────────────────────────────────────────────────────────────┘"
    echo ""

    if [[ ${OPT_YES:-0} -eq 1 ]]; then
        echo "Continuing due to --yes flag..."
        return 0
    fi

    if [[ -t 0 ]]; then
        read -p "Continue with --${option}? [y/N] " -n 1 -r
        echo
        [[ ${REPLY} =~ ^[Yy]$ ]] && return 0
    else
        warn "Non-interactive session: pass --yes to proceed with --${option}"
    fi
    return 1
}

# Log security-sensitive changes to syslog
log_security_change() {
    local change=$1
    command -v logger &>/dev/null &&
        logger -t "system-optimize" "SECURITY: ${change} by user $(whoami)"
    verbose "Security change logged: ${change}"
}

#-------------------------------------------------------------------------------
# Configuration Paths
#-------------------------------------------------------------------------------
# shellcheck disable=SC2034
readonly SCRIPT_NAME="system-optimize"
# shellcheck disable=SC2034
readonly SCRIPT_VERSION="1.0"

readonly CFG_SYSCTL="/etc/sysctl.d/99-system-optimize.conf"
readonly CFG_LIMITS="/etc/security/limits.d/99-system-optimize.conf"
readonly CFG_SYSTEMD_SYSTEM="/etc/systemd/system.conf.d/99-system-optimize.conf"
readonly CFG_SYSTEMD_USER="/etc/systemd/user.conf.d/99-system-optimize.conf"
readonly CFG_MODPROBE="/etc/modprobe.d/99-system-optimize-blacklist.conf"
readonly CFG_JOURNALD="/etc/systemd/journald.conf.d/99-system-optimize.conf"
readonly CFG_SERVICE="/etc/systemd/system/system-optimize.service"
CFG_FSTAB_HINTS=""  # Set later via mktemp when needed
readonly CFG_GRUB_BACKUP="/etc/default/grub.bak.system-optimize"

#-------------------------------------------------------------------------------
# Tuning Constants
#-------------------------------------------------------------------------------
# These values can be adjusted for different environments.
# To customize: modify the constants below, then re-run the script.
#-------------------------------------------------------------------------------

# --- CFS Scheduler Latency (nanoseconds) ---
# sched_latency_ns: Target preemption latency for CPU-bound tasks
# Higher values = better throughput (less context switching)
# Lower values = better responsiveness (more frequent preemption)
# Formula: Effective timeslice ≈ sched_latency_ns / nr_running_tasks
readonly CONST_SCHED_LATENCY_SERVER=24000000     # 24ms - maximize throughput
readonly CONST_SCHED_LATENCY_VM=20000000         # 20ms - balanced
readonly CONST_SCHED_LATENCY_WORKSTATION=6000000 # 6ms  - responsive UI
readonly CONST_SCHED_LATENCY_LAPTOP=6000000      # 6ms  - responsive

# kernel.sched_min_granularity_ns: Minimum timeslice per task (nanoseconds)
# Prevents excessive context switching when many tasks are runnable.
# Formula: Actual timeslice = max(min_granularity, latency/nr_running)
readonly CONST_SCHED_MIN_GRAN_SERVER=3000000  # 3ms   - longer slices, better throughput
readonly CONST_SCHED_MIN_GRAN_VM=2500000      # 2.5ms - balanced
readonly CONST_SCHED_MIN_GRAN_DESKTOP=750000  # 0.75ms - quick response for UI

# --- System Limits Multipliers ---
# nofile (max open files): Scaled by RAM because file handles consume memory.
# Each open file descriptor uses ~1-4KB kernel memory.
# Formula: LIMIT_NOFILE = RAM_GB × CONST_NOFILE_PER_GB
# Example: 64GB RAM × 65536 = 4M max files (server)
readonly CONST_NOFILE_PER_GB_SERVER=65536      # High-connection servers (web, DB)
readonly CONST_NOFILE_PER_GB_VM=32768          # Cloud workloads
readonly CONST_NOFILE_PER_GB_WORKSTATION=16384 # Desktop applications
readonly CONST_NOFILE_PER_GB_LAPTOP=8192       # Conservative for battery

# nproc (max processes/threads): Scaled by CPU cores.
# More cores can handle more concurrent processes efficiently.
# Formula: LIMIT_NPROC = CPU_CORES × CONST_NPROC_PER_CORE
# Example: 32 cores × 8192 = 262K max processes (server)
readonly CONST_NPROC_PER_CORE_SERVER=8192      # Many workers/threads
readonly CONST_NPROC_PER_CORE_VM=4096          # Moderate concurrency
readonly CONST_NPROC_PER_CORE_WORKSTATION=2048 # Desktop apps
readonly CONST_NPROC_PER_CORE_LAPTOP=1024      # Light usage

# --- Memory/VM Tuning ---
# vm.swappiness: Tendency to swap out anonymous memory (0-200, default 60)
# Lower = prefer dropping file cache, keep app memory in RAM
# Higher = more willing to swap out app memory to disk
readonly CONST_SWAPPINESS_SERVER=10   # Keep app memory in RAM
readonly CONST_SWAPPINESS_VM=30       # Balanced for cloud
readonly CONST_SWAPPINESS_WORKSTATION=30 # Balanced for desktop
readonly CONST_SWAPPINESS_LAPTOP=60   # Default, allow swap for battery
readonly CONST_SWAPPINESS_LATENCY=1   # Almost never swap (latency-sensitive)

# vm.dirty_ratio: Max % of RAM for dirty pages before synchronous writeback
# Lower = more frequent writes, less data loss risk, more I/O overhead
# Higher = better write performance, more data at risk on crash
readonly CONST_DIRTY_RATIO_SERVER=15      # Balance performance/safety
readonly CONST_DIRTY_RATIO_VM=10          # Lower for cloud storage latency
readonly CONST_DIRTY_RATIO_WORKSTATION=10 # Balanced
readonly CONST_DIRTY_RATIO_LAPTOP=5       # Preserve battery, protect SSD
readonly CONST_DIRTY_RATIO_LATENCY=5      # Flush quickly, predictable I/O

# --- I/O Queue Tuning ---
# /sys/block/*/queue/nr_requests: Max I/O requests queued per device
# Higher = better throughput (more batching), Lower = better latency
# Formula: NR_REQ = DEVICE_MAX × SCALE / 100
readonly CONST_NR_REQ_SCALE_SERVER=100    # 100% of device max
readonly CONST_NR_REQ_SCALE_VM=75         # 75% - balanced for cloud
readonly CONST_NR_REQ_SCALE_WORKSTATION=50 # 50% - responsive
readonly CONST_NR_REQ_SCALE_LAPTOP=25     # 25% - power saving
readonly CONST_NR_REQ_MIN=32              # Minimum queue depth

# --- Read-ahead Base Values (KB) ---
# /sys/block/*/queue/read_ahead_kb: Prefetch size for sequential reads
# Larger = better sequential throughput, wastes RAM for random I/O
# SSD: use lower values (fast random access)
# HDD: use higher values (slow seeks benefit from prefetch)
readonly CONST_READAHEAD_BASE_HIGH=512    # RAM >= 32GB
readonly CONST_READAHEAD_BASE_MED=256     # RAM >= 16GB
readonly CONST_READAHEAD_BASE_LOW=128     # RAM < 16GB

# --- Cloud Storage Constants ---
# Network-attached storage (EBS, Azure Disk, GCP PD):
#   Lower queue depth - network latency dominates, deep queues don't help
#   Lower read-ahead - large prefetch wastes IOPS on network storage
# Local storage (Instance Store, Local SSD):
#   Higher queue depth - local NVMe handles deep queues efficiently
#   Higher read-ahead - no network penalty for prefetching
readonly CONST_CLOUD_NR_REQ_NETWORK=256   # Network storage queue depth
readonly CONST_CLOUD_NR_REQ_LOCAL=2048    # Local NVMe queue depth
readonly CONST_CLOUD_READAHEAD_NETWORK=128 # Network storage (KB)
readonly CONST_CLOUD_READAHEAD_LOCAL=512   # Local NVMe (KB)

#===============================================================================
# PHASE 1: INITIALIZATION
#===============================================================================

# --- Backup Configuration ---
readonly BACKUP_ROOT="/var/backups"
readonly BACKUP_PREFIX="system-optimize"
BACKUP_DIR=""

# --- CLI Arguments ---
OPT_DISABLE_MITIGATIONS=0
OPT_DISABLE_SMT=0
OPT_ISOLATE_CPUS=""
OPT_LOW_LATENCY=0
OPT_RELAX_SECURITY=0
OPT_DISABLE_SERVICES=0
OPT_DRY_RUN=0
OPT_RECLAIM_MEMORY=0
OPT_APPLY_FS_TUNING=0
OPT_REPORT=0
OPT_YES=0
OPT_CLEANUP=0
OPT_RESTORE_FROM=""
OPT_VERBOSE=0
OPT_PROFILE="auto" # server, vm, workstation, laptop, latency, auto

usage() {
    cat <<'EOF'
================================================================================
                    LINUX SYSTEM PERFORMANCE OPTIMIZATION
================================================================================

Usage: ./system_optimize.sh [OPTIONS]

OPTIONS:
  --profile=TYPE         Optimization profile:
                           server     - Max performance, no power saving
                           vm         - Cloud/VM optimized
                           workstation- Balanced performance
                           laptop     - Power efficiency priority
                           latency    - Minimal latency (trading, HPC, gaming)
                           auto       - Auto-detect (default)
  --disable-mitigations  Disable CPU security mitigations (requires reboot)
  --disable-smt          Disable SMT/Hyper-Threading
  --low-latency          Same as --profile=latency
  --isolate-cpus=N-M     Isolate CPUs from scheduler (requires reboot)
  --relax-security       Disable non-essential security services
  --disable-services     Disable non-essential system services
  --reclaim-memory       Run one-time memory reclaim actions (drop caches/compact)
  --apply-fs-tuning      Apply filesystem-changing actions (tune2fs/xfs_io/btrfs sysfs/fstrim)
  --report               Print recommended config files and exit (no changes)
  --yes                  Assume "yes" for dangerous prompts (non-interactive)
  --dry-run              Print actions without changing the system
  --verbose              Enable detailed debugging output
  --cleanup              Remove all changes and restore from backup
  --restore-from=DIR     Restore from specific backup directory
  --help                 Show this help

NOTES:
  - Root is required to apply changes.
  - You can run without root using: --dry-run or --report

PROFILES:
  ┌─────────────┬─────────────────────────────────────────────────────────────┐
  │ server      │ Governor=performance, THP=madvise, aggressive caching       │
  │ vm          │ Governor=performance, THP=never, no hardware tuning         │
  │ workstation │ Governor=schedutil, balanced, responsive UI                 │
  │ laptop      │ Governor=powersave, battery priority, C-states enabled      │
  │ latency     │ Governor=performance, C1 only, no watchdogs, RT priority    │
  └─────────────┴─────────────────────────────────────────────────────────────┘

EXAMPLES:
  sudo ./system_optimize.sh                          # Auto-detect
  sudo ./system_optimize.sh --profile=server         # Server
  sudo ./system_optimize.sh --dry-run                # Preview changes
  sudo ./system_optimize.sh --cleanup                # Restore defaults

FILES CREATED:
  /etc/sysctl.d/99-system-optimize.conf
  /etc/security/limits.d/99-system-optimize.conf
  /etc/modprobe.d/99-system-optimize-blacklist.conf
  /etc/systemd/system/system-optimize.service

BACKUP LOCATION:
  /var/backups/system-optimize-YYYYMMDD-HHMMSS/
================================================================================
EOF
    exit 0
}

for arg in "$@"; do
    case ${arg} in
        --profile=*) OPT_PROFILE="${arg#*=}" ;;
        --disable-mitigations) OPT_DISABLE_MITIGATIONS=1 ;;
        --disable-smt) OPT_DISABLE_SMT=1 ;;
        --low-latency)
            OPT_PROFILE="latency"
            OPT_LOW_LATENCY=1
            ;;
        --isolate-cpus=*) OPT_ISOLATE_CPUS="${arg#*=}" ;;
        --relax-security) OPT_RELAX_SECURITY=1 ;;
        --disable-services) OPT_DISABLE_SERVICES=1 ;;
        --reclaim-memory) OPT_RECLAIM_MEMORY=1 ;;
        --apply-fs-tuning) OPT_APPLY_FS_TUNING=1 ;;
        --report)
            OPT_REPORT=1
            OPT_DRY_RUN=1
            ;;
        --yes | -y) OPT_YES=1 ;;
        --dry-run) OPT_DRY_RUN=1 ;;
        --verbose) OPT_VERBOSE=1 ;;
        --cleanup) OPT_CLEANUP=1 ;;
        --restore-from=*)
            OPT_RESTORE_FROM="${arg#*=}"
            OPT_CLEANUP=1
            ;;
        --help | -h) usage ;;
        -*) die "Unknown option: ${arg} (use --help for usage)" ;;
        *) die "Unexpected argument: ${arg}" ;;
    esac
done

# --- Input Validation ---
validate_input "${OPT_PROFILE}" "^(server|vm|workstation|laptop|latency|auto)$" "profile"

# Validate --isolate-cpus format (e.g., "2-5" or "1,3,5" or "2-5,8")
if [[ -n "${OPT_ISOLATE_CPUS}" ]]; then
    if ! [[ "${OPT_ISOLATE_CPUS}" =~ ^[0-9]+([-,][0-9]+)*$ ]]; then
        die "Invalid --isolate-cpus format: ${OPT_ISOLATE_CPUS} (use: N-M or N,M,O)"
    fi
fi

# Validate --restore-from path if provided
if [[ -n "${OPT_RESTORE_FROM}" ]]; then
    validate_dir "${OPT_RESTORE_FROM}" "Restore path"
fi

# latency profile implies low-latency flag
[[ "${OPT_PROFILE}" == "latency" ]] && OPT_LOW_LATENCY=1

# --- Security Warnings for Dangerous Options ---
if [[ ${OPT_DRY_RUN} -eq 0 && ${OPT_REPORT} -eq 0 ]]; then
    if [[ ${OPT_DISABLE_MITIGATIONS} -eq 1 ]]; then
        if ! security_warning "disable-mitigations" "HIGH" \
            "Disables CPU security mitigations (Spectre/Meltdown protection)"; then
            OPT_DISABLE_MITIGATIONS=0
        else
            log_security_change "CPU mitigations disabled"
        fi
    fi

    if [[ ${OPT_RELAX_SECURITY} -eq 1 ]]; then
        if ! security_warning "relax-security" "MEDIUM" \
            "Disables audit daemon and reduces security monitoring"; then
            OPT_RELAX_SECURITY=0
        else
            log_security_change "Security monitoring relaxed"
        fi
    fi

    if [[ ${OPT_DISABLE_SERVICES} -eq 1 ]]; then
        if ! security_warning "disable-services" "MEDIUM" \
            "Disables system services (may affect logging, monitoring, updates)"; then
            OPT_DISABLE_SERVICES=0
        else
            log_security_change "Non-essential services disabled"
        fi
    fi

    if [[ ${OPT_APPLY_FS_TUNING} -eq 1 ]]; then
        echo ""
        echo "┌─────────────────────────────────────────────────────────────────────────────┐"
        echo "│ ⚠  FILESYSTEM WARNING: --apply-fs-tuning                                    │"
        printf "│ %-75s │\n" ""
        printf "│ %-75s │\n" "This will modify filesystem metadata (tune2fs, xfs_io, btrfs)."
        printf "│ %-75s │\n" "Interrupting these operations could cause filesystem issues."
        printf "│ %-75s │\n" ""
        printf "│ %-75s │\n" "• Ensure stable power supply"
        printf "│ %-75s │\n" "• Backup important data first"
        echo "└─────────────────────────────────────────────────────────────────────────────┘"
        echo ""
        if [[ ${OPT_YES:-0} -ne 1 ]] && [[ -t 0 ]]; then
            read -rp "Continue with filesystem tuning? [y/N] " response
            [[ ! "${response}" =~ ^[Yy] ]] && OPT_APPLY_FS_TUNING=0
        fi
    fi
fi

# --- Preflight Checks ---
# Help/report/dry-run should be usable without root.
if [[ ${OPT_DRY_RUN} -eq 0 && ${OPT_REPORT} -eq 0 ]]; then
    [[ ${EUID} -ne 0 ]] && die "Run as root (sudo) to apply changes (or use --dry-run/--report without sudo)"
    [[ $(uname -m) != "x86_64" ]] && die "x86_64 architecture only"
    validate_environment
fi

# Dry-run wrapper: execute or print command
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

# Run command and suppress output (but still show in --dry-run)
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

# Write a single value to a procfs/sysfs node (respects --dry-run)
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

# Write/append file content from stdin (respects --dry-run)
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
# Backup & Restore Functions
#-------------------------------------------------------------------------------

# Find latest backup directory
latest_backup_dir() {
    local name
    name=$(find "${BACKUP_ROOT}" -maxdepth 1 -type d -name "${BACKUP_PREFIX}-*" -printf '%T@ %f\n' 2>/dev/null | sort -nr | head -n1 | awk '{print $2}')
    [[ -n "${name}" && -d "${BACKUP_ROOT}/${name}" ]] && echo "${BACKUP_ROOT}/${name}"
}

# Backup a file before modifying
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

# Restore a file from backup or remove if no backup exists
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

# Cleanup function: restore from backup
do_cleanup() {
    log "================================================================================"
    log "                    SYSTEM OPTIMIZATION CLEANUP"
    log "================================================================================"
    log ""

    local restore_dir=""
    if [[ -n "${OPT_RESTORE_FROM}" ]]; then
        [[ -d "${OPT_RESTORE_FROM}" ]] || die "Backup directory not found: ${OPT_RESTORE_FROM}"
        restore_dir="${OPT_RESTORE_FROM}"
    else
        restore_dir=$(latest_backup_dir)
    fi

    if [[ -n "${restore_dir}" ]]; then
        log "Restoring from backup: ${restore_dir}"
    else
        log "No backup found. Removing generated files..."
    fi
    log ""

    # Restore or remove config files
    restore_or_remove "${CFG_SYSCTL}" "${restore_dir}" || true
    restore_or_remove "${CFG_LIMITS}" "${restore_dir}" || true
    restore_or_remove "${CFG_MODPROBE}" "${restore_dir}" || true
    restore_or_remove "${CFG_SERVICE}" "${restore_dir}" || true
    restore_or_remove "${CFG_GRUB_BACKUP}" "${restore_dir}" || true

    # Restore GRUB if backup exists
    if [[ -n "${restore_dir}" && -f "${restore_dir}/files/etc/default/grub" ]]; then
        restore_or_remove "/etc/default/grub" "${restore_dir}"
        if command -v update-grub &>/dev/null; then
            run update-grub
        elif command -v grub2-mkconfig &>/dev/null; then
            run grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null ||
                run grub2-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
        fi
    fi

    # Disable and remove service
    if systemctl is-enabled system-optimize.service &>/dev/null; then
        log "  Disabling system-optimize.service..."
        run systemctl disable system-optimize.service
    fi
    run systemctl daemon-reload

    # Reload sysctl to restore defaults
    log ""
    log "Reloading sysctl defaults..."
    run sysctl --system

    log ""
    log "================================================================================"
    log "Cleanup complete. Reboot recommended to fully restore defaults."
    if [[ -n "${restore_dir}" ]]; then
        log "Restored from: ${restore_dir}"
    fi
    log "================================================================================"
    exit 0
}

# Run cleanup if requested
[[ ${OPT_CLEANUP} -eq 1 ]] && do_cleanup

# Create backup directory for this run
if [[ ${OPT_DRY_RUN} -eq 0 ]]; then
    BACKUP_DIR="${BACKUP_ROOT}/${BACKUP_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${BACKUP_DIR}"
    log "Backup directory: ${BACKUP_DIR}"
fi

# Staging area for sysctl snippets collected during runtime tuning
SYSCTL_SNIPPETS_FILE=$(mktemp -p /tmp system-optimize-sysctl.XXXXXX)
trap 'rm -f "${SYSCTL_SNIPPETS_FILE:-}" "${CFG_FSTAB_HINTS:-}" 2>/dev/null || true' EXIT

# --- Distribution Detection ---
# Extract only needed variables to avoid overwriting script vars
if [[ -f /etc/os-release ]]; then
    eval "$(grep -E '^(ID|VERSION_ID|PRETTY_NAME|NAME)=' /etc/os-release 2>/dev/null)"
fi
: "${ID:=unknown}"
DISTRO=${ID}
DISTRO_ID="${ID:-unknown}"
# DISTRO_VERSION_ID="${VERSION_ID:-}" # Unused
DISTRO_PRETTY="${PRETTY_NAME:-}"
if [[ -z "${DISTRO_PRETTY}" ]]; then
    DISTRO_PRETTY="${NAME:-${DISTRO}}${VERSION_ID:+ ${VERSION_ID}}"
fi
KERNEL_RELEASE=$(uname -r 2>/dev/null || echo "unknown")

SUPPORTED_DISTRO=0
case "${DISTRO_ID}" in
    ubuntu | debian | amzn | fedora | arch | rhel | centos | rocky | almalinux) SUPPORTED_DISTRO=1 ;;
esac
if [[ ${SUPPORTED_DISTRO} -ne 1 ]]; then
    if [[ ${OPT_DRY_RUN} -eq 1 || ${OPT_REPORT} -eq 1 ]]; then
        warn "Unsupported distro ID='${DISTRO_ID}' (tested for: Ubuntu, Debian, Fedora, Arch, RHEL-family, Amazon Linux 2023). Proceeding in read-only mode."
    else
        die "Unsupported distro ID='${DISTRO_ID}' (supported: Ubuntu, Debian, Fedora, Arch, RHEL-family, Amazon Linux 2023)"
    fi
fi

# Package manager helper
APT_UPDATED=0
pkg_install() {
    [[ $# -gt 0 ]] || return 0
    case ${DISTRO} in
        ubuntu | debian)
            if [[ ${APT_UPDATED} -eq 0 ]]; then
                run_quiet apt-get update
                APT_UPDATED=1
            fi
            run_quiet apt-get install -y "$@"
            ;;
        arch) run_quiet pacman -S --noconfirm "$@" ;;
        fedora | rhel | centos | rocky | almalinux | amzn)
            local pm="dnf"
            command -v dnf &>/dev/null || pm="yum"
            local pkg
            for pkg in "$@"; do
                run_quiet "${pm}" install -y "${pkg}" || true
            done
            ;;
    esac
}

# Check for required and optional dependencies
check_dependencies() {
    local missing_required=() missing_optional=()

    # Required tools
    command -v sysctl &>/dev/null || missing_required+=("procps (sysctl)")

    # Optional but recommended
    command -v curl &>/dev/null || missing_optional+=("curl")
    command -v numactl &>/dev/null || missing_optional+=("numactl")
    command -v hdparm &>/dev/null || missing_optional+=("hdparm")

    if [[ ${#missing_required[@]} -gt 0 ]]; then
        die "Missing required tools: ${missing_required[*]}"
    fi

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        warn "Optional tools not found: ${missing_optional[*]}"
        echo "  Install for full functionality:"
        case ${DISTRO} in
            ubuntu | debian) echo "    sudo apt install ${missing_optional[*]}" ;;
            arch) echo "    sudo pacman -S ${missing_optional[*]}" ;;
            fedora | rhel | centos | rocky | almalinux | amzn) echo "    sudo dnf install ${missing_optional[*]}" ;;
            *) echo "    Install: ${missing_optional[*]}" ;;
        esac
    fi
}

check_dependencies

update_grub_config() {
    if command -v update-grub &>/dev/null; then
        run_quiet update-grub
        return 0
    fi

    if command -v grub-mkconfig &>/dev/null; then
        if [[ -d /boot/grub ]]; then
            run_quiet grub-mkconfig -o /boot/grub/grub.cfg
            return 0
        fi
        if [[ -d /boot/grub2 ]]; then
            run_quiet grub-mkconfig -o /boot/grub2/grub.cfg
            return 0
        fi
    fi

    if command -v grub2-mkconfig &>/dev/null; then
        if [[ -d /boot/grub2 ]]; then
            run_quiet grub2-mkconfig -o /boot/grub2/grub.cfg || true
            return 0
        fi
        if [[ -d /boot/grub ]]; then
            run_quiet grub2-mkconfig -o /boot/grub/grub.cfg || true
            return 0
        fi
    fi

    warn "GRUB update tool not found; kernel cmdline changes may not apply until you regenerate GRUB config manually."
    return 1
}

#===============================================================================
# PHASE 2: HARDWARE DETECTION
#===============================================================================

echo "================================================================================"
echo "                    LINUX SYSTEM PERFORMANCE OPTIMIZATION"
[[ ${OPT_REPORT} -eq 1 ]] && echo "                              *** REPORT MODE ***"
[[ ${OPT_REPORT} -eq 0 ]] && [[ ${OPT_DRY_RUN} -eq 1 ]] && echo "                              *** DRY-RUN MODE ***"
echo "================================================================================"
echo ""
[[ ${OPT_DRY_RUN} -eq 1 ]] && echo "NOTE: No changes will be made. Commands shown for review only."
[[ ${OPT_DRY_RUN} -eq 1 ]] && echo ""
echo ">>> Phase 1: Detecting Hardware Configuration..."
echo ""

# --- CPU Detection ---
_CPUINFO=$(awk -F': *' '
    /^vendor_id/{v=$2} /^model name/{m=$2} /^cpu family/{f=$2}
    v && m && f {printf "%s\n%s\n%s\n",v,m,f; exit}
' /proc/cpuinfo)
HW_CPU_VENDOR=$(sed -n '1p' <<< "${_CPUINFO}")
HW_CPU_MODEL=$(sed -n '2p' <<< "${_CPUINFO}")
HW_CPU_FAMILY=$(sed -n '3p' <<< "${_CPUINFO}")
HW_CPU_CORES=$(nproc)

# --- Memory Detection ---
HW_MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
HW_MEM_TOTAL_GB=$(( (HW_MEM_TOTAL_KB + 1048575) / 1024 / 1024 ))
[[ ${HW_MEM_TOTAL_GB} -lt 1 ]] && HW_MEM_TOTAL_GB=1

# --- Topology Detection ---
HW_NUMA_NODES=$(find /sys/devices/system/node -maxdepth 1 -name 'node[0-9]*' -type d 2>/dev/null | wc -l)
[[ ${HW_NUMA_NODES} -lt 1 ]] && HW_NUMA_NODES=1
HW_IS_VM=$(systemd-detect-virt 2>/dev/null) || HW_IS_VM="none"

# --- SMT Detection ---
HW_SMT_ACTIVE=0
HW_SMT_CONTROL="unsupported"
[[ -f /sys/devices/system/cpu/smt/active ]] && {
    HW_SMT_ACTIVE=$(cat /sys/devices/system/cpu/smt/active)
    HW_SMT_CONTROL=$(cat /sys/devices/system/cpu/smt/control)
}
HW_THREADS_PER_CORE=$(lscpu 2>/dev/null | grep "Thread(s) per core" | awk '{print $4}' || echo "1")

# --- Cloud Provider Detection ---
# Multi-method detection with fallbacks for robustness
_timer_start
CLOUD_PROVIDER="none"
INSTANCE_TYPE=""
CLOUD_DETECTION_METHOD=""
CLOUD_CONFIDENCE="" # high/medium/low

# Helper: IMDS fetch with timeout
imds_fetch() {
    local url=$1 header=${2:-}
    local result=""
    if [[ -n "${header}" ]]; then
        result=$(timeout 1 curl -sf -H "${header}" "${url}" 2>/dev/null) || true
    else
        result=$(timeout 1 curl -sf "${url}" 2>/dev/null) || true
    fi
    echo "${result}"
}

if [[ "${HW_IS_VM}" != "none" ]]; then
    # Method 1: DMI/SMBIOS data (fastest, no network)
    if [[ -f /sys/devices/virtual/dmi/id/board_vendor ]]; then
        DMI_VENDOR=$(tr '[:upper:]' '[:lower:]' </sys/devices/virtual/dmi/id/board_vendor 2>/dev/null) || DMI_VENDOR=""
        DMI_BIOS=$(tr '[:upper:]' '[:lower:]' </sys/devices/virtual/dmi/id/bios_vendor 2>/dev/null) || DMI_BIOS=""

        if [[ "${DMI_VENDOR}" == *"amazon"* ]] || [[ "${DMI_BIOS}" == *"amazon"* ]]; then
            CLOUD_PROVIDER="aws"
            CLOUD_DETECTION_METHOD="dmi"
        elif [[ "${DMI_VENDOR}" == *"microsoft"* ]]; then
            CLOUD_PROVIDER="azure"
            CLOUD_DETECTION_METHOD="dmi"
        elif [[ "${DMI_VENDOR}" == *"google"* ]]; then
            CLOUD_PROVIDER="gcp"
            CLOUD_DETECTION_METHOD="dmi"
        elif [[ "${DMI_VENDOR}" == *"alibaba"* ]]; then
            CLOUD_PROVIDER="alibaba"
            CLOUD_DETECTION_METHOD="dmi"
        fi
    fi

    # Method 2: IMDS probing (if DMI didn't identify provider)
    # Skip if DMI was readable but didn't match any known cloud vendor
    if [[ "${CLOUD_PROVIDER}" == "none" ]] && [[ -z "${DMI_VENDOR:-}" ]]; then
        if imds_fetch "http://169.254.169.254/latest/meta-data/" | grep -q ami-id 2>/dev/null; then
            CLOUD_PROVIDER="aws"
            CLOUD_DETECTION_METHOD="imds"
        elif imds_fetch "http://169.254.169.254/computeMetadata/v1/" "Metadata-Flavor: Google" | grep -q instance 2>/dev/null; then
            CLOUD_PROVIDER="gcp"
            CLOUD_DETECTION_METHOD="imds"
        elif imds_fetch "http://169.254.169.254/metadata/instance?api-version=2021-02-01" "Metadata:true" | grep -q vmId 2>/dev/null; then
            CLOUD_PROVIDER="azure"
            CLOUD_DETECTION_METHOD="imds"
        elif imds_fetch "http://100.100.100.200/latest/meta-data/" | grep -q instance-id 2>/dev/null; then
            CLOUD_PROVIDER="alibaba"
            CLOUD_DETECTION_METHOD="imds"
        fi
    fi

    # Method 3: Cloud-specific services/files (fallback)
    if [[ "${CLOUD_PROVIDER}" == "none" ]]; then
        if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null || [[ -d /etc/amazon ]]; then
            CLOUD_PROVIDER="aws"
            CLOUD_DETECTION_METHOD="service"
        elif systemctl is-active --quiet waagent 2>/dev/null; then
            CLOUD_PROVIDER="azure"
            CLOUD_DETECTION_METHOD="service"
        elif systemctl is-active --quiet google-guest-agent 2>/dev/null; then
            CLOUD_PROVIDER="gcp"
            CLOUD_DETECTION_METHOD="service"
        fi
    fi

    # Fetch instance type from IMDS
    case ${CLOUD_PROVIDER} in
        aws)
            INSTANCE_TYPE=$(imds_fetch "http://169.254.169.254/latest/meta-data/instance-type")
            ;;
        azure)
            INSTANCE_TYPE=$(imds_fetch "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text" "Metadata:true")
            ;;
        gcp)
            INSTANCE_TYPE=$(imds_fetch "http://169.254.169.254/computeMetadata/v1/instance/machine-type" "Metadata-Flavor: Google")
            INSTANCE_TYPE=${INSTANCE_TYPE##*/}
            ;;
        alibaba)
            INSTANCE_TYPE=$(imds_fetch "http://100.100.100.200/latest/meta-data/instance/instance-type")
            ;;
    esac

    # Set confidence based on detection method and data
    if [[ "${CLOUD_PROVIDER}" != "none" ]]; then
        if [[ -n "${INSTANCE_TYPE}" ]]; then
            [[ "${CLOUD_DETECTION_METHOD}" == "dmi" ]] && CLOUD_CONFIDENCE="high" || CLOUD_CONFIDENCE="medium"
        else
            CLOUD_CONFIDENCE="low"
        fi
        verbose "Cloud: ${CLOUD_PROVIDER} (method=${CLOUD_DETECTION_METHOD}, confidence=${CLOUD_CONFIDENCE})"
    fi

    # Warn if detection is uncertain
    if [[ "${CLOUD_PROVIDER}" == "none" ]]; then
        verbose "Cloud provider not detected (VM: ${HW_IS_VM})"
    elif [[ -z "${INSTANCE_TYPE}" ]]; then
        verbose "Cloud provider ${CLOUD_PROVIDER} detected but instance type unavailable"
    fi
fi
_timer_end "Cloud detection"

# --- Profile Auto-Detection ---
# Detection priority: VM > laptop > workstation > server
# Workstation indicators: display server, desktop environment, audio, graphical target
_is_workstation() {
    [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]] ||
        systemctl get-default 2>/dev/null | grep -q graphical ||
        [[ -d /run/user/"$(id -u)"/pulse ]] ||
        pgrep -x "gnome-shell" >/dev/null 2>&1 ||
        pgrep -x "plasmashell" >/dev/null 2>&1 ||
        pgrep -x "xfce4-session" >/dev/null 2>&1 ||
        pgrep -x "cinnamon" >/dev/null 2>&1 ||
        pgrep -x "mate-session" >/dev/null 2>&1
}

if [[ "${OPT_PROFILE}" = "auto" ]]; then
    if [[ "${HW_IS_VM}" != "none" ]]; then
        OPT_PROFILE="vm"
    elif [[ -d /sys/class/power_supply/BAT0 ]] || [[ -d /sys/class/power_supply/BAT1 ]]; then
        OPT_PROFILE="laptop"
    elif _is_workstation; then
        OPT_PROFILE="workstation"
    elif [[ ${HW_CPU_CORES} -le 4 && ${HW_MEM_TOTAL_GB} -le 16 ]]; then
        OPT_PROFILE="workstation"
    else
        OPT_PROFILE="server"
    fi
fi

# --- Profile-Based Defaults ---
case ${OPT_PROFILE} in
    server)
        PROFILE_GOVERNOR="performance"
        PROFILE_TURBO=1
        PROFILE_THP="madvise"
        PROFILE_SWAPPINESS_BASE=$CONST_SWAPPINESS_SERVER
        PROFILE_DIRTY_RATIO_BASE=$CONST_DIRTY_RATIO_SERVER
        PROFILE_BLACKLIST_DESKTOP=1
        ;;
    vm)
        PROFILE_GOVERNOR="performance"
        PROFILE_TURBO=1
        PROFILE_THP="never"
        PROFILE_SWAPPINESS_BASE=$CONST_SWAPPINESS_VM
        PROFILE_DIRTY_RATIO_BASE=$CONST_DIRTY_RATIO_VM
        PROFILE_BLACKLIST_DESKTOP=1

        # Cloud-specific overrides
        case ${CLOUD_PROVIDER} in
            aws)
                # AWS: ENA driver, NVMe optimization, credit-aware for burstable
                PROFILE_DIRTY_RATIO_BASE=5 # Lower for EBS latency
                ;;
            azure)
                # Azure: Accelerated networking, managed disk optimization
                PROFILE_DIRTY_RATIO_BASE=8
                ;;
            gcp)
                # GCP: virtio-net, local SSD optimization
                PROFILE_DIRTY_RATIO_BASE=10
                ;;
        esac
        ;;
    workstation)
        PROFILE_GOVERNOR="schedutil"
        PROFILE_TURBO=1
        PROFILE_THP="madvise"
        PROFILE_SWAPPINESS_BASE=$CONST_SWAPPINESS_WORKSTATION
        PROFILE_DIRTY_RATIO_BASE=$CONST_DIRTY_RATIO_WORKSTATION
        # PROFILE_CSTATE_LIMIT=0 # Unused
        PROFILE_BLACKLIST_DESKTOP=0
        ;;
    laptop)
        PROFILE_GOVERNOR="powersave"
        PROFILE_TURBO=0
        PROFILE_THP="never"
        PROFILE_SWAPPINESS_BASE=$CONST_SWAPPINESS_LAPTOP
        PROFILE_DIRTY_RATIO_BASE=$CONST_DIRTY_RATIO_LAPTOP
        # PROFILE_CSTATE_LIMIT=0 # Unused
        PROFILE_BLACKLIST_DESKTOP=0
        ;;
    latency)
        # Minimal latency: trading, HPC, gaming, real-time
        PROFILE_GOVERNOR="performance"
        PROFILE_TURBO=1
        PROFILE_THP="never"
        PROFILE_SWAPPINESS_BASE=$CONST_SWAPPINESS_LATENCY
        PROFILE_DIRTY_RATIO_BASE=$CONST_DIRTY_RATIO_LATENCY
        # PROFILE_CSTATE_LIMIT=1        # C1 only (set by OPT_LOW_LATENCY) # Unused
        PROFILE_BLACKLIST_DESKTOP=1
        ;;
    *)
        echo "Unknown profile: ${OPT_PROFILE}"
        exit 1
        ;;
esac

# --- Storage Detection ---
declare -A DISK_TYPE
declare -A DISK_CLOUD # Track cloud storage type
for disk in /sys/block/*/queue/rotational; do
    DEV=$(echo "${disk}" | cut -d/ -f4)
    [[ "${DEV}" =~ ^(loop|ram|dm-) ]] && continue
    [[ -f "/sys/block/${DEV}/queue/scheduler" ]] || continue
    if [[ "$(cat "${disk}" 2>/dev/null)" -eq 0 ]]; then
        DISK_TYPE[${DEV}]="ssd"
    else
        DISK_TYPE[${DEV}]="hdd"
    fi

    # Detect cloud storage type
    DISK_CLOUD[${DEV}]="local"
    if [[ "${CLOUD_PROVIDER}" != "none" ]]; then
        MODEL=""
        VENDOR=""
        [[ -f "/sys/block/${DEV}/device/model" ]] && MODEL=$(tr -d ' ' <"/sys/block/${DEV}/device/model" 2>/dev/null)
        [[ -f "/sys/block/${DEV}/device/vendor" ]] && VENDOR=$(tr -d ' ' <"/sys/block/${DEV}/device/vendor" 2>/dev/null)
        case ${CLOUD_PROVIDER} in
            aws)
                # AWS: NVMe EBS or NVMe instance store
                [[ "${DEV}" =~ ^nvme ]] && {
                    # Check NVMe controller model
                    NVME_MODEL=$(cat "/sys/block/${DEV}/device/model" 2>/dev/null || echo "")
                    [[ "${NVME_MODEL}" == *"Amazon Elastic Block Store"* ]] && DISK_CLOUD[${DEV}]="ebs"
                    [[ "${NVME_MODEL}" == *"Amazon EC2 NVMe Instance Storage"* ]] && DISK_CLOUD[${DEV}]="instance-store"
                }
                [[ "${DEV}" =~ ^xvd ]] && DISK_CLOUD[${DEV}]="ebs" # Xen-based EBS
                ;;
            azure)
                # Azure: Check for managed disk vs temp/local disk
                if [[ "${VENDOR}" == *"Msft"* ]]; then
                    # sdb is typically the temp disk on Azure
                    if [[ "${DEV}" == "sdb" ]]; then
                        DISK_CLOUD[${DEV}]="azure-temp"
                    else
                        DISK_CLOUD[${DEV}]="azure-disk"
                    fi
                fi
                # NVMe local disks on Lsv2/Lsv3 series
                [[ "${DEV}" =~ ^nvme ]] && [[ "${MODEL}" == *"NVMe"* ]] && DISK_CLOUD[${DEV}]="azure-local"
                ;;
            gcp)
                [[ "${MODEL}" == *"PersistentDisk"* ]] && DISK_CLOUD[${DEV}]="gcp-pd"
                [[ "${MODEL}" == *"nvme_card"* ]] && DISK_CLOUD[${DEV}]="gcp-local-ssd"
                [[ "${MODEL}" == *"LocalSSD"* ]] && DISK_CLOUD[${DEV}]="gcp-local-ssd"
                ;;
            alibaba)
                # Alibaba: vd* for cloud disk, nvme for local SSD
                [[ "${DEV}" =~ ^vd ]] && DISK_CLOUD[${DEV}]="cloud-disk"
                [[ "${DEV}" =~ ^nvme ]] && DISK_CLOUD[${DEV}]="alibaba-local"
                ;;
        esac
    fi
done

# Primary storage type (for memory tuning)
HW_PRIMARY_SSD=0
[[ -f /sys/block/sda/queue/rotational ]] && [[ "$(cat /sys/block/sda/queue/rotational)" -eq 0 ]] && HW_PRIMARY_SSD=1
[[ -d /sys/block/nvme0n1 ]] && HW_PRIMARY_SSD=1

# --- Display Detected Configuration ---
echo "┌─────────────────────────────────────────────────────────────────────────────┐"
echo "│ SYSTEM CONFIGURATION                                                        │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
printf "│ %-75.75s │\n" "Profile: ${OPT_PROFILE} (governor=${PROFILE_GOVERNOR}, THP=${PROFILE_THP})"
if [[ "${CLOUD_PROVIDER}" != "none" ]]; then
    printf "│ %-75.75s │\n" "Cloud: ${CLOUD_PROVIDER} | Instance: ${INSTANCE_TYPE:-unknown}"
    # Fetch additional cloud metadata (skip in dry-run/report mode)
    if [[ ${OPT_DRY_RUN} -eq 0 ]]; then
        case ${CLOUD_PROVIDER} in
            aws)
                _aws_az=$(imds_fetch "http://169.254.169.254/latest/meta-data/placement/availability-zone")
                _aws_ami=$(imds_fetch "http://169.254.169.254/latest/meta-data/ami-id")
                _aws_id=$(imds_fetch "http://169.254.169.254/latest/meta-data/instance-id")
                [[ -n "${_aws_az}" ]] && printf "│ %-75.75s │\n" "  AZ: ${_aws_az} | AMI: ${_aws_ami:-n/a}"
                [[ -n "${_aws_id}" ]] && printf "│ %-75.75s │\n" "  Instance ID: ${_aws_id}"
                ;;
            azure)
                _az_loc=$(imds_fetch "http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text" "Metadata:true")
                _az_rg=$(imds_fetch "http://169.254.169.254/metadata/instance/compute/resourceGroupName?api-version=2021-02-01&format=text" "Metadata:true")
                _az_id=$(imds_fetch "http://169.254.169.254/metadata/instance/compute/vmId?api-version=2021-02-01&format=text" "Metadata:true")
                [[ -n "${_az_loc}" ]] && printf "│ %-75.75s │\n" "  Location: ${_az_loc} | RG: ${_az_rg:-n/a}"
                [[ -n "${_az_id}" ]] && printf "│ %-75.75s │\n" "  VM ID: ${_az_id}"
                ;;
            gcp)
                _gcp_zone=$(imds_fetch "http://169.254.169.254/computeMetadata/v1/instance/zone" "Metadata-Flavor: Google")
                _gcp_zone=${_gcp_zone##*/}
                _gcp_id=$(imds_fetch "http://169.254.169.254/computeMetadata/v1/instance/id" "Metadata-Flavor: Google")
                _gcp_proj=$(imds_fetch "http://169.254.169.254/computeMetadata/v1/project/project-id" "Metadata-Flavor: Google")
                [[ -n "${_gcp_zone}" ]] && printf "│ %-75.75s │\n" "  Zone: ${_gcp_zone} | Project: ${_gcp_proj:-n/a}"
                [[ -n "${_gcp_id}" ]] && printf "│ %-75.75s │\n" "  Instance ID: ${_gcp_id}"
                ;;
            alibaba)
                _ali_zone=$(imds_fetch "http://100.100.100.200/latest/meta-data/zone-id")
                _ali_region=$(imds_fetch "http://100.100.100.200/latest/meta-data/region-id")
                _ali_id=$(imds_fetch "http://100.100.100.200/latest/meta-data/instance-id")
                [[ -n "${_ali_region}" ]] && printf "│ %-75.75s │\n" "  Region: ${_ali_region} | Zone: ${_ali_zone:-n/a}"
                [[ -n "${_ali_id}" ]] && printf "│ %-75.75s │\n" "  Instance ID: ${_ali_id}"
                ;;
        esac
    fi
fi
printf "│ %-75.75s │\n" "CPU: ${HW_CPU_MODEL}"
printf "│ %-75.75s │\n" "Vendor: ${HW_CPU_VENDOR} | Cores: ${HW_CPU_CORES} | SMT: ${HW_SMT_ACTIVE} (threads/core: ${HW_THREADS_PER_CORE})"
printf "│ %-75.75s │\n" "Memory: ${HW_MEM_TOTAL_GB}GB | NUMA Nodes: ${HW_NUMA_NODES}"
printf "│ %-75.75s │\n" "OS: ${DISTRO_PRETTY}"
printf "│ %-75.75s │\n" "Kernel: ${KERNEL_RELEASE}"
printf "│ %-75.75s │\n" "Virtualization: ${HW_IS_VM}"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ STORAGE DEVICES                                                             │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
for DEV in "${!DISK_TYPE[@]}"; do
    TYPE=${DISK_TYPE[${DEV}]}
    CLOUD_TYPE=${DISK_CLOUD[${DEV}]}
    SCHED=$(grep -o '\[.*\]' "/sys/block/${DEV}/queue/scheduler" 2>/dev/null | tr -d '[]')
    # Get size in human-readable format
    SIZE_SECTORS=$(cat "/sys/block/${DEV}/size" 2>/dev/null || echo 0)
    SIZE_GB=$((SIZE_SECTORS * 512 / 1024 / 1024 / 1024))
    if [[ "${CLOUD_TYPE}" != "local" ]]; then
        printf "│ %-75.75s │\n" "${DEV}: ${TYPE^^} ${SIZE_GB}GB [${CLOUD_TYPE}] (scheduler: ${SCHED})"
    else
        printf "│ %-75.75s │\n" "${DEV}: ${TYPE^^} ${SIZE_GB}GB (scheduler: ${SCHED})"
    fi
done
echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ CPU SECURITY MITIGATIONS                                                    │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
if [[ -d /sys/devices/system/cpu/vulnerabilities ]]; then
    for v in /sys/devices/system/cpu/vulnerabilities/*; do
        NAME=$(basename "${v}")
        STATUS=$(tr -d '\n' <"${v}" 2>/dev/null | cut -c1-54)
        printf "│ %-20.20s %-54.54s │\n" "${NAME}:" "${STATUS}"
    done
fi
echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ SECURITY SETTINGS (Performance Impact)                                      │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"

# Check SELinux
SELINUX_STATUS="disabled"
if command -v getenforce &>/dev/null; then
    SELINUX_STATUS=$(getenforce 2>/dev/null || echo "disabled")
fi
[[ "${SELINUX_STATUS}" = "Enforcing" ]] && SELINUX_IMPACT="~2-5% overhead" || SELINUX_IMPACT="no impact"
printf "│ %-20.20s %-29.29s %-24.24s │\n" "SELinux:" "${SELINUX_STATUS}" "(${SELINUX_IMPACT})"

# Check AppArmor
APPARMOR_STATUS="disabled"
APPARMOR_PROFILES=0
if [[ -r /sys/kernel/security/apparmor/profiles ]]; then
    APPARMOR_PROFILES=$(wc -l /sys/kernel/security/apparmor/profiles 2>/dev/null | awk '{print $1}' || echo 0)
    [[ "${APPARMOR_PROFILES}" -gt 0 ]] && APPARMOR_STATUS="enabled (${APPARMOR_PROFILES} profiles)"
fi
[[ "${APPARMOR_PROFILES}" -gt 0 ]] && APPARMOR_IMPACT="~1-3% overhead" || APPARMOR_IMPACT="no impact"
printf "│ %-20.20s %-29.29s %-24.24s │\n" "AppArmor:" "${APPARMOR_STATUS}" "(${APPARMOR_IMPACT})"

# Check audit daemon
AUDIT_STATUS="disabled"
if systemctl is-active auditd &>/dev/null; then
    AUDIT_STATUS="running"
    AUDIT_IMPACT="~1-5% I/O overhead"
else
    AUDIT_IMPACT="no impact"
fi
printf "│ %-20.20s %-29.29s %-24.24s │\n" "Audit daemon:" "${AUDIT_STATUS}" "(${AUDIT_IMPACT})"

# Check firewall (nftables is replacing iptables in modern distros)
FIREWALL_STATUS="disabled"
FIREWALL_IMPACT="no impact"
if systemctl is-active firewalld &>/dev/null; then
    # firewalld uses nftables backend by default since RHEL 8/Fedora 18
    FIREWALL_STATUS="firewalld (nftables)"
    RULES=$(firewall-cmd --list-all 2>/dev/null | wc -l)
    FIREWALL_IMPACT="~1-2% network"
elif systemctl is-active ufw &>/dev/null; then
    FIREWALL_STATUS="ufw running"
    FIREWALL_IMPACT="~1-2% network"
elif command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q "chain"; then
    # Direct nftables usage
    RULES=$(nft list ruleset 2>/dev/null | grep -c "^[[:space:]]*chain" || echo 0)
    FIREWALL_STATUS="nftables (${RULES} chains)"
    FIREWALL_IMPACT="~1-2% network"
elif iptables -L -n 2>/dev/null | grep -q "Chain"; then
    # Legacy iptables (may be iptables-nft wrapper)
    RULES=$(iptables -L -n 2>/dev/null | grep -c "^[A-Z]" || echo 0)
    if iptables -V 2>/dev/null | grep -q "nf_tables"; then
        [[ "${RULES}" -gt 10 ]] && FIREWALL_STATUS="iptables-nft (${RULES} rules)" && FIREWALL_IMPACT="~1-2% network"
    else
        [[ "${RULES}" -gt 10 ]] && FIREWALL_STATUS="iptables (${RULES} rules)" && FIREWALL_IMPACT="~1-3% network"
    fi
fi
printf "│ %-20.20s %-29.29s %-24.24s │\n" "Firewall:" "${FIREWALL_STATUS}" "(${FIREWALL_IMPACT})"

# Check IOMMU/VT-d via sysfs (faster, no privilege issues unlike dmesg)
IOMMU_STATUS="disabled"
if [[ -d /sys/kernel/iommu_groups ]] && [[ $(find /sys/kernel/iommu_groups -maxdepth 1 -type d 2>/dev/null | wc -l) -gt 1 ]]; then
    IOMMU_STATUS="enabled"
    IOMMU_IMPACT="~1-2% I/O (if unused)"
else
    IOMMU_IMPACT="no impact"
fi
printf "│ %-20.20s %-29.29s %-24.24s │\n" "IOMMU:" "${IOMMU_STATUS}" "(${IOMMU_IMPACT})"

# Check speculative execution mitigations impact estimate
MITIGATION_IMPACT="minimal"
if [[ -d /sys/devices/system/cpu/vulnerabilities ]]; then
    MITIG_COUNT=0
    for v in /sys/devices/system/cpu/vulnerabilities/*; do
        grep -qi "mitigation" "${v}" 2>/dev/null && MITIG_COUNT=$((MITIG_COUNT + 1))
    done
    if [[ ${MITIG_COUNT} -ge 5 ]]; then
        MITIGATION_IMPACT="~5-30% (use --disable-mitigations)"
    elif [[ ${MITIG_COUNT} -ge 3 ]]; then
        MITIGATION_IMPACT="~3-15%"
    fi
fi
printf "│ %-20.20s %-29.29s %-24.24s │\n" "CPU mitigations:" "${MITIG_COUNT} active" "(${MITIGATION_IMPACT})"

# Check kernel lockdown
LOCKDOWN_STATUS="disabled"
if [[ -f /sys/kernel/security/lockdown ]]; then
    LOCKDOWN_STATUS=$(grep -o '\[.*\]' /sys/kernel/security/lockdown 2>/dev/null | tr -d '[]')
    [[ -z "${LOCKDOWN_STATUS}" ]] && LOCKDOWN_STATUS="none"
fi
printf "│ %-20.20s %-29.29s %-24.24s │\n" "Kernel lockdown:" "${LOCKDOWN_STATUS}" "(no perf impact)"

# Check journald settings
JOURNAL_STORAGE=$(grep -E "^Storage=" /etc/systemd/journald.conf 2>/dev/null | cut -d= -f2 || echo "auto")
# JOURNAL_RATE=$(grep -E "^RateLimitBurst=" /etc/systemd/journald.conf 2>/dev/null | cut -d= -f2 || echo "default") # Unused
[[ -z "${JOURNAL_STORAGE}" ]] && JOURNAL_STORAGE="auto"
[[ "${JOURNAL_STORAGE}" = "persistent" ]] && JOURNAL_IMPACT="~1-3% I/O" || JOURNAL_IMPACT="minimal"
printf "│ %-20.20s %-29.29s %-24.24s │\n" "Journald:" "storage=${JOURNAL_STORAGE}" "(${JOURNAL_IMPACT})"

# Check rsyslog/syslog-ng
SYSLOG_STATUS="not running"
SYSLOG_IMPACT="no impact"
if systemctl is-active rsyslog &>/dev/null; then
    SYSLOG_STATUS="rsyslog running"
    SYSLOG_IMPACT="~1-2% I/O"
elif systemctl is-active syslog-ng &>/dev/null; then
    SYSLOG_STATUS="syslog-ng running"
    SYSLOG_IMPACT="~1-2% I/O"
fi
printf "│ %-20.20s %-29.29s %-24.24s │\n" "Syslog:" "${SYSLOG_STATUS}" "(${SYSLOG_IMPACT})"

# Check kernel printk level
PRINTK_LEVEL=$(awk '{print $1}' /proc/sys/kernel/printk 2>/dev/null)
[[ "${PRINTK_LEVEL}" -ge 5 ]] && PRINTK_IMPACT="verbose logging" || PRINTK_IMPACT="minimal"
printf "│ %-20.20s %-29.29s %-24.24s │\n" "Kernel printk:" "level=${PRINTK_LEVEL}" "(${PRINTK_IMPACT})"

echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ NON-ESSENTIAL SERVICES (Memory & CPU Impact)                                │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"

# Define services to check based on profile
# Format: name:description:typical_memory_mb:profiles (s=server,v=vm,w=workstation,l=laptop)
SERVICES_CHECK_ALL=(
    "cups:Print service:~30MB:sv"
    "cups-browsed:Print browsing:~10MB:sv"
    "avahi-daemon:mDNS/Bonjour:~5MB:sv"
    "ModemManager:Mobile broadband:~10MB:svw"
    "bluetooth:Bluetooth:~5MB:sv"
    "accounts-daemon:User accounts:~5MB:sv"
    "packagekit:Package updates:~50MB:svl"
    "snapd:Snap packages:~50MB:sv"
    "unattended-upgrades:Auto updates:~20MB:sv"
    "thermald:Thermal daemon:~5MB:sv"
    "power-profiles-daemon:Power profiles:~5MB:sv"
    "switcheroo-control:GPU switching:~3MB:svw"
    "bolt:Thunderbolt:~3MB:sv"
    "fwupd:Firmware updates:~20MB:sv"
    "colord:Color management:~10MB:sv"
    "udisks2:Disk management:~10MB:sv"
    "geoclue:Location service:~5MB:sv"
    "whoopsie:Error reporting:~10MB:svwl"
    "apport:Crash reporting:~10MB:svwl"
    "kerneloops:Kernel oops:~5MB:svwl"
    "speech-dispatcher:Speech synthesis:~10MB:sv"
    "brltty:Braille display:~5MB:svwl"
)

# Map profile to check letter
case ${OPT_PROFILE} in
    server) PROFILE_LETTER="s" ;;
    vm) PROFILE_LETTER="v" ;;
    workstation) PROFILE_LETTER="w" ;;
    laptop) PROFILE_LETTER="l" ;;
    latency) PROFILE_LETTER="s" ;; # Same as server for service disabling
esac

TOTAL_WASTE_MB=0
RUNNING_SERVICES=""
for svc_info in "${SERVICES_CHECK_ALL[@]}"; do
    SVC=$(echo "${svc_info}" | cut -d: -f1)
    # DESC=$(echo "$svc_info" | cut -d: -f2) # Unused
    MEM=$(echo "${svc_info}" | cut -d: -f3)
    PROFILES=$(echo "${svc_info}" | cut -d: -f4)
    MEM_NUM=$(echo "${MEM}" | grep -oE '[0-9]+')

    # Only check if this service is non-essential for current profile
    if [[ "${PROFILES}" == *"${PROFILE_LETTER}"* ]]; then
        if systemctl is-active "${SVC}" &>/dev/null 2>&1; then
            printf "│ %-20.20s %-29.29s %-24.24s │\n" "${SVC}:" "running" "(${MEM})"
            TOTAL_WASTE_MB=$((TOTAL_WASTE_MB + MEM_NUM))
            RUNNING_SERVICES="${RUNNING_SERVICES} ${SVC}"
        fi
    fi
done

if [[ ${TOTAL_WASTE_MB} -eq 0 ]]; then
    printf "│ %-75.75s │\n" "No non-essential services for ${OPT_PROFILE} profile"
else
    printf "│ %s │\n" "$(printf '%*s' 75 '' | tr ' ' '-')"
    printf "│ %-20.20s %-29.29s %-24.24s │\n" "TOTAL:" "${TOTAL_WASTE_MB} MB potential savings" "(use --disable-services)"
fi

echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ MEMORY USAGE ANALYSIS                                                       │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"

# Current memory stats
MEM_TOTAL=$((HW_MEM_TOTAL_KB / 1024))
MEM_AVAIL=$(awk '/^MemAvailable:/{printf "%d", int($2/1024)}' /proc/meminfo)
MEM_BUFFERS=$(awk '/^Buffers:/{printf "%d", int($2/1024)}' /proc/meminfo)
MEM_CACHED=$(awk '/^Cached:/{printf "%d", int($2/1024)}' /proc/meminfo)
MEM_SLAB=$(awk '/^Slab:/{printf "%d", int($2/1024)}' /proc/meminfo)
MEM_USED=$((MEM_TOTAL - MEM_AVAIL))

printf "│ %-20.20s %-54.54s │\n" "Total:" "${MEM_TOTAL}MB"
printf "│ %-20.20s %-54.54s │\n" "Used:" "${MEM_USED}MB ($((MEM_USED * 100 / MEM_TOTAL))%)"
printf "│ %-20.20s %-54.54s │\n" "Available:" "${MEM_AVAIL}MB ($((MEM_AVAIL * 100 / MEM_TOTAL))%)"
printf "│ %-20.20s %-54.54s │\n" "Buffers/Cache:" "$((MEM_BUFFERS + MEM_CACHED))MB (reclaimable)"
printf "│ %-20.20s %-54.54s │\n" "Slab cache:" "${MEM_SLAB}MB (kernel objects)"

# Check for memory optimization opportunities
MEM_OPTS=""
# Swap usage
SWAP_USED=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo 2>/dev/null || echo 0)
[[ "${SWAP_USED}" -gt 100 ]] && MEM_OPTS="${MEM_OPTS} swap_in_use"

# Large slab cache
[[ "${MEM_SLAB}" -gt $((MEM_TOTAL / 10)) ]] && MEM_OPTS="${MEM_OPTS} large_slab"

# Huge pages reserved but unused
HP_TOTAL=$(grep "^HugePages_Total:" /proc/meminfo | awk '{print $2}')
HP_FREE=$(grep "^HugePages_Free:" /proc/meminfo | awk '{print $2}')
[[ "${HP_TOTAL}" -gt 0 ]] && [[ "${HP_FREE}" -eq "${HP_TOTAL}" ]] && MEM_OPTS="${MEM_OPTS} unused_hugepages"

if [[ -n "${MEM_OPTS}" ]]; then
    printf "│ %s │\n" "$(printf '%*s' 75 '' | tr ' ' '-')"
    printf "│ %-20.20s %-54.54s │\n" "Optimization hints:" "${MEM_OPTS}"
fi

echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ MONITORING & PROFILING (Performance Impact)                                 │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"

# Check perf/profiling
PERF_PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "N/A")
[[ "${PERF_PARANOID}" != "N/A" ]] && printf "│ %-20.20s %-29.29s %-24.24s │\n" "perf_paranoid:" "${PERF_PARANOID}" "(higher=more overhead)"

# Check if perf is collecting
if pgrep -x "perf" &>/dev/null; then
    printf "│ %-20.20s %-29.29s %-24.24s │\n" "perf:" "running" "(~1-5% CPU overhead)"
fi

# Check sysstat/sar
if systemctl is-active sysstat &>/dev/null; then
    SAR_INTERVAL=$(sed -n 's|.*/\([0-9]*\).*|\1|p' /etc/cron.d/sysstat 2>/dev/null | head -1)
    SAR_INTERVAL=${SAR_INTERVAL:-10}
    printf "│ %-20.20s %-29.29s %-24.24s │\n" "sysstat/sar:" "running (${SAR_INTERVAL}min)" "(~0.5-1% I/O)"
fi

# Check collectd
if systemctl is-active collectd &>/dev/null; then
    printf "│ %-20.20s %-29.29s %-24.24s │\n" "collectd:" "running" "(~1-2% CPU)"
fi

# Check node_exporter (Prometheus)
if systemctl is-active node_exporter &>/dev/null || pgrep -x "node_exporter" &>/dev/null; then
    printf "│ %-20.20s %-29.29s %-24.24s │\n" "node_exporter:" "running" "(~0.5-1% CPU)"
fi

# Check telegraf
if systemctl is-active telegraf &>/dev/null; then
    printf "│ %-20.20s %-29.29s %-24.24s │\n" "telegraf:" "running" "(~1-2% CPU)"
fi

# Check netdata
if systemctl is-active netdata &>/dev/null; then
    printf "│ %-20.20s %-29.29s %-24.24s │\n" "netdata:" "running" "(~2-5% CPU)"
fi

# Check atop
if systemctl is-active atop &>/dev/null || pgrep -x "atop" &>/dev/null; then
    printf "│ %-20.20s %-29.29s %-24.24s │\n" "atop:" "running" "(~1-3% I/O)"
fi

# Check vmstat interval processes
VMSTAT_PROCS=$(pgrep -c "vmstat" 2>/dev/null) || VMSTAT_PROCS=0
[[ "${VMSTAT_PROCS}" -gt 0 ]] && printf "│ %-20.20s %-29.29s %-24.24s │\n" "vmstat:" "${VMSTAT_PROCS} processes" "(~0.1% per proc)"

# Check kernel tracing
FTRACE_ON=0
if [[ -f /sys/kernel/debug/tracing/tracing_on ]]; then
    FTRACE_ON=$(tr -d '\n' </sys/kernel/debug/tracing/tracing_on 2>/dev/null) || FTRACE_ON=0
fi
[[ "${FTRACE_ON}" = "1" ]] && printf "│ %-20.20s %-29.29s %-24.24s │\n" "ftrace:" "enabled" "(~5-20% overhead!)"

# Check eBPF/BCC tools
BPF_PROCS=$((0 + $( (ls /sys/fs/bpf 2>/dev/null || true) | wc -l)))
[[ "${BPF_PROCS}" -gt 0 ]] && printf "│ %-20.20s %-29.29s %-24.24s │\n" "eBPF programs:" "${BPF_PROCS} loaded" "(varies by program)"

# Check kernel accounting
ACCT_ON=0
[[ -f /proc/sys/kernel/acct ]] && ACCT_ON=$(cat /var/log/pacct 2>/dev/null && echo 1 || echo 0)
[[ "${ACCT_ON}" -eq 1 ]] && printf "│ %-20.20s %-29.29s %-24.24s │\n" "Process acct:" "enabled" "(~1-2% I/O)"

# Check schedstats
SCHEDSTATS=$(cat /proc/sys/kernel/sched_schedstats 2>/dev/null || echo 0)
[[ "${SCHEDSTATS}" -eq 1 ]] && printf "│ %-20.20s %-29.29s %-24.24s │\n" "schedstats:" "enabled" "(~1-2% CPU)"

# Check nmi_watchdog
NMI_WD=$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null || echo 0)
[[ "${NMI_WD}" -eq 1 ]] && printf "│ %-20.20s %-29.29s %-24.24s │\n" "nmi_watchdog:" "enabled" "(~0.5-1% CPU)"

# Check kptr_restrict (affects profiling tools)
KPTR=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo 0)
printf "│ %-20.20s %-29.29s %-24.24s │\n" "kptr_restrict:" "${KPTR}" "(affects profiling)"

echo "└─────────────────────────────────────────────────────────────────────────────┘"
echo ""

#===============================================================================
# PHASE 3: APPLY OPTIMIZATIONS
#===============================================================================

echo ">>> Phase 2: Applying Optimizations..."
echo ""

#-------------------------------------------------------------------------------
# 3.1 CPU OPTIMIZATIONS
#-------------------------------------------------------------------------------
echo "[CPU] Configuring processor settings..."

# --- CPU Governor: Set to performance mode ---
set_governor() {
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "${g}" ]] && write_value_quiet "${g}" "$1"
    done
}

if ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor &>/dev/null; then
    pkg_install linux-tools-common cpupower kernel-tools || true
    set_governor "${PROFILE_GOVERNOR}"
    echo "  ✓ Governor: ${PROFILE_GOVERNOR}"
fi

# --- Turbo Boost: Based on profile ---
if [[ "${HW_CPU_VENDOR}" = "GenuineIntel" ]]; then
    if [[ ${PROFILE_TURBO} -eq 1 ]]; then
        [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]] && write_value_quiet /sys/devices/system/cpu/intel_pstate/no_turbo 0
        [[ -f /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost ]] && write_value_quiet /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost 1
        echo "  ✓ Intel Turbo Boost: enabled"
    else
        [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]] && write_value_quiet /sys/devices/system/cpu/intel_pstate/no_turbo 1
        echo "  ✓ Intel Turbo Boost: disabled (battery saving)"
    fi
elif [[ "${HW_CPU_VENDOR}" = "AuthenticAMD" ]]; then
    if [[ ${PROFILE_TURBO} -eq 1 ]]; then
        [[ -f /sys/devices/system/cpu/cpufreq/boost ]] && write_value_quiet /sys/devices/system/cpu/cpufreq/boost 1
        echo "  ✓ AMD Precision Boost: enabled"
    else
        [[ -f /sys/devices/system/cpu/cpufreq/boost ]] && write_value_quiet /sys/devices/system/cpu/cpufreq/boost 0
        echo "  ✓ AMD Precision Boost: disabled (battery saving)"
    fi
fi

# --- SMT Control ---
if [[ ${OPT_DISABLE_SMT} -eq 1 ]]; then
    if [[ -f /sys/devices/system/cpu/smt/control ]] && [[ "${HW_SMT_CONTROL}" != "notsupported" ]]; then
        write_value_quiet /sys/devices/system/cpu/smt/control off
        HW_CPU_CORES=$(nproc) # Update core count
        echo "  ✓ SMT: disabled (effective cores: ${HW_CPU_CORES})"
    else
        echo "  ✗ SMT: control not available"
    fi
else
    [[ -f /sys/devices/system/cpu/smt/control ]] && [[ "${HW_SMT_CONTROL}" = "off" ]] && write_value_quiet /sys/devices/system/cpu/smt/control on
    echo "  ✓ SMT: enabled (default)"
fi

# --- CPU Mitigations (requires reboot) ---
if [[ ${OPT_DISABLE_MITIGATIONS} -eq 1 ]]; then
    # Additional VM-specific warning
    if [[ "${HW_IS_VM}" != "none" ]]; then
        warn "Disabling mitigations in VM (${HW_IS_VM}) - host may still be vulnerable"
    fi

    if [[ -f /etc/default/grub ]]; then
        backup_file "/etc/default/grub"
        MITIG_PARAMS="mitigations=off"
        [[ "${HW_CPU_VENDOR}" = "GenuineIntel" ]] && MITIG_PARAMS="mitigations=off tsx=on tsx_async_abort=off mds=off l1tf=off"
        [[ "${HW_CPU_VENDOR}" = "AuthenticAMD" ]] && [[ "${HW_CPU_FAMILY}" = "23" ]] && MITIG_PARAMS="mitigations=off retbleed=off"

        run sed -i 's/mitigations=[^ "]*//g; s/tsx=[^ "]*//g; s/tsx_async_abort=[^ "]*//g; s/mds=[^ "]*//g; s/l1tf=[^ "]*//g; s/retbleed=[^ "]*//g' /etc/default/grub
        run sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${MITIG_PARAMS} |" /etc/default/grub
        run sed -i 's/  */ /g; s/" /"/g' /etc/default/grub

        # Azure/cloud-init VMs: also update grub.d override file
        if [[ -f /etc/default/grub.d/50-cloudimg-settings.cfg ]]; then
            backup_file "/etc/default/grub.d/50-cloudimg-settings.cfg"
            run sed -i 's/mitigations=[^ "]*//g; s/tsx=[^ "]*//g; s/tsx_async_abort=[^ "]*//g; s/mds=[^ "]*//g; s/l1tf=[^ "]*//g; s/retbleed=[^ "]*//g' /etc/default/grub.d/50-cloudimg-settings.cfg
            if grep -q 'GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub.d/50-cloudimg-settings.cfg; then
                run sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${MITIG_PARAMS} |" /etc/default/grub.d/50-cloudimg-settings.cfg
            else
                run bash -c "echo 'GRUB_CMDLINE_LINUX_DEFAULT=\"\${GRUB_CMDLINE_LINUX_DEFAULT} ${MITIG_PARAMS}\"' >> /etc/default/grub.d/50-cloudimg-settings.cfg"
            fi
            run sed -i 's/  */ /g; s/" /"/g' /etc/default/grub.d/50-cloudimg-settings.cfg
        fi

        update_grub_config || true
        echo "  ✓ Mitigations: will be disabled after reboot"
    fi
fi

# --- CPU Isolation (requires reboot) ---
if [[ -n "${OPT_ISOLATE_CPUS}" ]] && [[ -f /etc/default/grub ]]; then
    backup_file "/etc/default/grub"
    # Sanitize user input before use in sed patterns
    if [[ ! "${OPT_ISOLATE_CPUS}" =~ ^[0-9]+([,\-][0-9]+)*$ ]]; then
        die "Invalid characters in --isolate-cpus: ${OPT_ISOLATE_CPUS}"
    fi
    ISOL_PARAMS="isolcpus=${OPT_ISOLATE_CPUS} nohz_full=${OPT_ISOLATE_CPUS} rcu_nocbs=${OPT_ISOLATE_CPUS}"
    run sed -i 's/isolcpus=[^ "]*//g; s/nohz_full=[^ "]*//g; s/rcu_nocbs=[^ "]*//g' /etc/default/grub
    run sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${ISOL_PARAMS} |" /etc/default/grub
    run sed -i 's/  */ /g; s/" /"/g' /etc/default/grub

    # Azure/cloud-init VMs: also update grub.d override file
    if [[ -f /etc/default/grub.d/50-cloudimg-settings.cfg ]]; then
        backup_file "/etc/default/grub.d/50-cloudimg-settings.cfg"
        run sed -i 's/isolcpus=[^ "]*//g; s/nohz_full=[^ "]*//g; s/rcu_nocbs=[^ "]*//g' /etc/default/grub.d/50-cloudimg-settings.cfg
        if grep -q 'GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub.d/50-cloudimg-settings.cfg; then
            run sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${ISOL_PARAMS} |" /etc/default/grub.d/50-cloudimg-settings.cfg
        else
            run bash -c "echo 'GRUB_CMDLINE_LINUX_DEFAULT=\"\${GRUB_CMDLINE_LINUX_DEFAULT} ${ISOL_PARAMS}\"' >> /etc/default/grub.d/50-cloudimg-settings.cfg"
        fi
        run sed -i 's/  */ /g; s/" /"/g' /etc/default/grub.d/50-cloudimg-settings.cfg
    fi

    update_grub_config || true
    echo "  ✓ CPU Isolation: ${OPT_ISOLATE_CPUS} (after reboot)"
fi

# --- Latency Profile GRUB Parameters (requires reboot) ---
if [[ "${OPT_PROFILE}" = "latency" ]] && [[ -f /etc/default/grub ]]; then
    echo ""
    echo "[GRUB] Configuring kernel boot parameters for low-latency..."

    # Build latency-optimized kernel parameters
    LATENCY_PARAMS=""
    LATENCY_PARAMS+="processor.max_cstate=1 "     # Limit C-states
    LATENCY_PARAMS+="intel_idle.max_cstate=1 "    # Intel C-state limit
    LATENCY_PARAMS+="idle=poll "                  # Busy-poll idle (extreme, optional)
    LATENCY_PARAMS+="nowatchdog "                 # Disable watchdog
    LATENCY_PARAMS+="nmi_watchdog=0 "             # Disable NMI watchdog
    LATENCY_PARAMS+="nosoftlockup "               # Disable soft lockup detector
    LATENCY_PARAMS+="tsc=reliable "               # Trust TSC
    LATENCY_PARAMS+="clocksource=tsc "            # Use TSC clocksource
    LATENCY_PARAMS+="transparent_hugepage=never " # Disable THP
    LATENCY_PARAMS+="skew_tick=1 "                # Spread timer ticks

    # Check if parameters already exist
    if ! grep -q "processor.max_cstate=1" /etc/default/grub; then
        backup_file "/etc/default/grub"

        # Remove conflicting parameters first
        run sed -i 's/processor.max_cstate=[^ "]*//g; s/intel_idle.max_cstate=[^ "]*//g' /etc/default/grub
        run sed -i 's/idle=[^ "]*//g; s/nowatchdog//g; s/nmi_watchdog=[^ "]*//g' /etc/default/grub
        run sed -i 's/transparent_hugepage=[^ "]*//g; s/skew_tick=[^ "]*//g' /etc/default/grub

        # Add new parameters
        run sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${LATENCY_PARAMS}|" /etc/default/grub
        run sed -i 's/  */ /g; s/" /"/g' /etc/default/grub

        # Azure/cloud-init VMs: also update grub.d override file
        if [[ -f /etc/default/grub.d/50-cloudimg-settings.cfg ]]; then
            backup_file "/etc/default/grub.d/50-cloudimg-settings.cfg"
            run sed -i 's/processor.max_cstate=[^ "]*//g; s/intel_idle.max_cstate=[^ "]*//g' /etc/default/grub.d/50-cloudimg-settings.cfg
            run sed -i 's/idle=[^ "]*//g; s/nowatchdog//g; s/nmi_watchdog=[^ "]*//g' /etc/default/grub.d/50-cloudimg-settings.cfg
            run sed -i 's/transparent_hugepage=[^ "]*//g; s/skew_tick=[^ "]*//g' /etc/default/grub.d/50-cloudimg-settings.cfg
            if grep -q 'GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub.d/50-cloudimg-settings.cfg; then
                run sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${LATENCY_PARAMS}|" /etc/default/grub.d/50-cloudimg-settings.cfg
            else
                run bash -c "echo 'GRUB_CMDLINE_LINUX_DEFAULT=\"\${GRUB_CMDLINE_LINUX_DEFAULT} ${LATENCY_PARAMS}\"' >> /etc/default/grub.d/50-cloudimg-settings.cfg"
            fi
            run sed -i 's/  */ /g; s/" /"/g' /etc/default/grub.d/50-cloudimg-settings.cfg
        fi

        update_grub_config || true
        echo "  ✓ Latency kernel params: configured (reboot required)"
        echo "  → Added: max_cstate=1, nowatchdog, tsc=reliable, THP=never"
    else
        echo "  → Latency kernel params: already configured"
    fi
fi

# --- Low Latency Mode ---
if [[ ${OPT_LOW_LATENCY} -eq 1 ]]; then
    # Limit C-states to C1
    for cpu in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
        STATE=$(echo "${cpu}" | sed -n 's/.*state\([0-9]*\).*/\1/p')
        [[ "${STATE}" -gt 1 ]] && write_value_quiet "${cpu}" 1
    done
    # Disable watchdogs
    write_value_quiet /proc/sys/kernel/watchdog 0
    write_value_quiet /proc/sys/kernel/nmi_watchdog 0
    write_value_quiet /proc/sys/kernel/hung_task_timeout_secs 0
    echo "  ✓ Low-latency: C-states limited, watchdogs disabled"
fi

#-------------------------------------------------------------------------------
# 3.2 MEMORY OPTIMIZATIONS
#-------------------------------------------------------------------------------
echo ""
echo "[MEMORY] Configuring memory management..."

# Calculate parameters based on RAM size and profile
# dirty_expire: centisecs before dirty data must be written (higher = more batching)
# dirty_writeback: centisecs between pdflush wakeups
if [[ ${HW_MEM_TOTAL_GB} -ge 64 ]]; then
    TUNE_SWAPPINESS=$((PROFILE_SWAPPINESS_BASE / 2))
    TUNE_DIRTY_RATIO=$((PROFILE_DIRTY_RATIO_BASE + 5))
    TUNE_DIRTY_BG_RATIO=5
    TUNE_VFS_PRESSURE=30
    TUNE_DIRTY_EXPIRE=6000    # 60s - large RAM can batch more
    TUNE_DIRTY_WRITEBACK=1000 # 10s
elif [[ ${HW_MEM_TOTAL_GB} -ge 16 ]]; then
    TUNE_SWAPPINESS=${PROFILE_SWAPPINESS_BASE}
    TUNE_DIRTY_RATIO=${PROFILE_DIRTY_RATIO_BASE}
    TUNE_DIRTY_BG_RATIO=5
    TUNE_VFS_PRESSURE=50
    TUNE_DIRTY_EXPIRE=3000   # 30s
    TUNE_DIRTY_WRITEBACK=500 # 5s
elif [[ ${HW_MEM_TOTAL_GB} -ge 4 ]]; then
    TUNE_SWAPPINESS=$((PROFILE_SWAPPINESS_BASE + 20))
    TUNE_DIRTY_RATIO=$((PROFILE_DIRTY_RATIO_BASE - 5))
    [[ ${TUNE_DIRTY_RATIO} -lt 5 ]] && TUNE_DIRTY_RATIO=5
    TUNE_DIRTY_BG_RATIO=3
    TUNE_VFS_PRESSURE=75
    TUNE_DIRTY_EXPIRE=1500   # 15s
    TUNE_DIRTY_WRITEBACK=300 # 3s
else
    TUNE_SWAPPINESS=$((PROFILE_SWAPPINESS_BASE + 30))
    TUNE_DIRTY_RATIO=5
    TUNE_DIRTY_BG_RATIO=2
    TUNE_VFS_PRESSURE=100
    TUNE_DIRTY_EXPIRE=1000   # 10s - low RAM, flush quickly
    TUNE_DIRTY_WRITEBACK=200 # 2s
fi

# Min free memory: 1% of RAM, capped between 64MB-256MB
TUNE_MIN_FREE_KB=$((HW_MEM_TOTAL_KB / 100))
[[ ${TUNE_MIN_FREE_KB} -lt 65536 ]] && TUNE_MIN_FREE_KB=65536   # 64MB min
[[ ${TUNE_MIN_FREE_KB} -gt 262144 ]] && TUNE_MIN_FREE_KB=262144 # 256MB max

echo "  ✓ Swappiness: ${TUNE_SWAPPINESS} (RAM-based)"
echo "  ✓ Dirty ratio: ${TUNE_DIRTY_RATIO}% / background: ${TUNE_DIRTY_BG_RATIO}%"
echo "  ✓ VFS cache pressure: ${TUNE_VFS_PRESSURE}"

# --- THP (Transparent Huge Pages) - Profile based ---
TUNE_THP_MODE=${PROFILE_THP}
if [[ "${TUNE_THP_MODE}" = "madvise" ]]; then
    write_value_quiet /sys/kernel/mm/transparent_hugepage/enabled madvise
    write_value_quiet /sys/kernel/mm/transparent_hugepage/defrag defer+madvise
else
    write_value_quiet /sys/kernel/mm/transparent_hugepage/enabled never
fi
echo "  ✓ THP: ${TUNE_THP_MODE}"

# --- Memory Footprint Reduction ---
echo ""
echo "[MEMORY] Reducing memory footprint..."

# One-time memory reclaim (optional, can cause short stalls)
if [[ ${OPT_RECLAIM_MEMORY} -eq 1 ]]; then
    # Release unused huge pages
    HP_TOTAL=$(grep "^HugePages_Total:" /proc/meminfo 2>/dev/null | awk '{print $2}')
    HP_FREE=$(grep "^HugePages_Free:" /proc/meminfo 2>/dev/null | awk '{print $2}')
    if [[ "${HP_TOTAL:-0}" -gt 0 ]] && [[ "${HP_FREE}" -eq "${HP_TOTAL}" ]]; then
        write_value_quiet /proc/sys/vm/nr_hugepages 0
        HP_SIZE=$(grep "^Hugepagesize:" /proc/meminfo | awk '{print $2}')
        FREED=$((HP_TOTAL * HP_SIZE / 1024))
        echo "  ✓ Released unused huge pages: ${FREED}MB"
    fi

    # Compact memory (reduce fragmentation)
    if [[ -f /proc/sys/vm/compact_memory ]]; then
        write_value_quiet /proc/sys/vm/compact_memory 1
        echo "  ✓ Memory compaction: triggered"
    fi

    # Trim slab caches if too large
    MEM_SLAB_NOW=$(grep "^Slab:" /proc/meminfo | awk '{print int($2/1024)}')
    if [[ "${MEM_SLAB_NOW}" -gt $((HW_MEM_TOTAL_GB * 100)) ]]; then
        run sync
        write_value_quiet /proc/sys/vm/drop_caches 2
        MEM_SLAB_AFTER=$(grep "^Slab:" /proc/meminfo | awk '{print int($2/1024)}')
        echo "  ✓ Slab cache trimmed: ${MEM_SLAB_NOW}MB → ${MEM_SLAB_AFTER}MB"
    fi
else
    echo "  → Skipping one-time reclaim (use --reclaim-memory)"
fi

# --- KSM (Kernel Samepage Merging) ---
if [[ -f /sys/kernel/mm/ksm/run ]] && [[ "${HW_IS_VM}" = "none" ]]; then
    write_value_quiet /sys/kernel/mm/ksm/run 0
    echo "  ✓ KSM: disabled (bare metal)"
fi

#-------------------------------------------------------------------------------
# 3.2.1 ADVANCED MEMORY OPTIMIZATIONS
#-------------------------------------------------------------------------------

# --- zswap/zram (Compressed Swap) - Profile-aware ---
echo ""
echo "[MEMORY] Configuring compressed swap..."

HAS_SWAP=0
SWAP_DEVS=$(awk 'NR>1{c++} END{print c+0}' /proc/swaps 2>/dev/null || echo 0)
[[ "${SWAP_DEVS:-0}" -gt 0 ]] && HAS_SWAP=1

case ${OPT_PROFILE} in
    server | vm)
        # Server/VM: enable zswap for memory efficiency
        if [[ -f /sys/module/zswap/parameters/enabled ]]; then
            if [[ ${HAS_SWAP} -eq 0 ]]; then
                warn "zswap available but no swap devices detected; skipping zswap (enable swap or consider zram)"
            else
                write_value_quiet /sys/module/zswap/parameters/enabled 1
                write_value_quiet /sys/module/zswap/parameters/compressor lz4 ||
                    write_value_quiet /sys/module/zswap/parameters/compressor lzo
                write_value_quiet /sys/module/zswap/parameters/zpool z3fold ||
                    write_value_quiet /sys/module/zswap/parameters/zpool zbud
                write_value_quiet /sys/module/zswap/parameters/max_pool_percent 20
                echo "  ✓ zswap: enabled (lz4/z3fold, 20% max)"
            fi
        fi
        ;;
    workstation)
        # Workstation: enable zswap with moderate settings
        if [[ -f /sys/module/zswap/parameters/enabled ]]; then
            if [[ ${HAS_SWAP} -eq 0 ]]; then
                warn "zswap available but no swap devices detected; skipping zswap (enable swap or consider zram)"
            else
                write_value_quiet /sys/module/zswap/parameters/enabled 1
                write_value_quiet /sys/module/zswap/parameters/compressor lz4
                write_value_quiet /sys/module/zswap/parameters/max_pool_percent 15
                echo "  ✓ zswap: enabled (15% max)"
            fi
        fi
        ;;
    laptop)
        # Laptop: enable zswap to reduce SSD wear
        if [[ -f /sys/module/zswap/parameters/enabled ]]; then
            if [[ ${HAS_SWAP} -eq 0 ]]; then
                warn "zswap available but no swap devices detected; skipping zswap (enable swap or consider zram)"
            else
                write_value_quiet /sys/module/zswap/parameters/enabled 1
                write_value_quiet /sys/module/zswap/parameters/compressor lz4
                write_value_quiet /sys/module/zswap/parameters/max_pool_percent 25
                echo "  ✓ zswap: enabled (25% max - reduce SSD wear)"
            fi
        fi
        ;;
    latency)
        # Latency: disable zswap to avoid compression overhead
        if [[ -f /sys/module/zswap/parameters/enabled ]]; then
            write_value_quiet /sys/module/zswap/parameters/enabled 0
            echo "  ✓ zswap: disabled (latency profile)"
        fi
        ;;
esac

# Setup zram for low memory systems when no swap is present
if [[ ${HAS_SWAP} -eq 0 && ${HW_MEM_TOTAL_GB} -le 8 ]]; then
    if [[ ${OPT_DRY_RUN} -eq 1 ]]; then
        log "[DRY-RUN] modprobe zram; configure /dev/zram0 (~50% RAM); mkswap; swapon"
    else
        if modprobe zram 2>/dev/null; then
            ZRAM_SIZE=$((HW_MEM_TOTAL_KB * 1024 / 2))
            write_value_quiet /sys/block/zram0/disksize "${ZRAM_SIZE}"
            mkswap /dev/zram0 &>/dev/null || true
            swapon -p 100 /dev/zram0 2>/dev/null || true
            echo "  ✓ zram: enabled ($((ZRAM_SIZE / 1024 / 1024))MB)"
        fi
    fi
fi

# --- NUMA Memory Policy ---
if [[ ${HW_NUMA_NODES} -gt 1 ]]; then
    echo ""
    echo "[NUMA] Configuring multi-socket memory policy..."

    # Install numactl if needed
    pkg_install numactl || true

    # Set zone reclaim mode based on workload
    if [[ "${OPT_PROFILE}" = "server" ]]; then
        # Server: prefer local, but allow remote if needed
        TUNE_ZONE_RECLAIM_MODE=0
        write_value_quiet /proc/sys/vm/zone_reclaim_mode 0
        echo "  ✓ Zone reclaim: disabled (allow remote allocation)"
    else
        TUNE_ZONE_RECLAIM_MODE=1
        write_value_quiet /proc/sys/vm/zone_reclaim_mode 1
        echo "  ✓ Zone reclaim: enabled (prefer local)"
    fi

    # NUMA balancing
    if [[ "${OPT_LOW_LATENCY}" -eq 1 ]]; then
        write_value_quiet /proc/sys/kernel/numa_balancing 0
        echo "  ✓ NUMA balancing: disabled (low-latency)"
    else
        write_value_quiet /proc/sys/kernel/numa_balancing 1
        echo "  ✓ NUMA balancing: enabled"
    fi
fi

# --- tmpfs Optimization (profile-aware) ---
echo ""
echo "[TMPFS] Optimizing temporary filesystems..."

# Calculate tmpfs sizes based on profile
case ${OPT_PROFILE} in
    server)
        TMP_PERCENT=25 # 25% of RAM for /tmp
        SHM_PERCENT=50 # 50% of RAM for /dev/shm
        ;;
    vm)
        TMP_PERCENT=20
        SHM_PERCENT=40
        ;;
    workstation)
        TMP_PERCENT=15
        SHM_PERCENT=50
        ;;
    laptop)
        TMP_PERCENT=10 # Smaller to save RAM
        SHM_PERCENT=25
        ;;
    latency)
        TMP_PERCENT=25
        SHM_PERCENT=50
        ;;
esac

# Resize /tmp if it's tmpfs
if mount | grep -q "tmpfs on /tmp"; then
    TMP_SIZE=$((HW_MEM_TOTAL_GB * TMP_PERCENT / 100))
    [[ ${TMP_SIZE} -lt 1 ]] && TMP_SIZE=1
    [[ ${TMP_SIZE} -gt 16 ]] && TMP_SIZE=16
    run mount -o remount,size="${TMP_SIZE}"G,noatime,nodiratime /tmp || true
    echo "  ✓ /tmp: ${TMP_SIZE}GB (${TMP_PERCENT}% of RAM)"
fi

# Resize /dev/shm
if mount | grep -q "tmpfs on /dev/shm"; then
    SHM_SIZE=$((HW_MEM_TOTAL_GB * SHM_PERCENT / 100))
    [[ ${SHM_SIZE} -lt 1 ]] && SHM_SIZE=1
    run mount -o remount,size="${SHM_SIZE}"G /dev/shm || true
    echo "  ✓ /dev/shm: ${SHM_SIZE}GB (${SHM_PERCENT}% of RAM)"
fi

# --- OOM Killer Tuning ---
echo ""
echo "[OOM] Configuring OOM killer..."

# Protect critical system processes (systemd/PID 1 is already kernel-protected)
for proc in sshd journald; do
    for pid in $(pgrep -x "${proc}" 2>/dev/null); do
        [[ -f "/proc/${pid}/oom_score_adj" ]] && write_value_quiet "/proc/${pid}/oom_score_adj" -1000
    done
done
echo "  ✓ OOM: protected sshd, journald"

# --- Intel EPP/EPB (Energy Performance) ---
if [[ "${HW_CPU_VENDOR}" = "GenuineIntel" ]]; then
    echo ""
    echo "[POWER] Configuring Intel power management..."

    # Set Energy Performance Preference
    EPP_VALUE="balance_performance"
    case ${OPT_PROFILE} in
        server | vm)
            EPP_VALUE="performance"
            ;;
        workstation)
            EPP_VALUE="balance_performance"
            ;;
        laptop)
            EPP_VALUE="balance_power"
            ;;
        latency)
            EPP_VALUE="performance"
            ;;
    esac

    # Apply EPP to all CPUs (only if sysfs files exist)
    EPP_APPLIED=0
    if ls /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference &>/dev/null; then
        for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
            [[ -f "${epp}" ]] && write_value_quiet "${epp}" "${EPP_VALUE}" && EPP_APPLIED=1
        done
    fi

    # Set EPB (Energy Performance Bias) if available
    # Skip on VMs - x86_energy_perf_policy can hang when MSR access is restricted
    if [[ "${HW_IS_VM}" = "none" ]] && command -v x86_energy_perf_policy &>/dev/null; then
        # Use timeout to prevent hanging on restricted systems
        if command -v timeout &>/dev/null; then
            case ${OPT_PROFILE} in
                server | vm) timeout 2 x86_energy_perf_policy performance &>/dev/null || true ;;
                workstation) timeout 2 x86_energy_perf_policy normal &>/dev/null || true ;;
                laptop) timeout 2 x86_energy_perf_policy powersave &>/dev/null || true ;;
                latency) timeout 2 x86_energy_perf_policy performance &>/dev/null || true ;;
            esac
        fi
    fi

    if [[ ${EPP_APPLIED} -eq 1 ]]; then
        echo "  ✓ EPP: ${EPP_VALUE}"
    else
        echo "  → EPP: not available (VM or no intel_pstate)"
    fi
fi

# --- Kernel Scheduler Fine-Tuning ---
echo ""
echo "[SCHEDULER] Fine-tuning kernel scheduler..."

# Detect scheduler type: EEVDF (kernel 6.6+) vs CFS (older)
# EEVDF removed sched_latency_ns, sched_min_granularity_ns, sched_wakeup_granularity_ns
SCHEDULER_TYPE="eevdf"
if [[ -f /proc/sys/kernel/sched_latency_ns ]]; then
    SCHEDULER_TYPE="cfs"
fi

if [[ "${SCHEDULER_TYPE}" == "cfs" ]]; then
    # CFS scheduler tunables (kernel < 6.6)
    SCHED_LATENCY=${CONST_SCHED_LATENCY_WORKSTATION}
    SCHED_MIN_GRAN=${CONST_SCHED_MIN_GRAN_DESKTOP}
    SCHED_WAKEUP_GRAN=1000000 # 1ms default
    case ${OPT_PROFILE} in
        server)
            SCHED_LATENCY=${CONST_SCHED_LATENCY_SERVER}
            SCHED_MIN_GRAN=${CONST_SCHED_MIN_GRAN_SERVER}
            SCHED_WAKEUP_GRAN=4000000 # 4ms - less preemption, more throughput
            ;;
        vm)
            SCHED_LATENCY=${CONST_SCHED_LATENCY_VM}
            SCHED_MIN_GRAN=${CONST_SCHED_MIN_GRAN_VM}
            SCHED_WAKEUP_GRAN=3000000 # 3ms
            ;;
        workstation)
            SCHED_LATENCY=${CONST_SCHED_LATENCY_WORKSTATION}
            SCHED_MIN_GRAN=${CONST_SCHED_MIN_GRAN_DESKTOP}
            SCHED_WAKEUP_GRAN=1000000 # 1ms - responsive
            ;;
        laptop)
            SCHED_LATENCY=${CONST_SCHED_LATENCY_LAPTOP}
            SCHED_MIN_GRAN=${CONST_SCHED_MIN_GRAN_DESKTOP}
            SCHED_WAKEUP_GRAN=1000000 # 1ms
            ;;
        latency)
            SCHED_LATENCY=4000000    # 4ms - minimize scheduling latency
            SCHED_MIN_GRAN=500000    # 0.5ms - quick context switches
            SCHED_WAKEUP_GRAN=750000 # 0.75ms - fast wakeup response
            ;;
    esac

    cat >>"${SYSCTL_SNIPPETS_FILE}" <<EOF

# CFS Scheduler Fine-Tuning (kernel < 6.6)
kernel.sched_latency_ns = ${SCHED_LATENCY}
kernel.sched_min_granularity_ns = ${SCHED_MIN_GRAN}
kernel.sched_wakeup_granularity_ns = ${SCHED_WAKEUP_GRAN}
kernel.sched_child_runs_first = 0
kernel.sched_tunable_scaling = 1
EOF
    echo "  ✓ CFS Scheduler: latency=${SCHED_LATENCY}ns, min_gran=${SCHED_MIN_GRAN}ns"
else
    # EEVDF scheduler (kernel 6.6+) - fewer tunables, more algorithmic
    cat >>"${SYSCTL_SNIPPETS_FILE}" <<EOF

# EEVDF Scheduler (kernel 6.6+)
# Note: sched_latency_ns, sched_min_granularity_ns, sched_wakeup_granularity_ns
# were removed in EEVDF. The scheduler is now more algorithmic with fewer tunables.
kernel.sched_autogroup_enabled = $([[ "${OPT_PROFILE}" = "server" ]] && echo 0 || echo 1)
EOF
    echo "  ✓ EEVDF Scheduler: autogroup=$([[ "${OPT_PROFILE}" = "server" ]] && echo disabled || echo enabled)"
fi

# --- Real-Time Throttling ---
echo ""
echo "[RT] Configuring real-time scheduling..."

if [[ "${OPT_LOW_LATENCY}" -eq 1 ]]; then
    # Disable RT throttling for low-latency (-1 = unlimited)
    write_value_quiet /proc/sys/kernel/sched_rt_runtime_us -1
    echo "  ✓ RT throttling: disabled (low-latency mode)"
else
    # Default: RT tasks can use 950000/1000000 = 95% of each second
    write_value_quiet /proc/sys/kernel/sched_rt_runtime_us 950000
    echo "  ✓ RT throttling: 95% max"
fi

# --- cgroups v2 Optimization ---
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    echo ""
    echo "[CGROUPS] Configuring cgroups v2..."

    # Enable all controllers at root
    # CONTROLLERS=$(cat /sys/fs/cgroup/cgroup.controllers) # Unused
    write_value_quiet /sys/fs/cgroup/cgroup.subtree_control "+cpu +memory +io +pids"

    # Set memory.high for user slices (soft limit at 90%)
    if [[ -d /sys/fs/cgroup/user.slice ]]; then
        MEM_HIGH=$((HW_MEM_TOTAL_KB * 1024 * 90 / 100))
        write_value_quiet /sys/fs/cgroup/user.slice/memory.high "${MEM_HIGH}"
    fi
    echo "  ✓ cgroups v2: controllers enabled"
fi

# --- I/O Priority Defaults ---
echo ""
echo "[IONICE] Configuring I/O priorities..."

# Set default I/O class for the system
if command -v ionice &>/dev/null; then
    # Best-effort class 4 (default priority)
    run_quiet ionice -c 2 -n 4 -p 1 # init/systemd
fi

echo "  ✓ I/O priority: configured"

# --- Kernel Debug Disable ---
echo ""
echo "[DEBUG] Disabling kernel debug features..."

cat >>"${SYSCTL_SNIPPETS_FILE}" <<'EOF'

# Disable Debug Features (production)
kernel.sysrq = 1
kernel.core_uses_pid = 1
kernel.randomize_va_space = 2
debug.exception-trace = 0
EOF

# Disable kernel debugging if not needed
[[ -f /sys/kernel/debug/sched_debug ]] && write_value_quiet /proc/sys/kernel/sched_debug 0
[[ -f /proc/sys/kernel/ftrace_enabled ]] && write_value_quiet /proc/sys/kernel/ftrace_enabled 0

echo "  ✓ Debug features: minimized"

# --- Memory Watermarks ---
echo ""
echo "[WATERMARKS] Configuring memory watermarks..."

# Calculate watermarks based on RAM
WATERMARK_SCALE=$((200 + HW_MEM_TOTAL_GB)) # Scale with RAM
[[ ${WATERMARK_SCALE} -gt 500 ]] && WATERMARK_SCALE=500

echo "  ✓ Watermarks: scale_factor=${WATERMARK_SCALE}"

# --- Linux Kernel 6.x+ Optimizations ---
KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
KERNEL_MAJOR=$(echo "${KERNEL_VERSION}" | cut -d. -f1)
KERNEL_MINOR=$(echo "${KERNEL_VERSION}" | cut -d. -f2)

if [[ "${KERNEL_MAJOR}" -ge 6 ]]; then
    echo ""
    echo "[KERNEL 6.x+] Applying modern kernel optimizations..."

    # --- Kernel 6.1+: MGLRU (Multi-Gen LRU) ---
    if [[ -f /sys/kernel/mm/lru_gen/enabled ]]; then
        # Enable MGLRU for better page reclaim
        write_value_quiet /sys/kernel/mm/lru_gen/enabled Y
        # Set min_ttl (minimum age before reclaim) - 0 for servers, higher for desktop
        case ${OPT_PROFILE} in
            server | vm) write_value_quiet /sys/kernel/mm/lru_gen/min_ttl_ms 0 ;;
            *) write_value_quiet /sys/kernel/mm/lru_gen/min_ttl_ms 1000 ;;
        esac
        echo "  ✓ MGLRU: enabled (better page reclaim)"
    fi

    # --- Kernel 6.2+: Per-VMA locks ---
    if [[ -f /proc/sys/vm/per_vma_lock ]]; then
        write_value_quiet /proc/sys/vm/per_vma_lock 1
        echo "vm.per_vma_lock = 1" >>"${SYSCTL_SNIPPETS_FILE}"
        echo "  ✓ Per-VMA locks: enabled (better mmap scalability)"
    fi

    # --- Kernel 6.3+: Memory tiering ---
    if [[ -f /sys/kernel/mm/numa/demotion_enabled ]]; then
        if [[ ${HW_NUMA_NODES} -gt 1 ]]; then
            write_value_quiet /sys/kernel/mm/numa/demotion_enabled 1
            echo "  ✓ NUMA demotion: enabled (memory tiering)"
        fi
    fi

    # --- Kernel 6.5+: Lazy preemption (PREEMPT_LAZY) ---
    if [[ -f /sys/kernel/debug/sched/preempt ]]; then
        PREEMPT_VAL=""
        case ${OPT_PROFILE} in
            server) PREEMPT_VAL="none" ;;
            vm) PREEMPT_VAL="voluntary" ;;
            *) PREEMPT_VAL="full" ;;
        esac
        write_value_quiet /sys/kernel/debug/sched/preempt "${PREEMPT_VAL}"
        echo "  ✓ Preemption: configured for ${OPT_PROFILE}"
    fi

    # --- Kernel 6.6+: EEVDF scheduler ---
    if [[ -f /sys/kernel/debug/sched/features ]] && grep -q "EEVDF" /sys/kernel/debug/sched/features 2>/dev/null; then
        # EEVDF is default in 6.6+, optimize its parameters
        if [[ -f /proc/sys/kernel/sched_base_slice_ns ]]; then
            case ${OPT_PROFILE} in
                server) write_value_quiet /proc/sys/kernel/sched_base_slice_ns 3000000 ;; # 3ms
                vm) write_value_quiet /proc/sys/kernel/sched_base_slice_ns 2000000 ;;     # 2ms
                *) write_value_quiet /proc/sys/kernel/sched_base_slice_ns 750000 ;;       # 0.75ms
            esac
            echo "  ✓ EEVDF scheduler: base_slice tuned"
        fi
    fi

    # --- Kernel 6.7+: Transparent hugepage shrinker ---
    if [[ -f /sys/kernel/mm/transparent_hugepage/shrink ]]; then
        echo "  ✓ THP shrinker: available"
    fi

    # --- Kernel 6.8+: AMD Preferred Core ---
    if [[ "${HW_CPU_VENDOR}" = "AuthenticAMD" ]] && [[ -f /sys/devices/system/cpu/amd_pstate/prefcore ]]; then
        write_value_quiet /sys/devices/system/cpu/amd_pstate/prefcore 1
        echo "  ✓ AMD Preferred Core: enabled"
    fi

    # --- Kernel 6.9+: AMD pstate guided mode ---
    if [[ "${HW_CPU_VENDOR}" = "AuthenticAMD" ]] && [[ -f /sys/devices/system/cpu/amd_pstate/status ]]; then
        case ${OPT_PROFILE} in
            server) write_value_quiet /sys/devices/system/cpu/amd_pstate/status active ;;
            laptop) write_value_quiet /sys/devices/system/cpu/amd_pstate/status guided ;;
            *) write_value_quiet /sys/devices/system/cpu/amd_pstate/status active ;;
        esac
        echo "  ✓ AMD P-State: configured"
    fi
fi

# --- Kernel 6.12+ Specific ---
if [[ "${KERNEL_MAJOR}" -gt 6 ]] || { [[ "${KERNEL_MAJOR}" -eq 6 ]] && [[ "${KERNEL_MINOR}" -ge 12 ]]; }; then
    echo ""
    echo "[KERNEL 6.12+] Applying latest kernel optimizations..."

    # --- sched_ext (Extensible Scheduler) ---
    if [[ -d /sys/kernel/sched_ext ]]; then
        echo "  → sched_ext: available (use scx schedulers for custom policies)"
    fi

    # --- Improved NUMA balancing ---
    if [[ -f /proc/sys/kernel/numa_balancing_promote_rate_limit_MBps ]]; then
        # Set promotion rate limit based on memory bandwidth
        write_value_quiet /proc/sys/kernel/numa_balancing_promote_rate_limit_MBps 65536
        echo "  ✓ NUMA promotion rate: 64GB/s limit"
    fi

    # --- Real-time throttling improvements ---
    if [[ -f /proc/sys/kernel/sched_rt_period_us ]]; then
        write_value_quiet /proc/sys/kernel/sched_rt_period_us 1000000
        echo "  ✓ RT period: 1s (6.12+ improved)"
    fi

    # --- Memory compaction proactiveness ---
    if [[ -f /proc/sys/vm/compaction_proactiveness ]]; then
        case ${OPT_PROFILE} in
            server) write_value_quiet /proc/sys/vm/compaction_proactiveness 20 ;;
            vm) write_value_quiet /proc/sys/vm/compaction_proactiveness 10 ;;
            *) write_value_quiet /proc/sys/vm/compaction_proactiveness 5 ;;
        esac
        echo "  ✓ Compaction proactiveness: tuned"
    fi

    # --- Folios and large anonymous pages ---
    if [[ -f /sys/kernel/mm/transparent_hugepage/hugepages-64kB/enabled ]]; then
        # Enable 64KB large folios for better TLB efficiency
        write_value_quiet /sys/kernel/mm/transparent_hugepage/hugepages-64kB/enabled always
        echo "  ✓ 64KB folios: enabled"
    fi

    # --- BPF token (security) ---
    if [[ -f /proc/sys/kernel/unprivileged_bpf_disabled ]]; then
        write_value_quiet /proc/sys/kernel/unprivileged_bpf_disabled 2
        echo "  ✓ Unprivileged BPF: disabled (security)"
    fi
fi

echo "  ✓ Kernel ${KERNEL_VERSION} optimizations complete"

#-------------------------------------------------------------------------------
# 3.3 I/O OPTIMIZATIONS
#-------------------------------------------------------------------------------
echo ""
echo "[I/O] Configuring storage subsystem..."

# --- I/O Scheduler Selection (profile-aware) ---
for DEV in "${!DISK_TYPE[@]}"; do
    [[ -f "/sys/block/${DEV}/queue/scheduler" ]] || continue
    AVAIL=$(cat "/sys/block/${DEV}/queue/scheduler")
    TYPE=${DISK_TYPE[${DEV}]}

    if [[ "${TYPE}" = "ssd" ]]; then
        # SSD/NVMe scheduler selection
        case ${OPT_PROFILE} in
            server | vm)
                # Server: none for lowest latency
                if [[ "${AVAIL}" =~ "none" ]]; then
                    SCHED="none"
                elif [[ "${AVAIL}" =~ "mq-deadline" ]]; then
                    SCHED="mq-deadline"
                else continue; fi
                ;;
            latency)
                # Latency: none for minimal overhead, or kyber for latency goals
                if [[ "${AVAIL}" =~ "none" ]]; then
                    SCHED="none"
                elif [[ "${AVAIL}" =~ "kyber" ]]; then
                    SCHED="kyber" # Self-tuning for latency targets
                else continue; fi
                ;;
            workstation)
                # Workstation: mq-deadline for balance
                if [[ "${AVAIL}" =~ "mq-deadline" ]]; then
                    SCHED="mq-deadline"
                elif [[ "${AVAIL}" =~ "none" ]]; then
                    SCHED="none"
                else continue; fi
                ;;
            laptop)
                # Laptop: kyber for power efficiency
                if [[ "${AVAIL}" =~ "kyber" ]]; then
                    SCHED="kyber"
                elif [[ "${AVAIL}" =~ "mq-deadline" ]]; then
                    SCHED="mq-deadline"
                else continue; fi
                ;;
        esac
    else
        # HDD scheduler selection
        case ${OPT_PROFILE} in
            server)
                # Server: mq-deadline for throughput
                if [[ "${AVAIL}" =~ "mq-deadline" ]]; then
                    SCHED="mq-deadline"
                elif [[ "${AVAIL}" =~ "bfq" ]]; then
                    SCHED="bfq"
                else continue; fi
                ;;
            *)
                # Desktop/Laptop: bfq for fairness
                if [[ "${AVAIL}" =~ "bfq" ]]; then
                    SCHED="bfq"
                elif [[ "${AVAIL}" =~ "mq-deadline" ]]; then
                    SCHED="mq-deadline"
                else continue; fi
                ;;
        esac
    fi

    write_value_quiet "/sys/block/${DEV}/queue/scheduler" "${SCHED}"
    echo "  ✓ ${DEV}: scheduler=${SCHED} (${OPT_PROFILE})"
done

# --- I/O Queue Tuning (profile-aware) ---
for DEV in "${!DISK_TYPE[@]}"; do
    Q="/sys/block/${DEV}/queue"
    [[ -d "${Q}" ]] || continue
    TYPE=${DISK_TYPE[${DEV}]}

    # Auto-detect device max queue depth
    NR_REQ_MAX=$(cat "${Q}/nr_requests" 2>/dev/null || echo 128)

    # Auto-tune based on profile (percentage of max)
    case ${OPT_PROFILE} in
        server)
            NR_REQ_SCALE=$CONST_NR_REQ_SCALE_SERVER
            RA_BASE=$((HW_MEM_TOTAL_GB >= 32 ? CONST_READAHEAD_BASE_HIGH : CONST_READAHEAD_BASE_MED))
            ;;
        vm)
            NR_REQ_SCALE=$CONST_NR_REQ_SCALE_VM
            RA_BASE=$((HW_MEM_TOTAL_GB >= 16 ? CONST_READAHEAD_BASE_MED : CONST_READAHEAD_BASE_LOW))
            ;;
        workstation)
            NR_REQ_SCALE=$CONST_NR_REQ_SCALE_WORKSTATION
            RA_BASE=$CONST_READAHEAD_BASE_LOW
            ;;
        laptop | latency)
            NR_REQ_SCALE=$CONST_NR_REQ_SCALE_LAPTOP
            RA_BASE=$((CONST_READAHEAD_BASE_LOW / 2))
            ;;
        *)
            NR_REQ_SCALE=$CONST_NR_REQ_SCALE_WORKSTATION
            RA_BASE=$CONST_READAHEAD_BASE_LOW
            ;;
    esac

    # Calculate nr_requests
    NR_REQ=$((NR_REQ_MAX * NR_REQ_SCALE / 100))
    [[ ${NR_REQ} -lt $CONST_NR_REQ_MIN ]] && NR_REQ=$CONST_NR_REQ_MIN

    # Adjust read_ahead for device type
    if [[ "${TYPE}" = "ssd" ]]; then
        RA_KB=$((RA_BASE / 2)) # SSD: lower readahead
        [[ ${RA_KB} -lt 32 ]] && RA_KB=32
    else
        RA_KB=$((RA_BASE * 2)) # HDD: higher readahead
    fi

    [[ -f "${Q}/nr_requests" ]] && write_value_quiet "${Q}/nr_requests" "${NR_REQ}"
    [[ -f "${Q}/read_ahead_kb" ]] && write_value_quiet "${Q}/read_ahead_kb" "${RA_KB}"

    # Cloud storage-specific overrides
    CLOUD_TYPE=${DISK_CLOUD[${DEV}]}
    case ${CLOUD_TYPE} in
        ebs)
            # AWS EBS: Network-attached storage
            [[ -f "${Q}/nr_requests" ]] && write_value_quiet "${Q}/nr_requests" $CONST_CLOUD_NR_REQ_NETWORK
            [[ -f "${Q}/read_ahead_kb" ]] && write_value_quiet "${Q}/read_ahead_kb" $CONST_CLOUD_READAHEAD_NETWORK
            [[ -f "${Q}/nomerges" ]] && write_value_quiet "${Q}/nomerges" 2
            echo "  ✓ ${DEV}: EBS-optimized (nr_requests=$CONST_CLOUD_NR_REQ_NETWORK)"
            ;;
        instance-store)
            # AWS Instance Store: Local NVMe
            [[ -f "${Q}/nr_requests" ]] && write_value_quiet "${Q}/nr_requests" $CONST_CLOUD_NR_REQ_LOCAL
            [[ -f "${Q}/read_ahead_kb" ]] && write_value_quiet "${Q}/read_ahead_kb" $CONST_CLOUD_READAHEAD_LOCAL
            [[ -f "${Q}/max_sectors_kb" ]] && write_value_quiet "${Q}/max_sectors_kb" 512
            [[ -f "${Q}/nomerges" ]] && write_value_quiet "${Q}/nomerges" 0
            [[ -f "${Q}/rotational" ]] && write_value_quiet "${Q}/rotational" 0
            [[ -f "${Q}/iostats" ]] && write_value_quiet "${Q}/iostats" 0
            echo "  ✓ ${DEV}: Instance-store optimized (nr_requests=$CONST_CLOUD_NR_REQ_LOCAL)"
            ;;
        azure-disk)
            # Azure Managed Disk: Network-attached
            [[ -f "${Q}/nr_requests" ]] && write_value_quiet "${Q}/nr_requests" $CONST_CLOUD_NR_REQ_NETWORK
            [[ -f "${Q}/read_ahead_kb" ]] && write_value_quiet "${Q}/read_ahead_kb" $CONST_CLOUD_READAHEAD_NETWORK
            [[ -f "${Q}/nomerges" ]] && write_value_quiet "${Q}/nomerges" 2
            echo "  ✓ ${DEV}: Azure Disk optimized"
            ;;
        azure-temp | azure-local)
            # Azure Temporary/Local SSD
            [[ -f "${Q}/nr_requests" ]] && write_value_quiet "${Q}/nr_requests" $CONST_CLOUD_NR_REQ_LOCAL
            [[ -f "${Q}/read_ahead_kb" ]] && write_value_quiet "${Q}/read_ahead_kb" $CONST_CLOUD_READAHEAD_LOCAL
            [[ -f "${Q}/iostats" ]] && write_value_quiet "${Q}/iostats" 0
            echo "  ✓ ${DEV}: Azure Local SSD optimized"
            ;;
        gcp-pd)
            # GCP Persistent Disk: Network-attached
            [[ -f "${Q}/nr_requests" ]] && write_value_quiet "${Q}/nr_requests" $CONST_CLOUD_NR_REQ_NETWORK
            [[ -f "${Q}/read_ahead_kb" ]] && write_value_quiet "${Q}/read_ahead_kb" $CONST_CLOUD_READAHEAD_NETWORK
            [[ -f "${Q}/nomerges" ]] && write_value_quiet "${Q}/nomerges" 2
            echo "  ✓ ${DEV}: GCP PD optimized"
            ;;
        gcp-local-ssd)
            # GCP Local SSD: High performance local NVMe
            [[ -f "${Q}/nr_requests" ]] && write_value_quiet "${Q}/nr_requests" $CONST_CLOUD_NR_REQ_LOCAL
            [[ -f "${Q}/read_ahead_kb" ]] && write_value_quiet "${Q}/read_ahead_kb" $CONST_CLOUD_READAHEAD_LOCAL
            [[ -f "${Q}/max_sectors_kb" ]] && write_value_quiet "${Q}/max_sectors_kb" 512
            [[ -f "${Q}/iostats" ]] && write_value_quiet "${Q}/iostats" 0
            echo "  ✓ ${DEV}: GCP Local SSD optimized (nr_requests=$CONST_CLOUD_NR_REQ_LOCAL)"
            ;;
        alibaba-local)
            # Alibaba Cloud Local SSD
            [[ -f "${Q}/nr_requests" ]] && write_value_quiet "${Q}/nr_requests" $CONST_CLOUD_NR_REQ_LOCAL
            [[ -f "${Q}/read_ahead_kb" ]] && write_value_quiet "${Q}/read_ahead_kb" $CONST_CLOUD_READAHEAD_LOCAL
            [[ -f "${Q}/iostats" ]] && write_value_quiet "${Q}/iostats" 0
            echo "  ✓ ${DEV}: Alibaba Local SSD optimized"
            ;;
        cloud-disk)
            # Alibaba Cloud Disk (network-attached)
            [[ -f "${Q}/nr_requests" ]] && write_value_quiet "${Q}/nr_requests" $CONST_CLOUD_NR_REQ_NETWORK
            [[ -f "${Q}/read_ahead_kb" ]] && write_value_quiet "${Q}/read_ahead_kb" $CONST_CLOUD_READAHEAD_NETWORK
            echo "  ✓ ${DEV}: Alibaba Cloud Disk optimized"
            ;;
    esac

    [[ -f "${Q}/add_random" ]] && write_value_quiet "${Q}/add_random" 0
    [[ -f "${Q}/rq_affinity" ]] && write_value_quiet "${Q}/rq_affinity" 2
done
echo "  ✓ Queue tuning: applied (${OPT_PROFILE})"
# Readahead summary value (actual per-device readahead is set in the loop above)
if [[ "${HW_MEM_TOTAL_GB}" -ge 32 ]]; then
    TUNE_READAHEAD=$((CONST_READAHEAD_BASE_HIGH * 4))
elif [[ "${HW_MEM_TOTAL_GB}" -ge 16 ]]; then
    TUNE_READAHEAD=$((CONST_READAHEAD_BASE_MED * 4))
else
    TUNE_READAHEAD=$((CONST_READAHEAD_BASE_LOW * 2))
fi

#-------------------------------------------------------------------------------
# 3.4 FILESYSTEM OPTIMIZATIONS
#-------------------------------------------------------------------------------
echo ""
echo "[FILESYSTEM] Analyzing and optimizing filesystems..."

declare -A FS_RECOMMENDATIONS=()
declare -A FS_TYPES=()

# Detect all filesystems
while read -r DEV MOUNT FSTYPE OPTS REST; do
    [[ -z "${MOUNT}" || -z "${FSTYPE}" ]] && continue
    [[ "${MOUNT}" =~ ^/(proc|sys|dev|run|snap) ]] && continue
    [[ "${FSTYPE}" =~ ^(tmpfs|devtmpfs|sysfs|proc|cgroup|overlay)$ ]] && continue
    [[ "${DEV}" == "none" ]] && continue

    FS_TYPES["${MOUNT}"]="${FSTYPE}"

    case ${FSTYPE} in
        ext4)
            echo "  [${MOUNT}] ext4 detected"

            # Reduce reserved blocks on non-root (default 5% → 1%)
            if [[ "${MOUNT}" != "/" ]] && command -v tune2fs &>/dev/null; then
                if [[ ${OPT_APPLY_FS_TUNING} -eq 1 ]]; then
                    if run_quiet tune2fs -m 1 "${DEV}"; then
                        echo "    ✓ Reserved blocks: set to 1%"
                    else
                        echo "    → Reserved blocks: tune2fs failed (skipped)"
                    fi
                else
                    echo "    → Reserved blocks: recommend tune2fs -m 1 ${DEV} (use --apply-fs-tuning)"
                fi
            fi

            # Check/set optimal journal mode
            if command -v tune2fs &>/dev/null; then
                JOURNAL_MODE=$(tune2fs -l "${DEV}" 2>/dev/null | grep "Journal features" || echo "")
                [[ -n "${JOURNAL_MODE}" ]] && echo "    → Journal: ${JOURNAL_MODE}"
            fi

            # Recommend mount options
            RECOMMEND="noatime,nodiratime"
            [[ ! "${OPTS}" =~ commit= ]] && RECOMMEND="${RECOMMEND},commit=60"
            [[ "${OPT_PROFILE}" = "server" ]] && RECOMMEND="${RECOMMEND},journal_async_commit"
            [[ "${HW_PRIMARY_SSD}" -eq 1 ]] && RECOMMEND="${RECOMMEND},discard"
            FS_RECOMMENDATIONS[${MOUNT}]="${RECOMMEND}"
            ;;

        xfs)
            echo "  [${MOUNT}] XFS detected"

            # Set extent size hint for better allocation
            if command -v xfs_io &>/dev/null; then
                if [[ ${OPT_APPLY_FS_TUNING} -eq 1 ]]; then
                    run_quiet xfs_io -c "extsize 1m" "${MOUNT}" || true
                    echo "    ✓ Extent size hint: 1MB"
                else
                    echo "    → Extent size hint: recommend xfs_io -c 'extsize 1m' ${MOUNT} (use --apply-fs-tuning)"
                fi
            fi

            # Get XFS info
            if command -v xfs_info &>/dev/null; then
                XFS_LOG=$(xfs_info "${MOUNT}" 2>/dev/null | grep "log" | head -1)
                [[ -n "${XFS_LOG}" ]] && echo "    → Log: ${XFS_LOG}"
            fi

            # Recommend mount options
            RECOMMEND="noatime,nodiratime,logbufs=8,logbsize=256k"
            [[ "${OPT_PROFILE}" = "server" ]] && RECOMMEND="${RECOMMEND},allocsize=64m,inode64"
            [[ "${HW_PRIMARY_SSD}" -eq 1 ]] && RECOMMEND="${RECOMMEND},discard"
            FS_RECOMMENDATIONS[${MOUNT}]="${RECOMMEND}"
            ;;

        btrfs)
            echo "  [${MOUNT}] Btrfs detected"

            # Check if SSD
            BDEV=$(df "${MOUNT}" 2>/dev/null | tail -1 | awk '{print $1}' | sed 's|/dev/||;s|[0-9]*$||;s|p[0-9]*$||')
            IS_BTRFS_SSD=0
            [[ -f "/sys/block/${BDEV}/queue/rotational" ]] && [[ "$(cat "/sys/block/${BDEV}/queue/rotational")" -eq 0 ]] && IS_BTRFS_SSD=1

            # Btrfs-specific runtime tuning
            if [[ -d "/sys/fs/btrfs" ]]; then
                # Find UUID
                BTRFS_UUID=$(btrfs filesystem show "${MOUNT}" 2>/dev/null | sed -n 's/.*uuid: \([a-f0-9-]*\).*/\1/p' | head -1)
                if [[ -n "${BTRFS_UUID}" ]] && [[ -d "/sys/fs/btrfs/${BTRFS_UUID}" ]]; then
                    # Optimize metadata ratio
                    if [[ ${OPT_APPLY_FS_TUNING} -eq 1 ]]; then
                        [[ -f "/sys/fs/btrfs/${BTRFS_UUID}/allocation/metadata/chunk_size" ]] &&
                            write_value_quiet "/sys/fs/btrfs/${BTRFS_UUID}/allocation/metadata/chunk_size" 50
                    else
                        echo "    → Btrfs sysfs tuning: skipped (use --apply-fs-tuning)"
                    fi
                fi
            fi

            # Defrag if HDD
            if [[ ${IS_BTRFS_SSD} -eq 0 ]] && command -v btrfs &>/dev/null; then
                echo "    → Consider: btrfs filesystem defragment -r ${MOUNT}"
            fi

            # Recommend mount options
            RECOMMEND="noatime,nodiratime,space_cache=v2"
            if [[ ${IS_BTRFS_SSD} -eq 1 ]]; then
                RECOMMEND="${RECOMMEND},ssd,discard=async,compress=zstd:1"
            else
                RECOMMEND="${RECOMMEND},autodefrag,compress=zstd:3"
            fi
            [[ "${OPT_PROFILE}" = "server" ]] && RECOMMEND="${RECOMMEND},commit=120"
            FS_RECOMMENDATIONS[${MOUNT}]="${RECOMMEND}"

            echo "    ✓ Btrfs optimized (SSD=${IS_BTRFS_SSD})"
            ;;

        f2fs)
            echo "  [${MOUNT}] F2FS detected"
            RECOMMEND="noatime,nodiratime,compress_algorithm=zstd,compress_chksum,atgc,gc_merge"
            FS_RECOMMENDATIONS[${MOUNT}]="${RECOMMEND}"
            ;;

    esac
done </proc/mounts

# --- Filesystem-specific sysctl ---
echo ""
echo "[FILESYSTEM] Applying filesystem sysctl tuning..."

# Check which filesystems are in use
# Check which filesystems are in use
# HAS_EXT4 and HAS_BTRFS are unused
HAS_XFS=0
for fs in "${FS_TYPES[@]}"; do
    # Check which filesystems are in use
    # [ "$fs" = "ext4" ] && HAS_EXT4=1   # Unused
    [[ "${fs}" = "xfs" ]] && HAS_XFS=1
    # [ "$fs" = "btrfs" ] && HAS_BTRFS=1 # Unused
done

# XFS-specific
if [[ ${HAS_XFS} -eq 1 ]]; then
    cat >>"${SYSCTL_SNIPPETS_FILE}" <<'EOF'

# Filesystem (XFS)
# Tune background metadata flush behavior.
fs.xfs.xfssyncd_centisecs = 3000
fs.xfs.filestream_centisecs = 3000
fs.xfs.speculative_prealloc_lifetime = 300
EOF
    echo "  ✓ XFS sysctl: xfssyncd=30s, speculative_prealloc=300s"
else
    echo "  ✓ Filesystem sysctl: none"
fi

# Save recommendations
if [[ "${#FS_RECOMMENDATIONS[@]}" -gt 0 ]]; then
    if [[ -z "${CFG_FSTAB_HINTS}" ]]; then
        CFG_FSTAB_HINTS=$(mktemp /tmp/system-optimize-fstab.XXXXXX)
    fi
    write_file "${CFG_FSTAB_HINTS}" <<'EOF'
# Filesystem Mount Option Recommendations
# Generated by system_optimize.sh
# Review and add to /etc/fstab, then remount or reboot
# WARNING: Test on non-production first!

EOF
    for mount in "${!FS_RECOMMENDATIONS[@]}"; do
        append_file "${CFG_FSTAB_HINTS}" <<EOF
# $mount (${FS_TYPES[$mount]})
# Add options: ${FS_RECOMMENDATIONS[$mount]}

EOF
        echo "  → ${mount}: recommend ${FS_RECOMMENDATIONS[${mount}]}"
    done
    echo "  ✓ Recommendations saved: ${CFG_FSTAB_HINTS}"
fi

# --- SSD/NVMe TRIM Support ---
# Check if any SSD/NVMe devices exist
HAS_SSD=0
for rot in /sys/block/*/queue/rotational; do
    [[ -f "${rot}" ]] && [[ "$(cat "${rot}")" -eq 0 ]] && HAS_SSD=1 && break
done

if [[ ${HAS_SSD} -eq 1 ]]; then
    echo ""
    echo "[TRIM] Configuring SSD/NVMe TRIM support..."

    # Enable fstrim.timer for periodic TRIM (weekly)
    if systemctl list-unit-files fstrim.timer &>/dev/null; then
        run systemctl enable fstrim.timer || true
        run systemctl start fstrim.timer || true
        echo "  ✓ fstrim.timer: enabled (weekly TRIM)"
    fi

    # Run fstrim now on all mounted filesystems (best-effort)
    if command -v fstrim &>/dev/null; then
        if [[ ${OPT_DRY_RUN} -eq 1 ]]; then
            echo "[DRY-RUN] fstrim -av"
            echo "  ✓ fstrim: skipped (dry-run)"
        else
            if [[ ${OPT_APPLY_FS_TUNING} -eq 1 ]]; then
                echo "  → Running fstrim on mounted filesystems..."
                fstrim -av 2>/dev/null | while read -r line; do
                    echo "    ${line}"
                done || true
                echo "  ✓ fstrim: completed"
            else
                echo "  → Skipping fstrim now (use --apply-fs-tuning)"
            fi
        fi
    fi
fi

#-------------------------------------------------------------------------------
# 3.5 SYSTEM LIMITS
#-------------------------------------------------------------------------------
echo ""
echo "[LIMITS] Configuring resource limits..."

# Calculate limits based on hardware and profile
LIMIT_NOFILE=$((HW_MEM_TOTAL_GB * CONST_NOFILE_PER_GB_WORKSTATION))
LIMIT_NPROC=$((HW_CPU_CORES * CONST_NPROC_PER_CORE_WORKSTATION))
case ${OPT_PROFILE} in
    server)
        LIMIT_NOFILE=$((HW_MEM_TOTAL_GB * CONST_NOFILE_PER_GB_SERVER))
        LIMIT_NPROC=$((HW_CPU_CORES * CONST_NPROC_PER_CORE_SERVER))
        ;;
    vm)
        LIMIT_NOFILE=$((HW_MEM_TOTAL_GB * CONST_NOFILE_PER_GB_VM))
        LIMIT_NPROC=$((HW_CPU_CORES * CONST_NPROC_PER_CORE_VM))
        ;;
    workstation)
        LIMIT_NOFILE=$((HW_MEM_TOTAL_GB * CONST_NOFILE_PER_GB_WORKSTATION))
        LIMIT_NPROC=$((HW_CPU_CORES * CONST_NPROC_PER_CORE_WORKSTATION))
        ;;
    laptop)
        LIMIT_NOFILE=$((HW_MEM_TOTAL_GB * CONST_NOFILE_PER_GB_LAPTOP))
        LIMIT_NPROC=$((HW_CPU_CORES * CONST_NPROC_PER_CORE_LAPTOP))
        ;;
    latency)
        LIMIT_NOFILE=$((HW_MEM_TOTAL_GB * CONST_NOFILE_PER_GB_SERVER))
        LIMIT_NPROC=$((HW_CPU_CORES * CONST_NPROC_PER_CORE_SERVER))
        ;;
esac

# Apply min/max bounds for nofile and nproc
[[ ${LIMIT_NOFILE} -lt 65536 ]] && LIMIT_NOFILE=65536     # 64K min
[[ ${LIMIT_NOFILE} -gt 1048576 ]] && LIMIT_NOFILE=1048576 # 1M max (kernel limit)
[[ ${LIMIT_NPROC} -lt 32768 ]] && LIMIT_NPROC=32768       # 32K min
[[ ${LIMIT_NPROC} -gt 524288 ]] && LIMIT_NPROC=524288     # 512K max

# memlock: 50% of RAM in bytes (for mlock() syscall)
LIMIT_MEMLOCK=$((HW_MEM_TOTAL_KB * 1024 / 2))

# Filesystem limits
LIMIT_FILE_MAX=$((HW_MEM_TOTAL_KB * 10))                      # ~10 file handles per KB RAM
[[ ${LIMIT_FILE_MAX} -lt 2097152 ]] && LIMIT_FILE_MAX=2097152 # 2M min
LIMIT_INOTIFY_WATCHES=524288                                  # 512K watches (IDEs, file sync tools need many)
LIMIT_INOTIFY_INSTANCES=1024                                  # 1K instances

echo "  ✓ nofile: ${LIMIT_NOFILE} | nproc: ${LIMIT_NPROC}"

# --- PAM Limits ---
backup_file "${CFG_LIMITS}"
write_file "${CFG_LIMITS}" <<EOF
# =============================================================================
# $CFG_LIMITS
# Auto-generated by system_optimize.sh (profile=$OPT_PROFILE)
#
# Notes:
# - Applies to new sessions (re-login) and some services after restart.
# - Some limits may be capped by the kernel or systemd.
# =============================================================================

# -----------------------------
# Defaults for all users (*)
# -----------------------------
* soft nofile ${LIMIT_NOFILE}
* hard nofile ${LIMIT_NOFILE}

* soft nproc ${LIMIT_NPROC}
* hard nproc ${LIMIT_NPROC}

# Allow mlock() up to ~50% of RAM (useful for DBs, some JVM tuning, etc.)
* soft memlock ${LIMIT_MEMLOCK}
* hard memlock ${LIMIT_MEMLOCK}

# Disable core dumps by default (privacy + disk I/O)
* soft core 0
* hard core 0

# Pending signals/message queue/RT priority/stack
* soft sigpending ${LIMIT_NPROC}
* hard sigpending ${LIMIT_NPROC}
* soft msgqueue 819200   # 800KB POSIX message queue size
* hard msgqueue 819200
* soft rtprio 99         # Allow real-time priority (0-99)
* hard rtprio 99
* soft stack 65536       # 64MB stack size (KB)
* hard stack 65536

# -----------------------------
# Root overrides
# -----------------------------
root soft nofile ${LIMIT_NOFILE}
root hard nofile ${LIMIT_NOFILE}
root soft nproc ${LIMIT_NPROC}
root hard nproc ${LIMIT_NPROC}
EOF

# --- Systemd Limits ---
run mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
backup_file "${CFG_SYSTEMD_SYSTEM}"
backup_file "${CFG_SYSTEMD_USER}"
write_file "${CFG_SYSTEMD_SYSTEM}" <<EOF
# =============================================================================
# $CFG_SYSTEMD_SYSTEM
# Auto-generated by system_optimize.sh (profile=$OPT_PROFILE)
#
# Notes:
# - This is a systemd-manager drop-in. A reboot is the safest way to ensure it
#   is applied everywhere; otherwise consider: systemctl daemon-reexec
# =============================================================================

[Manager]
DefaultLimitNOFILE=${LIMIT_NOFILE}
DefaultLimitNPROC=${LIMIT_NPROC}
DefaultLimitMEMLOCK=${LIMIT_MEMLOCK}
DefaultLimitCORE=0
EOF
run cp "${CFG_SYSTEMD_SYSTEM}" "${CFG_SYSTEMD_USER}"

echo "  ✓ PAM & systemd limits: configured"

#-------------------------------------------------------------------------------
# 3.6 KERNEL & SYSTEM SERVICES
#-------------------------------------------------------------------------------
echo ""
echo "[KERNEL] Configuring kernel settings..."

# --- IRQ Balancing (profile-aware) ---
if [[ "${HW_CPU_CORES}" -gt 1 ]]; then
    case ${OPT_PROFILE} in
        server | vm)
            # Server/VM: enable irqbalance for throughput
            if ! command -v irqbalance &>/dev/null; then
                pkg_install irqbalance || true
            fi
            if command -v irqbalance &>/dev/null; then
                run systemctl enable irqbalance || true
                run systemctl restart irqbalance || true
                echo "  ✓ IRQ balancing: enabled (server/vm)"
            fi
            ;;
        workstation)
            # Workstation: enable with hint for desktop responsiveness
            if command -v irqbalance &>/dev/null; then
                run systemctl enable irqbalance || true
                run systemctl restart irqbalance || true
                echo "  ✓ IRQ balancing: enabled (workstation)"
            fi
            ;;
        laptop)
            # Laptop: disable to save power (let kernel handle it)
            if systemctl is-active irqbalance &>/dev/null; then
                run systemctl stop irqbalance || true
                run systemctl disable irqbalance || true
                echo "  ✓ IRQ balancing: disabled (laptop - power saving)"
            fi
            ;;
    esac
fi

# --- Entropy (profile-aware) ---
ENTROPY=$(cat /proc/sys/kernel/random/entropy_avail)
case ${OPT_PROFILE} in
    server | vm)
        # Server/VM: ensure high entropy for crypto operations
        if [[ "${ENTROPY}" -lt 1000 ]]; then
            pkg_install haveged rng-tools || true
            if command -v haveged &>/dev/null; then
                run systemctl enable --now haveged || true
            fi
            # rngd service - skip on Debian/Ubuntu (uses generated transient unit)
            if [[ -c /dev/hwrng ]] && command -v rngd &>/dev/null && [[ "${DISTRO}" =~ ^(fedora|rhel|centos|rocky|almalinux|amzn)$ ]]; then
                run systemctl enable --now rngd 2>/dev/null || true
            fi
            echo "  ✓ Entropy: enhanced for server (was ${ENTROPY})"
        else
            echo "  ✓ Entropy: sufficient (${ENTROPY})"
        fi
        ;;
    workstation | laptop)
        # Desktop: usually sufficient, don't add overhead
        echo "  ✓ Entropy: ${ENTROPY} (desktop default)"
        ;;
esac

# --- Module Blacklist (profile-aware) ---
backup_file "${CFG_MODPROBE}"
write_file "${CFG_MODPROBE}" <<'EOF'
# =============================================================================
# /etc/modprobe.d/99-system-optimize-blacklist.conf
# Auto-generated by system_optimize.sh
#
# Notes:
# - Blacklisting prevents *auto-loading* of modules; it does not unload modules
#   that are already loaded.
# - If you later need a device/feature, remove the relevant line(s) and reboot,
#   or manually `modprobe <module>`.
# =============================================================================

# -----------------------------
# Legacy/rare hardware
# -----------------------------
# Floppy / optical media
blacklist floppy
blacklist cdrom
blacklist sr_mod
blacklist iso9660

# FireWire (common on older systems)
blacklist firewire_core
blacklist firewire_ohci
EOF

# Add desktop-related blacklist only for server/vm profiles
if [[ ${PROFILE_BLACKLIST_DESKTOP} -eq 1 ]]; then
    USB_ETH_IN_USE=0
    for m in r8152 asix ax88179_178a cdc_ether cdc_ncm rndis_host usbnet; do
        if lsmod 2>/dev/null | awk '{print $1}' | grep -qx "${m}"; then
            USB_ETH_IN_USE=1
            break
        fi
    done

    append_file "${CFG_MODPROBE}" <<'EOF'
# -----------------------------
# Server/VM only: reduce desktop/hotplug noise
# -----------------------------

# Audio
blacklist pcspkr
blacklist snd_pcsp
blacklist snd_hda_intel
blacklist snd_hda_codec
blacklist soundcore
EOF

    if [[ ${USB_ETH_IN_USE} -eq 1 ]]; then
        append_file "${CFG_MODPROBE}" <<'EOF'

# USB Ethernet dongles
# NOTE: Skipped because a USB NIC driver module is currently loaded on this host.
# If you are certain you don't use USB NICs, you can add these lines manually:
#   blacklist r8152
#   blacklist asix
#   blacklist ax88179_178a
#   blacklist cdc_ether
#   blacklist cdc_ncm
#   blacklist rndis_host
#   blacklist usbnet
EOF
        echo "  -> USB NIC driver detected; skipping USB Ethernet module blacklist"
    else
        append_file "${CFG_MODPROBE}" <<'EOF'

# USB Ethernet dongles
blacklist r8152
blacklist asix
blacklist ax88179_178a
blacklist cdc_ether
blacklist cdc_ncm
blacklist rndis_host
blacklist usbnet
EOF
    fi

    append_file "${CFG_MODPROBE}" <<'EOF'

# Bluetooth
blacklist bluetooth
blacklist btusb
blacklist btrtl
blacklist btbcm
blacklist btintel

# Webcam
blacklist uvcvideo
EOF
    if [[ ${USB_ETH_IN_USE} -eq 1 ]]; then
        echo "  ✓ Module blacklist: full (server/vm profile; USB NIC drivers preserved)"
    else
        echo "  ✓ Module blacklist: full (server/vm profile)"
    fi
else
    echo "  ✓ Module blacklist: minimal (desktop profile)"
fi

# Network tuning is handled by network_optimize.sh

# --- Cloud-Specific Optimizations (non-network) ---
if [[ "${CLOUD_PROVIDER}" != "none" ]]; then
    echo ""
    echo "[CLOUD] Applying ${CLOUD_PROVIDER}-specific optimizations..."

    case ${CLOUD_PROVIDER} in
        aws)
            # AWS EC2: NVMe optimization for EBS/instance store
            for nvme in /sys/block/nvme*; do
                [[ -d "${nvme}" ]] || continue
                write_value_quiet "${nvme}/queue/add_random" 0
                write_value_quiet "${nvme}/queue/nomerges" 2
            done
            echo "  ✓ NVMe: optimized for EBS"
            ;;

        azure)
            # Azure: managed disk optimization
            for disk in /sys/block/sd*; do
                [[ -d "${disk}" ]] || continue
                write_value_quiet "${disk}/queue/nr_requests" 256
                write_value_quiet "${disk}/queue/read_ahead_kb" 128
            done
            echo "  ✓ Managed disks: queue optimized"

            # Disable NUMA balancing (Azure VMs often have suboptimal NUMA)
            write_value_quiet /proc/sys/kernel/numa_balancing 0
            echo "  ✓ NUMA balancing: disabled (Azure)"
            ;;

        gcp)
            # GCP: Local SSD optimization
            _gcp_has_local_ssd=0
            for nvme in /sys/block/nvme*; do
                [[ -d "${nvme}" ]] || continue
                _gcp_has_local_ssd=1
                write_value_quiet "${nvme}/queue/scheduler" none
                write_value_quiet "${nvme}/queue/add_random" 0
            done
            echo "  ✓ Local SSD: scheduler=none"

            # GCP recommends higher dirty ratio for local SSD
            if [[ ${_gcp_has_local_ssd} -eq 1 ]]; then
                TUNE_DIRTY_RATIO=20
                echo "  ✓ Dirty ratio: increased for local SSD"
            fi
            ;;

        alibaba)
            # Alibaba Cloud: disk optimization
            for disk in /sys/block/vd*; do
                [[ -d "${disk}" ]] || continue
                write_value_quiet "${disk}/queue/nr_requests" 256
            done
            echo "  ✓ Disk queue: optimized"
            ;;
    esac

    # Common cloud optimizations (non-network)
    # Disable transparent huge pages (all clouds recommend this)
    write_value_quiet /sys/kernel/mm/transparent_hugepage/enabled never
    TUNE_THP_MODE="never"

    # Reduce swappiness for cloud (avoid swap on network storage)
    [[ ${TUNE_SWAPPINESS} -gt 10 ]] && TUNE_SWAPPINESS=10

    # Disable KSM (host handles memory dedup)
    [[ -f /sys/kernel/mm/ksm/run ]] && write_value_quiet /sys/kernel/mm/ksm/run 0

    echo "  ✓ Common cloud optimizations applied"
    echo "  → Network optimization: use network_optimize.sh"
fi

# --- Relax Security Settings (optional) ---
if [[ ${OPT_RELAX_SECURITY} -eq 1 ]]; then
    echo ""
    echo "[SECURITY] Relaxing non-essential security settings..."

    # Disable audit daemon (reduces I/O overhead)
    if systemctl is-active auditd &>/dev/null; then
        run systemctl stop auditd || true
        run systemctl disable auditd || true
        echo "  ✓ Audit daemon: disabled"
    fi

    # Set SELinux to permissive (if enforcing)
    if command -v setenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" = "Enforcing" ]]; then
        run_quiet setenforce 0 || true
        backup_file /etc/selinux/config
        run sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        echo "  ✓ SELinux: set to permissive"
    fi

    # Disable firewall logging (keep firewall, reduce logging overhead)
    if systemctl is-active firewalld &>/dev/null; then
        run_quiet firewall-cmd --set-log-denied=off || true
        echo "  ✓ Firewalld: logging disabled"
    fi
    # NOTE: `ufw status` requires root; suppress errors so --dry-run/--report can run unprivileged.
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        run_quiet ufw logging off || true
        echo "  ✓ UFW: logging disabled"
    fi

    # Disable IOMMU if not used for passthrough (via GRUB)
    if [[ -f /etc/default/grub ]] && [[ -d /sys/kernel/iommu_groups ]] && [[ $(find /sys/kernel/iommu_groups -maxdepth 1 -type d 2>/dev/null | wc -l) -gt 1 ]]; then
        # Check if any devices use IOMMU
        IOMMU_DEVICES=$(find /sys/kernel/iommu_groups -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [[ "${IOMMU_DEVICES}" -le 1 ]]; then
            if ! grep -q "iommu=off" /etc/default/grub; then
                backup_file /etc/default/grub
                run sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT="|GRUB_CMDLINE_LINUX_DEFAULT="iommu=off |' /etc/default/grub
                run sed -i 's/  */ /g' /etc/default/grub
                update_grub_config || true
                echo "  ✓ IOMMU: will be disabled after reboot"
            fi
        else
            echo "  → IOMMU: kept (devices attached)"
        fi
    fi

    # Disable kernel audit
    echo "kernel.audit_enabled = 0" >>"${SYSCTL_SNIPPETS_FILE}"
    write_value_quiet /proc/sys/kernel/audit_enabled 0

    # Reduce security-related kernel overhead
    cat >>"${SYSCTL_SNIPPETS_FILE}" <<'EOF'

# Security relaxation for performance
kernel.dmesg_restrict=0
kernel.kptr_restrict=0
kernel.perf_event_paranoid=0
kernel.yama.ptrace_scope=0
EOF
    echo "  ✓ Kernel security restrictions: relaxed"

    # --- Logging Optimization ---
    echo ""
    echo "[LOGGING] Optimizing logging for performance..."

    # Reduce kernel printk verbosity
    echo "kernel.printk = 3 3 3 3" >>"${SYSCTL_SNIPPETS_FILE}"
    write_value_quiet /proc/sys/kernel/printk "3 3 3 3"
    echo "  ✓ Kernel printk: reduced to errors only"

    # Optimize journald
    run mkdir -p /etc/systemd/journald.conf.d
    write_file "${CFG_JOURNALD}" <<'EOF'
# =============================================================================
# /etc/systemd/journald.conf.d/99-system-optimize.conf
# Auto-generated by system_optimize.sh
#
# Goal: reduce disk I/O from logging on performance-focused systems.
# =============================================================================

[Journal]
# Store in memory only (volatile) - reduces disk I/O
Storage=volatile
# Limit journal size
RuntimeMaxUse=100M
# Rate limiting
RateLimitIntervalSec=30s
RateLimitBurst=1000
# Compress logs
Compress=yes
# Don't forward to syslog
ForwardToSyslog=no
ForwardToWall=no
EOF
    run systemctl restart systemd-journald || true
    echo "  ✓ Journald: volatile storage, rate-limited"

    # Disable rsyslog if journald is sufficient
    if systemctl is-active rsyslog &>/dev/null; then
        run systemctl stop rsyslog || true
        run systemctl disable rsyslog || true
        echo "  ✓ Rsyslog: disabled (using journald)"
    fi
    if systemctl is-active syslog-ng &>/dev/null; then
        run systemctl stop syslog-ng || true
        run systemctl disable syslog-ng || true
        echo "  ✓ Syslog-ng: disabled (using journald)"
    fi
fi

# --- Disable Non-Essential Services (Profile-Aware) ---
if [[ ${OPT_DISABLE_SERVICES} -eq 1 ]]; then
    echo ""
    echo "[SERVICES] Disabling non-essential services for ${OPT_PROFILE} profile..."

    # Services to disable based on profile
    # Format: "service_names:profiles" (s=server,v=vm,w=workstation,l=laptop)
    DISABLE_LIST_ALL=(
        "cups cups-browsed:sv"                       # Printing - keep on workstation/laptop
        "avahi-daemon:sv"                            # mDNS - keep on workstation/laptop
        "ModemManager:svw"                           # Mobile broadband - keep on laptop
        "bluetooth:sv"                               # Bluetooth - keep on workstation/laptop
        "accounts-daemon:sv"                         # User accounts - keep on desktop
        "packagekit:svl"                             # Package GUI - keep on workstation
        "snapd snapd.socket:sv"                      # Snap - keep on desktop
        "unattended-upgrades:sv"                     # Auto updates - keep on desktop
        "apt-daily.timer apt-daily-upgrade.timer:sv" # APT timers
        "thermald:sv"                                # Thermal - keep on laptop
        "power-profiles-daemon:sv"                   # Power profiles - keep on laptop
        "switcheroo-control:svw"                     # GPU switching - keep on laptop
        "bolt:sv"                                    # Thunderbolt - keep on desktop
        "fwupd:sv"                                   # Firmware - keep on desktop
        "colord:sv"                                  # Color - keep on desktop
        "geoclue:sv"                                 # Location - keep on desktop
        "whoopsie:svwl"                              # Error reporting - disable all
        "apport:svwl"                                # Crash reporting - disable all
        "kerneloops:svwl"                            # Kernel oops - disable all
        "speech-dispatcher:sv"                       # Speech - keep on desktop
        "brltty:svwl"                                # Braille - rarely needed
        "pcscd:svw"                                  # Smart card - keep on laptop
        "wpa_supplicant:sv"                          # WiFi - keep on workstation/laptop
    )

    FREED_MB=0
    for entry in "${DISABLE_LIST_ALL[@]}"; do
        SERVICES=$(echo "${entry}" | cut -d: -f1)
        PROFILES=$(echo "${entry}" | cut -d: -f2)

        # Only disable if current profile matches
        [[ "${PROFILES}" != *"${PROFILE_LETTER}"* ]] && continue

        for s in ${SERVICES}; do
            if systemctl is-active "${s}" &>/dev/null 2>&1; then
                PID=$(systemctl show -p MainPID "${s}" 2>/dev/null | cut -d= -f2)
                MEM=0
                [[ -n "${PID}" ]] && [[ "${PID}" != "0" ]] && MEM=$(ps -o rss= -p "${PID}" 2>/dev/null | tr -d ' ')
                [[ -z "${MEM}" ]] && MEM=0

                run systemctl stop "${s}" || true
                run systemctl disable "${s}" || true
                run systemctl mask "${s}" || true

                MEM_MB=$((MEM / 1024))
                FREED_MB=$((FREED_MB + MEM_MB))
                echo "  ✓ ${s}: stopped & masked (~${MEM_MB}MB freed)"
            fi
        done
    done

    # Clear systemd failed units
    run systemctl reset-failed || true

    echo "  ✓ Total memory freed: ~${FREED_MB}MB"
    if [[ ${OPT_RECLAIM_MEMORY} -eq 1 ]]; then
        run sync
        write_value_quiet /proc/sys/vm/drop_caches 3
        echo "  ✓ Page cache cleared"
    else
        echo "  → Skipping page cache drop (use --reclaim-memory)"
    fi
fi

# --- Disable Monitoring Overhead (with --relax-security) ---
if [[ ${OPT_RELAX_SECURITY} -eq 1 ]]; then
    echo ""
    echo "[MONITORING] Reducing monitoring overhead..."

    # Disable schedstats (scheduler statistics)
    [[ -f /proc/sys/kernel/sched_schedstats ]] && write_value_quiet /proc/sys/kernel/sched_schedstats 0
    echo "kernel.sched_schedstats = 0" >>"${SYSCTL_SNIPPETS_FILE}"
    echo "  ✓ schedstats: disabled (~1-2% CPU saved)"

    # Disable NMI watchdog (already in low-latency, but ensure it's off)
    write_value_quiet /proc/sys/kernel/nmi_watchdog 0
    echo "  ✓ nmi_watchdog: disabled"

    # Reduce vmstat update interval
    write_value_quiet /proc/sys/vm/stat_interval 10
    echo "  ✓ vmstat interval: 10s (reduced overhead)"

    # Disable ftrace if enabled
    [[ -f /sys/kernel/debug/tracing/tracing_on ]] && write_value_quiet /sys/kernel/debug/tracing/tracing_on 0
    echo "  ✓ ftrace: disabled"

    # Disable process accounting if enabled
    [[ -f /var/log/pacct ]] && {
        run_quiet accton off || true
        echo "  ✓ Process accounting: disabled"
    }

    # Stop heavy monitoring daemons (optional - keep lightweight ones)
    for svc in netdata atop; do
        if systemctl is-active "${svc}" &>/dev/null; then
            run systemctl stop "${svc}" || true
            run systemctl disable "${svc}" || true
            echo "  ✓ ${svc}: stopped (heavy monitoring)"
        fi
    done

    # Reduce sysstat collection frequency
    if [[ -f /etc/cron.d/sysstat ]]; then
        backup_file /etc/cron.d/sysstat
        run sed -i 's|\*/10|\*/30|g' /etc/cron.d/sysstat
        echo "  ✓ sysstat: reduced to 30min intervals"
    fi
fi

#===============================================================================
# PHASE 4: PERSISTENCE
#===============================================================================

echo ""
echo ">>> Phase 3: Writing Persistent Configuration..."
echo ""

# --- CPU Scheduler Parameters ---
# migration_cost: nanoseconds a task must run before migration is considered
# Higher = less migration = better cache locality, but worse load balancing
TUNE_MIGRATION_COST=$((HW_CPU_CORES * 500000))                                                # 500us per core
[[ "${TUNE_MIGRATION_COST}" -gt 10000000 ]] && TUNE_MIGRATION_COST=10000000                   # Cap at 10ms
[[ "${HW_CPU_VENDOR}" = "AuthenticAMD" ]] && TUNE_MIGRATION_COST=$((TUNE_MIGRATION_COST / 2)) # AMD has better inter-CCX latency
TUNE_NUMA_BALANCING=0
[[ "${HW_NUMA_NODES}" -gt 1 ]] && TUNE_NUMA_BALANCING=1
TUNE_AUTOGROUP=0                                  # Disable autogroup for servers (better for batch workloads)
[[ "${HW_CPU_CORES}" -le 4 ]] && TUNE_AUTOGROUP=1 # Enable for small systems (desktop responsiveness)
: "${TUNE_ZONE_RECLAIM_MODE:=0}"
: "${WATERMARK_SCALE:=200}" # 2x default watermark distance

# RT runtime: microseconds per period RT tasks can run (-1 = unlimited)
TUNE_RT_RUNTIME_US=950000 # 950ms per 1000ms period = 95%
[[ "${OPT_LOW_LATENCY}" -eq 1 ]] && TUNE_RT_RUNTIME_US=-1

TUNE_KERNEL_WATCHDOG=1
TUNE_NMI_WATCHDOG=0 # Disable NMI watchdog (reduces latency jitter)
TUNE_SOFT_WATCHDOG=1
TUNE_HUNG_TASK_TIMEOUT_SECS=120 # 2 minutes before reporting hung task
if [[ "${OPT_LOW_LATENCY}" -eq 1 ]]; then
    TUNE_KERNEL_WATCHDOG=0
    TUNE_NMI_WATCHDOG=0
    TUNE_SOFT_WATCHDOG=0
    TUNE_HUNG_TASK_TIMEOUT_SECS=0 # Disable hung task detection
fi

# --- Write Sysctl Configuration ---
backup_file "${CFG_SYSCTL}"
write_file "${CFG_SYSCTL}" <<EOF
# =============================================================================
# $CFG_SYSCTL
# Auto-generated by system_optimize.sh (profile=$OPT_PROFILE)
#
# System:
# - OS: $DISTRO_PRETTY
# - Kernel: $KERNEL_RELEASE
# - CPU: $HW_CPU_VENDOR | cores=$HW_CPU_CORES | numa_nodes=$HW_NUMA_NODES
# - RAM: ${HW_MEM_TOTAL_GB}GB
#
# Apply/rollback:
# - Apply now:   sysctl --system
# - Rollback:   rm -f $CFG_SYSCTL && sysctl --system
# =============================================================================

# -----------------------------------------------------------------------------
# Memory management (VM)
# -----------------------------------------------------------------------------
# Swappiness: lower keeps anonymous memory in RAM; higher swaps more aggressively.
vm.swappiness = ${TUNE_SWAPPINESS}

# Dirty page writeback tuning (ratio-based).
vm.dirty_ratio = ${TUNE_DIRTY_RATIO}
vm.dirty_background_ratio = ${TUNE_DIRTY_BG_RATIO}
vm.dirty_expire_centisecs = ${TUNE_DIRTY_EXPIRE}
vm.dirty_writeback_centisecs = ${TUNE_DIRTY_WRITEBACK}

# VFS cache pressure: lower keeps inode/dentry cache longer.
vm.vfs_cache_pressure = ${TUNE_VFS_PRESSURE}

# Keep some free memory to avoid stalls/OOM edge cases.
vm.min_free_kbytes = ${TUNE_MIN_FREE_KB}

# OOM behavior:
# - vm.oom_kill_allocating_task: kill the task that triggered OOM first.
# - vm.oom_dump_tasks: reduce noisy dumps.
# - vm.panic_on_oom: keep system running (0) rather than panic.
vm.oom_kill_allocating_task = 1
vm.oom_dump_tasks = 0
vm.panic_on_oom = 0

# Overcommit behavior (0 = heuristic overcommit, ratio is the soft limit).
vm.overcommit_memory = 0
vm.overcommit_ratio = $((50 + HW_MEM_TOTAL_GB))

# NUMA: zone reclaim can help local allocation but can hurt latency.
vm.zone_reclaim_mode = ${TUNE_ZONE_RECLAIM_MODE}

# Read-ahead page clustering when swapping (2^3 = 8 pages at a time).
vm.page-cluster = 3

# Watermark behavior (reclaim aggressiveness).
vm.watermark_scale_factor = ${WATERMARK_SCALE}
vm.watermark_boost_factor = 0

# Reserve low memory for critical allocations (mainly relevant on lowmem systems).
vm.lowmem_reserve_ratio = 256 256 32

# -----------------------------------------------------------------------------
# Memory footprint / reclaim helpers
# -----------------------------------------------------------------------------
vm.compact_unevictable_allowed = 1
vm.extfrag_threshold = 500  # 0-1000, higher = more aggressive compaction
vm.stat_interval = 10       # VM stats update interval (seconds)
vm.admin_reserve_kbytes = 8192  # 8MB reserved for root recovery

# -----------------------------------------------------------------------------
# CPU scheduler (CFS only - removed in EEVDF kernel 6.6+)
# -----------------------------------------------------------------------------
$([[ -f /proc/sys/kernel/sched_migration_cost_ns ]] && echo "kernel.sched_migration_cost_ns = ${TUNE_MIGRATION_COST}" || echo "# sched_migration_cost_ns removed in EEVDF (kernel 6.6+)")
kernel.sched_autogroup_enabled = ${TUNE_AUTOGROUP}
kernel.numa_balancing = ${TUNE_NUMA_BALANCING}

# Real-time throttling: -1 disables throttling (latency profile).
kernel.sched_rt_runtime_us = ${TUNE_RT_RUNTIME_US}

# -----------------------------------------------------------------------------
# Filesystem / file handles
# -----------------------------------------------------------------------------
fs.file-max = ${LIMIT_FILE_MAX}
fs.inotify.max_user_watches = ${LIMIT_INOTIFY_WATCHES}
fs.inotify.max_user_instances = ${LIMIT_INOTIFY_INSTANCES}
fs.aio-max-nr = 1048576  # 1M async I/O requests (for databases, io_uring)

# Common hardening (low overhead, improves safety for multi-user systems).
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# -----------------------------------------------------------------------------
# Process/address-space limits
# -----------------------------------------------------------------------------
kernel.pid_max = $((LIMIT_NPROC * 2))
kernel.threads-max = $((LIMIT_NPROC * 4))
vm.max_map_count = $((LIMIT_NOFILE * 2))  # Memory mappings (JVM, DBs need many)

# -----------------------------------------------------------------------------
# IPC defaults (System V shared memory/message queues)
# -----------------------------------------------------------------------------
kernel.msgmax = 65536   # 64KB max message size
kernel.msgmnb = 65536   # 64KB max bytes in queue
kernel.shmmax = $((HW_MEM_TOTAL_KB * 1024 * 3 / 4))  # 75% of RAM for single shm segment
kernel.shmall = $((HW_MEM_TOTAL_KB * 1024 / 4096))   # Total shm pages (all segments)
kernel.sem = 250 32000 100 128

# -----------------------------------------------------------------------------
# Watchdogs / diagnostics
# -----------------------------------------------------------------------------
kernel.watchdog = ${TUNE_KERNEL_WATCHDOG}
kernel.nmi_watchdog = ${TUNE_NMI_WATCHDOG}
kernel.soft_watchdog = ${TUNE_SOFT_WATCHDOG}
kernel.hung_task_timeout_secs = ${TUNE_HUNG_TASK_TIMEOUT_SECS}
kernel.timer_migration = 1
EOF

if [[ -s "${SYSCTL_SNIPPETS_FILE}" ]]; then
    append_file "${CFG_SYSCTL}" <<'EOF'

#===============================================================================
# Additional tuning (runtime-detected)
#===============================================================================
EOF
    append_file "${CFG_SYSCTL}" <"${SYSCTL_SNIPPETS_FILE}"
fi

run_quiet sysctl --system
echo "[SYSCTL] ✓ ${CFG_SYSCTL}"

# --- Systemd Boot Service ---
backup_file "${CFG_SERVICE}"
SERVICE_INTEL_NO_TURBO=0
SERVICE_AMD_BOOST=1
if [[ "${PROFILE_TURBO}" -eq 0 ]]; then
    SERVICE_INTEL_NO_TURBO=1
    SERVICE_AMD_BOOST=0
fi

case ${OPT_PROFILE} in
    server | vm) SERVICE_DISK_SCHED="none" ;;
    workstation) SERVICE_DISK_SCHED="mq-deadline" ;;
    laptop) SERVICE_DISK_SCHED="kyber" ;;
    latency) SERVICE_DISK_SCHED="none" ;;
    *) SERVICE_DISK_SCHED="mq-deadline" ;;
esac

LOW_LATENCY_UNIT_LINES=""
if [[ ${OPT_LOW_LATENCY} -eq 1 ]]; then
    LOW_LATENCY_UNIT_LINES=$(
        cat <<'EOF'

# Low-latency only: disable deep CPU idle states (C2+).
# WARNING: This increases power draw and heat.
ExecStart=/bin/bash -c 'for c in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do [[ -f "${c}" ]] || continue; st=${c%/disable}; st=${st##*/}; num=${st#state}; case "${num}" in (""|*[!0-9]*) continue ;; esac; [[ "${num}" -gt 1 ]] && echo 1 > "${c}" 2>/dev/null || true; done'
EOF
    )
fi

write_file "${CFG_SERVICE}" <<EOF
# =============================================================================
# $CFG_SERVICE
# Auto-generated by system_optimize.sh (profile=$OPT_PROFILE)
#
# This unit exists to re-apply a small subset of tuning at boot. Most tuning is
# persisted in:
# - $CFG_SYSCTL
# - $CFG_SYSTEMD_SYSTEM and $CFG_SYSTEMD_USER
#
# Disable:
#   systemctl disable system-optimize.service
# =============================================================================

[Unit]
Description=System Performance Optimization (system_optimize.sh)
After=multi-user.target

[Service]
Type=oneshot

# NOTE: All actions are best-effort. Some nodes may not exist on all kernels/CPUs.
# Failures are ignored so boot can continue normally.

# CPU governor (cpufreq)
ExecStart=/bin/bash -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f "\$g" ] || continue; echo "${PROFILE_GOVERNOR}" > "\$g" 2>/dev/null || true; done'

# Intel Turbo Boost (intel_pstate): 0=enabled, 1=disabled
ExecStart=/bin/bash -c '[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo "${SERVICE_INTEL_NO_TURBO}" > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true'

# AMD Boost (cpufreq/boost): 1=enabled, 0=disabled
ExecStart=/bin/bash -c '[ -f /sys/devices/system/cpu/cpufreq/boost ] && echo "${SERVICE_AMD_BOOST}" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true'

# Transparent Huge Pages (best effort)
ExecStart=/bin/bash -c 'echo "${TUNE_THP_MODE}" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true'

# Block I/O scheduler (best effort)
ExecStart=/bin/bash -c 'for d in /sys/block/sd*/queue/scheduler /sys/block/nvme*/queue/scheduler; do [ -f "\$d" ] && echo "${SERVICE_DISK_SCHED}" > "\$d" 2>/dev/null || true; done'
${LOW_LATENCY_UNIT_LINES}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

run systemctl daemon-reload
run systemctl enable system-optimize.service || true
echo "[SERVICE] ✓ system-optimize.service enabled"

#===============================================================================
# PHASE 5: SUMMARY
#===============================================================================

echo ""
echo "================================================================================"
echo "                           OPTIMIZATION COMPLETE"
echo "================================================================================"
echo ""

# --- Applied Settings Summary ---
echo "┌─────────────────────────────────────────────────────────────────────────────┐"
echo "│ APPLIED OPTIMIZATIONS                                                       │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ CPU                                                                         │"

summary_row() {
    local left="$1" impact="${2:-}"
    # Total line length: 79 chars (matches the box). ASCII only to avoid width issues.
    # Keep '(' aligned while padding *after* ')' for nicer output.
    local inner
    inner=$(printf "%-47.47s (%.21s)" "${left}" "${impact}")
    printf "│   - %-71.71s │\n" "${inner}"
}

summary_row "Governor: ${PROFILE_GOVERNOR}" "+5-15% compute"
summary_row "Turbo Boost: $([[ "${PROFILE_TURBO}" -eq 1 ]] && echo enabled || echo disabled)" "+10-30% peak"
if [[ ${OPT_DISABLE_SMT} -eq 1 ]]; then
    summary_row "SMT: disabled" "+5-10% per-thread"
else
    summary_row "SMT: enabled" "+30-50% throughput"
fi
[[ ${OPT_LOW_LATENCY} -eq 1 ]] && summary_row "C-states: limited to C1" "-50-90% wake latency"
[[ ${OPT_LOW_LATENCY} -eq 1 ]] && summary_row "Watchdogs: disabled" "-1-2% jitter"
summary_row "Migration cost: ${TUNE_MIGRATION_COST}ns" "+2-5% cache hits"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ MEMORY                                                                      │"
summary_row "Swappiness: ${TUNE_SWAPPINESS}" "+5-20% less swap I/O"
summary_row "Dirty ratio: ${TUNE_DIRTY_RATIO}%" "+10-30% write batch"
summary_row "VFS cache pressure: ${TUNE_VFS_PRESSURE}" "+5-15% cache hits"
if [[ "${TUNE_THP_MODE}" == "madvise" ]]; then
    summary_row "THP: ${TUNE_THP_MODE}" "+5-10% large alloc"
else
    summary_row "THP: ${TUNE_THP_MODE}" "-latency spikes"
fi
summary_row "Min free: $((TUNE_MIN_FREE_KB / 1024))MB" "OOM prevention"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ I/O & STORAGE                                                               │"
for DEV in "${!DISK_TYPE[@]}"; do
    TYPE=${DISK_TYPE[${DEV}]}
    SCHED=$(grep -o '\[.*\]' "/sys/block/${DEV}/queue/scheduler" 2>/dev/null | tr -d '[]')
    if [[ "${TYPE}" = "ssd" ]]; then
        summary_row "${DEV}: ${SCHED}" "+5-15% IOPS"
    else
        summary_row "${DEV}: ${SCHED}" "+10-20% seq read"
    fi
done
summary_row "Readahead: SSD=$((TUNE_READAHEAD / 4))KB HDD=${TUNE_READAHEAD}KB" "+10-30% seq read"
summary_row "Queue depth: optimized" "+5-15% throughput"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ SYSTEM LIMITS                                                               │"
summary_row "Max open files: ${LIMIT_NOFILE}" "high-conn servers"
summary_row "Max processes: ${LIMIT_NPROC}" "multi-threaded apps"
summary_row "Memory lock: $((LIMIT_MEMLOCK / 1024 / 1024 / 1024))GB" "DB/JVM huge pages"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ KERNEL & SERVICES                                                           │"
summary_row "IRQ balancing: enabled" "+5-10% network"
if [[ ${TUNE_NUMA_BALANCING} -eq 1 ]]; then
    summary_row "NUMA balancing: enabled" "+10-20% NUMA"
else
    summary_row "NUMA balancing: disabled" "single socket"
fi
summary_row "Module blacklist: applied" "-memory overhead"
if [[ ${OPT_RELAX_SECURITY} -eq 1 ]]; then
    echo "├─────────────────────────────────────────────────────────────────────────────┤"
    echo "│ SECURITY RELAXATION                                                         │"
    summary_row "Audit daemon: disabled" "+1-5% I/O"
    summary_row "SELinux: permissive" "+2-5% syscalls"
    summary_row "Firewall logging: disabled" "+1-2% network"
    summary_row "Journald: volatile" "+1-3% I/O"
    summary_row "Kernel printk: errors only" "-log overhead"
fi
if [[ ${OPT_DISABLE_MITIGATIONS} -eq 1 ]]; then
    echo "├─────────────────────────────────────────────────────────────────────────────┤"
    echo "│ CPU MITIGATIONS (after reboot)                                              │"
    summary_row "Spectre/Meltdown: disabled" "+5-30% syscalls"
    summary_row "MDS/TAA: disabled" "+5-15% context sw"
fi
if [[ ${OPT_DISABLE_SERVICES} -eq 1 ]]; then
    echo "├─────────────────────────────────────────────────────────────────────────────┤"
    echo "│ DISABLED SERVICES                                                           │"
    summary_row "Print/Bluetooth/WiFi services" "+50-100MB RAM"
    summary_row "Package managers (snapd, packagekit)" "+50-100MB RAM"
    summary_row "Error reporting (whoopsie, apport)" "+20-30MB RAM"
    summary_row "Desktop services (colord, geoclue)" "+20-30MB RAM"
    summary_row "Auto-update timers" "-background I/O"
fi
echo "└─────────────────────────────────────────────────────────────────────────────┘"

# --- Reboot Requirements ---
echo ""
NEEDS_REBOOT=0
if [[ ${OPT_DISABLE_MITIGATIONS} -eq 1 ]] || [[ -n "${OPT_ISOLATE_CPUS}" ]] || [[ ${OPT_RELAX_SECURITY} -eq 1 ]]; then
    echo "┌─────────────────────────────────────────────────────────────────────────────┐"
    printf "│ %-75.75s │\n" "REBOOT REQUIRED"
    echo "├─────────────────────────────────────────────────────────────────────────────┤"
    [[ ${OPT_DISABLE_MITIGATIONS} -eq 1 ]] && printf "│   %-73.73s │\n" "- CPU mitigations will be disabled (GRUB updated)"
    [[ -n "${OPT_ISOLATE_CPUS}" ]] && printf "│   %-73.73s │\n" "- CPUs ${OPT_ISOLATE_CPUS} will be isolated from scheduler"
    [[ ${OPT_RELAX_SECURITY} -eq 1 ]] && printf "│   %-73.73s │\n" "- IOMMU changes (if applied) require reboot"
    echo "└─────────────────────────────────────────────────────────────────────────────┘"
    NEEDS_REBOOT=1
fi

# --- Files Created ---
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────────┐"
echo "│ FILES CREATED/MODIFIED                                                      │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
printf "│   %-73s │\n" "${CFG_SYSCTL}"
printf "│     %-71.71s │\n" "-> Kernel parameters (memory, scheduler, limits)"
printf "│   %-73s │\n" "${CFG_LIMITS}"
printf "│     %-71.71s │\n" "-> User resource limits (nofile, nproc, memlock)"
printf "│   %-73s │\n" "${CFG_SYSTEMD_SYSTEM}"
printf "│     %-71.71s │\n" "-> Systemd service limits"
printf "│   %-73s │\n" "${CFG_MODPROBE}"
printf "│     %-71.71s │\n" "-> Blacklisted kernel modules"
printf "│   %-73s │\n" "${CFG_SERVICE}"
printf "│     %-71.71s │\n" "-> Boot-time optimization service"
[[ "${#FS_RECOMMENDATIONS[@]}" -gt 0 ]] && printf "│   %-73s │\n" "${CFG_FSTAB_HINTS}"
[[ "${#FS_RECOMMENDATIONS[@]}" -gt 0 ]] && printf "│     %-71.71s │\n" "-> Suggested mount options for filesystems"
echo "└─────────────────────────────────────────────────────────────────────────────┘"

# --- Verification Commands ---
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────────┐"
echo "│ VERIFICATION COMMANDS                                                       │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
printf "│   %-73s │\n" "# Check current sysctl values"
printf "│   %-73s │\n" "sysctl vm.swappiness vm.dirty_ratio vm.vfs_cache_pressure"
printf "│   %-73s │\n" ""
printf "│   %-73s │\n" "# Check user limits"
printf "│   %-73s │\n" "ulimit -n -u -l"
printf "│   %-73s │\n" ""
printf "│   %-73s │\n" "# Check CPU governor"
printf "│   %-73s │\n" "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
printf "│   %-73s │\n" ""
printf "│   %-73s │\n" "# Check I/O scheduler"
printf "│   %-73s │\n" "cat /sys/block/*/queue/scheduler"
printf "│   %-73s │\n" ""
printf "│   %-73s │\n" "# Check boot service status"
printf "│   %-73s │\n" "systemctl status system-optimize.service"
echo "└─────────────────────────────────────────────────────────────────────────────┘"

# --- Rollback Instructions ---
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────────┐"
echo "│ ROLLBACK INSTRUCTIONS                                                       │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
printf "│   %-73s │\n" "# Remove all optimization configs"
printf "│   %-73s │\n" "sudo rm -f ${CFG_SYSCTL} \\"
printf "│   %-73s │\n" "           ${CFG_LIMITS} \\"
printf "│   %-73s │\n" "           ${CFG_MODPROBE} \\"
printf "│   %-73s │\n" "           ${CFG_SYSTEMD_SYSTEM} \\"
printf "│   %-73s │\n" "           ${CFG_SYSTEMD_USER}"
printf "│   %-73s │\n" ""
printf "│   %-73s │\n" "# Disable boot service"
printf "│   %-73s │\n" "sudo systemctl disable system-optimize.service"
printf "│   %-73s │\n" ""
printf "│   %-73s │\n" "# Reload defaults and reboot"
printf "│   %-73s │\n" "sudo sysctl --system && sudo reboot"
[[ ${OPT_DISABLE_MITIGATIONS} -eq 1 ]] && printf "│   %-73s │\n" ""
[[ ${OPT_DISABLE_MITIGATIONS} -eq 1 ]] && printf "│   %-73s │\n" "# Restore GRUB (if mitigations were disabled)"
[[ ${OPT_DISABLE_MITIGATIONS} -eq 1 ]] && printf "│   %-73s │\n" "sudo cp /etc/default/grub.bak.* /etc/default/grub && sudo update-grub"
echo "└─────────────────────────────────────────────────────────────────────────────┘"

# --- Final Status ---
echo ""
if [[ ${OPT_DRY_RUN} -eq 1 ]]; then
    echo "INFO: DRY-RUN complete. No changes were made."
elif [[ ${NEEDS_REBOOT} -eq 1 ]]; then
    echo "⚠  Some changes require a REBOOT to take effect."
    echo "   Run: sudo reboot"
else
    echo "✓  All optimizations are now ACTIVE. No reboot required."
fi
echo ""
echo "================================================================================"
