#!/bin/bash
#===============================================================================
# File              : network_optimize.sh
# Author            : Lianghong Fei <feilianghong@gmail.com>
# Date              : 2025-12-19
# Last Modified Date: 2025-12-19
# Last Modified By  : Lianghong Fei <feilianghong@gmail.com>
#===============================================================================
#                    LINUX NETWORK PERFORMANCE OPTIMIZATION
#===============================================================================
#
# A comprehensive, hardware-aware network tuning script for Linux systems.
# Automatically detects NIC capabilities and applies optimal configurations.
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
#   Distributions:  Ubuntu, Debian, Arch, Fedora, RHEL-family, Amazon Linux 2023
#   Cloud:          AWS EC2, Azure VM, GCP Compute, Alibaba Cloud ECS
#   NIC Drivers:    Intel (i40e, ice, ixgbe), Mellanox (mlx5), AWS ENA/EFA,
#                   Virtio, Hyper-V (hv_netvsc), GCP gVNIC, Broadcom, Realtek
#
#===============================================================================
# OPTIMIZATION AREAS
#===============================================================================
#   1. TCP/IP Stack Tuning:
#      - TCP buffer sizes (auto-scaled by RAM and profile)
#      - TCP memory limits
#      - Congestion control (BBR for throughput, CUBIC for latency)
#      - TCP Fast Open, timestamps, SACK
#      - Connection handling (somaxconn, syn backlog)
#      - Keepalive and timeout optimization
#
#   2. NIC Hardware Optimization:
#      - Ring buffers (RX/TX) - dynamically scaled to device max
#      - Multi-queue RSS - scaled to CPU count
#      - Hardware offloads (TSO, GSO, GRO, LRO, checksums)
#      - Interrupt coalescing (adaptive or disabled for latency)
#      - EEE (Energy Efficient Ethernet) control
#      - Flow control (pause frames)
#      - MTU/Jumbo frames (cloud-aware)
#
#   3. Packet Steering:
#      - RPS (Receive Packet Steering)
#      - RFS (Receive Flow Steering)
#      - XPS (Transmit Packet Steering)
#      - IRQ affinity distribution
#
#   4. Driver-Specific Tuning:
#      - AWS ENA: LLQ, ring buffers, instance-type aware
#      - AWS EFA: HPC/RDMA optimization
#      - Intel: Flow Director, ntuple filtering
#      - Mellanox: CQE compression
#      - Virtio: Multiqueue, GRO
#      - Azure: Accelerated networking (Mellanox VF)
#      - GCP: gVNIC optimization
#
#   5. Connection Tracking:
#      - Conntrack table sizing (auto-scaled by RAM)
#      - Timeout optimization
#
#===============================================================================
# AUTO-TUNING FEATURES
#===============================================================================
#   - NIC capability detection via ethtool
#   - Ring buffer max detection and scaling
#   - Queue count detection and CPU matching
#   - Cloud provider and instance type detection via IMDS
#   - Network performance tier classification (ultra/high/medium/low)
#   - MTU detection and cloud-specific optimization
#   - IPv6 availability detection
#
#===============================================================================
# USAGE
#===============================================================================
#   sudo ./network_optimize.sh [OPTIONS]
#
#   Options:
#     --profile=TYPE       server|vm|workstation|laptop|latency|auto
#     --high-throughput    Optimize for maximum bandwidth (64MB buffers)
#     --low-latency        Same as --profile=latency (busy polling, no coalescing)
#     --dry-run            Preview changes without applying
#     --cleanup            Remove all changes and restore from backup
#     --restore-from=DIR   Restore from specific backup directory
#     --help               Show help
#
#   Examples:
#     sudo ./network_optimize.sh                    # Auto-detect profile
#     sudo ./network_optimize.sh --profile=server   # Server optimization
#     sudo ./network_optimize.sh --profile=latency  # Low-latency tuning
#     sudo ./network_optimize.sh --high-throughput  # Max bandwidth
#     sudo ./network_optimize.sh --dry-run          # Preview changes
#     sudo ./network_optimize.sh --cleanup          # Restore defaults
#
#===============================================================================
# FILES CREATED
#===============================================================================
#   /etc/sysctl.d/99-network-optimize.conf        - Network kernel parameters
#   /etc/systemd/system/network-optimize.service  - Persistence service
#
# BACKUP LOCATION:
#   /var/backups/network-optimize-YYYYMMDD-HHMMSS/
#
#===============================================================================
# PROFILE COMPARISON
#===============================================================================
#   Profile     | TCP Buffer | Ring Scale | Coalescing | MTU    | Use Case
#   ------------|------------|------------|------------|--------|------------------
#   server      | 16MB       | 100%       | Adaptive   | Jumbo  | Web/DB servers
#   vm          | 8MB        | 75%        | Adaptive   | Cloud  | Cloud VMs
#   workstation | 4MB        | 50%        | Adaptive   | 1500   | Desktop use
#   laptop      | 2MB        | 25%        | Adaptive   | 1500   | Power saving
#   latency     | 1MB        | 15%        | Disabled   | 1500   | Trading/Gaming
#
#===============================================================================
# NOTES
#===============================================================================
#   - Run as root (sudo)
#   - Changes take effect immediately (no reboot required)
#   - Use --dry-run to preview changes before applying
#   - Persistence service re-applies NIC settings on boot
#   - Some cloud instances may have limited tunability
#
#===============================================================================

set -euo pipefail
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

#-------------------------------------------------------------------------------
# Configuration Paths
#-------------------------------------------------------------------------------
# readonly SCRIPT_NAME="network-optimize"  # Unused
readonly CFG_SYSCTL="/etc/sysctl.d/99-network-optimize.conf"
readonly CFG_SERVICE="/etc/systemd/system/network-optimize.service"

#-------------------------------------------------------------------------------
# Tuning Constants
#-------------------------------------------------------------------------------
# These values can be adjusted for different environments. All values are
# chosen based on common best practices and benchmarking results.
#
# To customize: modify the constants below, then re-run the script.
#-------------------------------------------------------------------------------

# --- TCP Buffer Sizes (bytes) ---
# Controls maximum TCP socket buffer sizes. Larger buffers improve throughput
# for high-bandwidth connections but increase memory usage.
# Formula: BDP (Bandwidth-Delay Product) = Bandwidth × RTT
# Example: 10Gbps × 100ms RTT = 125MB theoretical max
readonly CONST_TCP_BUF_SERVER=$((16 * 1024 * 1024))          # 16MB - high throughput servers
readonly CONST_TCP_BUF_VM=$((8 * 1024 * 1024))               # 8MB  - cloud VM balanced
readonly CONST_TCP_BUF_WORKSTATION=$((4 * 1024 * 1024))      # 4MB  - desktop use
readonly CONST_TCP_BUF_LAPTOP=$((2 * 1024 * 1024))           # 2MB  - memory conscious
readonly CONST_TCP_BUF_LATENCY=$((1 * 1024 * 1024))          # 1MB  - minimal queuing delay
readonly CONST_TCP_BUF_HIGH_THROUGHPUT=$((64 * 1024 * 1024)) # 64MB - bulk transfer, 100Gbps+
readonly CONST_TCP_BUF_HIGH=$((32 * 1024 * 1024))            # 32MB - high tier cloud (25-50Gbps)
readonly CONST_TCP_BUF_MEDIUM=$((16 * 1024 * 1024))          # 16MB - medium tier cloud (10-25Gbps)

# --- TCP Memory Fraction ---
# Denominator for calculating TCP memory pool from total RAM.
# Formula: TCP_MEM_MAX = RAM_KB / FRAC
# Lower value = more RAM for TCP. Example: 4 means 25% of RAM.
readonly CONST_TCP_MEM_FRAC_SERVER=4      # 25% of RAM - high connection count
readonly CONST_TCP_MEM_FRAC_VM=6          # 16% of RAM - balanced
readonly CONST_TCP_MEM_FRAC_WORKSTATION=8 # 12% of RAM - desktop apps
readonly CONST_TCP_MEM_FRAC_LAPTOP=10     # 10% of RAM - conservative

# --- Network Device Budget ---
# net.core.netdev_budget: Max packets processed per NAPI poll cycle.
# Higher = better throughput (more batching), Lower = better latency (less delay)
readonly CONST_NETDEV_BUDGET_SERVER=600   # High throughput servers
readonly CONST_NETDEV_BUDGET_VM=300       # Cloud VM balanced
readonly CONST_NETDEV_BUDGET_WORKSTATION=300 # Desktop balanced
readonly CONST_NETDEV_BUDGET_LAPTOP=150   # Power saving, less CPU wake
readonly CONST_NETDEV_BUDGET_LATENCY=64   # Minimal batching for low latency
readonly CONST_NETDEV_BUDGET_HIGH=1200    # Maximum throughput (100Gbps+)

# --- Connection Limits ---
# net.core.somaxconn: Max pending connections in listen queue.
# Higher values needed for high-connection servers (web, database, load balancer)
readonly CONST_SOMAXCONN_SERVER=65535     # Max connections - busy servers
readonly CONST_SOMAXCONN_VM=32768         # Cloud VM default
readonly CONST_SOMAXCONN_MEDIUM=16384     # Medium tier cloud instances
readonly CONST_SOMAXCONN_LOW=8192         # Low tier cloud instances
readonly CONST_SOMAXCONN_WORKSTATION=4096 # Desktop - few connections
readonly CONST_SOMAXCONN_LAPTOP=2048      # Laptop - minimal
readonly CONST_SOMAXCONN_LATENCY=4096     # Latency profile

# --- Backlog Limits ---
# net.core.netdev_max_backlog: Max packets queued when NIC receives faster than kernel processes.
# Higher = handle traffic bursts, Lower = less memory, faster drop detection
readonly CONST_BACKLOG_SERVER=65536       # High traffic servers
readonly CONST_BACKLOG_VM=32768           # Cloud VM default
readonly CONST_BACKLOG_MEDIUM=16384       # Medium tier cloud
readonly CONST_BACKLOG_LOW=8192           # Low tier cloud
readonly CONST_BACKLOG_WORKSTATION=4096   # Desktop use
readonly CONST_BACKLOG_LAPTOP=2048        # Laptop - minimal
readonly CONST_BACKLOG_LATENCY=1024       # Small queue = less queuing delay

# --- NIC Ring Buffer Scaling ---
# Percentage of detected maximum ring buffer size to use.
# Ring buffers store packets between NIC and kernel.
# Larger rings = more packet buffering, survives bursts, higher latency
# Smaller rings = less buffering, lower latency, potential drops under load
readonly CONST_RING_SCALE_SERVER=100      # 100% - use full capacity
readonly CONST_RING_SCALE_VM=75           # 75% of max
readonly CONST_RING_SCALE_WORKSTATION=50  # 50% of max
readonly CONST_RING_SCALE_LAPTOP=25       # 25% of max - save memory
readonly CONST_RING_SCALE_LATENCY=15      # 15% - minimal buffering
readonly CONST_RING_MIN=128               # Minimum ring size (packets)

# --- Conntrack Scaling ---
# Connection tracking table size for stateful firewall (iptables/nftables).
# Each entry ~256 bytes. Auto-scaled based on RAM to prevent table exhaustion.
# Formula: CONNTRACK_MAX = RAM_GB × CONST_CONNTRACK_PER_GB
readonly CONST_CONNTRACK_PER_GB_SERVER=8192  # ~2MB/GB RAM for conntrack
readonly CONST_CONNTRACK_PER_GB_VM=4096      # ~1MB/GB RAM
readonly CONST_CONNTRACK_PER_GB_OTHER=2048   # ~0.5MB/GB RAM
readonly CONST_CONNTRACK_MAX_CAP=2097152     # 2M entries max (~512MB)
readonly CONST_CONNTRACK_MIN=65536           # 64K entries min (~16MB)

# --- Cloud MTU Values ---
# Maximum Transmission Unit for cloud providers (jumbo frames within VPC)
readonly CONST_MTU_AWS=9001        # AWS VPC jumbo frames
readonly CONST_MTU_GCP=8896        # GCP gVNIC MTU
readonly CONST_MTU_GCP_DEFAULT=1460 # GCP default VPC MTU
readonly CONST_MTU_AZURE=9000      # Azure accelerated networking
readonly CONST_MTU_ALIBABA=8500    # Alibaba Cloud VPC
readonly CONST_MTU_DEFAULT=9000    # Bare metal jumbo frames
readonly CONST_MTU_FALLBACK=1500   # Standard Ethernet MTU

# --- Busy Polling ---
# net.core.busy_poll/busy_read: Microseconds to busy-poll for packets.
# Reduces latency by avoiding interrupt overhead, but increases CPU usage.
readonly CONST_BUSY_POLL_LATENCY=50 # 50µs - low latency profile
readonly CONST_BUSY_POLL_OFF=0      # Disabled - normal operation

#===============================================================================
# PHASE 1: INITIALIZATION
#===============================================================================

# --- Backup Configuration ---
readonly BACKUP_ROOT="/var/backups"
readonly BACKUP_PREFIX="network-optimize"
BACKUP_DIR=""

# --- CLI Arguments ---
OPT_PROFILE="auto" # server, vm, workstation, laptop, latency, auto
OPT_HIGH_THROUGHPUT=0
OPT_LOW_LATENCY=0
OPT_DRY_RUN=0
OPT_REPORT=0
OPT_CONGESTION=""
OPT_CLEANUP=0
OPT_RESTORE_FROM=""

usage() {
    cat <<'EOF'
================================================================================
                    LINUX NETWORK PERFORMANCE OPTIMIZATION
================================================================================

Usage: ./network_optimize.sh [OPTIONS]

OPTIONS:
  --profile=TYPE         Optimization profile:
                           server     - High throughput, many connections
                           vm         - Cloud VM optimized
                           workstation- Balanced
                           laptop     - Power efficient
                           latency    - Minimal latency (trading, gaming, HPC)
                           auto       - Auto-detect (default)
  --congestion=ALG       Override TCP congestion control (e.g., bbr, cubic, reno)
  --high-throughput      Optimize for maximum bandwidth (large transfers)
  --low-latency          Optimize for minimum latency (same as --profile=latency)
  --dry-run              Print actions without changing the system
  --report               Print recommended config files and exit (no changes)
  --cleanup              Remove all changes and restore from backup
  --restore-from=DIR     Restore from specific backup directory
  --help                 Show this help

NOTES:
  - Root is required to apply changes.
  - You can run without root using: --dry-run or --report

PROFILES:
  ┌─────────────┬─────────────────────────────────────────────────────────────┐
  │ server      │ Large buffers, BBR, high connection limits                  │
  │ vm          │ Cloud-optimized, virtio/ENA tuning                          │
  │ workstation │ Balanced throughput and latency                             │
  │ laptop      │ Power saving, moderate buffers                              │
  │ latency     │ Minimal latency: small buffers, no coalescing, busy poll    │
  └─────────────┴─────────────────────────────────────────────────────────────┘

EXAMPLES:
  sudo ./network_optimize.sh                        # Auto-detect (apply)
  sudo ./network_optimize.sh --profile=server       # Server (apply)
  ./network_optimize.sh --dry-run                   # Preview (no sudo required)
  ./network_optimize.sh --report                    # Show config files (no sudo required)
  sudo ./network_optimize.sh --cleanup              # Restore defaults

BACKUP LOCATION:
  /var/backups/network-optimize-YYYYMMDD-HHMMSS/
================================================================================
EOF
    exit 0
}

for arg in "$@"; do
    case $arg in
        --profile=*) OPT_PROFILE="${arg#*=}" ;;
        --congestion=*) OPT_CONGESTION="${arg#*=}" ;;
        --high-throughput) OPT_HIGH_THROUGHPUT=1 ;;
        --low-latency)
            OPT_PROFILE="latency"
            OPT_LOW_LATENCY=1
            ;;
        --dry-run) OPT_DRY_RUN=1 ;;
        --report)
            OPT_REPORT=1
            OPT_DRY_RUN=1
            ;;
        --cleanup) OPT_CLEANUP=1 ;;
        --restore-from=*)
            OPT_RESTORE_FROM="${arg#*=}"
            OPT_CLEANUP=1
            ;;
        --help | -h) usage ;;
        *) die "Unknown option: $arg" ;;
    esac
done

# Validate --profile
case "$OPT_PROFILE" in
    server | vm | workstation | laptop | latency | auto) ;;
    *) die "Invalid profile: $OPT_PROFILE (must be: server|vm|workstation|laptop|latency|auto)" ;;
esac

# latency profile implies low-latency flag
[[ "$OPT_PROFILE" == "latency" ]] && OPT_LOW_LATENCY=1

# --- Preflight Checks ---
# Help/report/dry-run should be usable without root.
if [[ $OPT_CLEANUP -eq 1 || ($OPT_DRY_RUN -eq 0 && $OPT_REPORT -eq 0) ]]; then
    [[ $EUID -ne 0 ]] && die "Run as root (sudo) to apply changes (or use --dry-run/--report without sudo)"
fi

# Dry-run wrapper: execute or print command
run() {
    if [[ $OPT_DRY_RUN -eq 1 ]]; then
        [[ $OPT_REPORT -eq 1 ]] && return 0
        printf '[DRY-RUN]'
        printf ' %s' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Run command and suppress output (but still show in --dry-run)
run_quiet() {
    if [[ $OPT_DRY_RUN -eq 1 ]]; then
        [[ $OPT_REPORT -eq 1 ]] && return 0
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
    if [[ $OPT_DRY_RUN -eq 1 ]]; then
        [[ $OPT_REPORT -eq 1 ]] && return 0
        printf '[DRY-RUN] write %s <= %s\n' "$path" "$value"
        return 0
    fi
    printf '%s\n' "$value" >"$path"
}

write_value_quiet() {
    write_value "$1" "$2" >/dev/null 2>&1 || true
}

# Write/append file content from stdin (respects --dry-run)
write_file() {
    local path=$1
    if [[ $OPT_DRY_RUN -eq 1 ]]; then
        if [[ $OPT_REPORT -eq 1 ]]; then
            log ""
            log "================================================================================"
            log "RECOMMENDED FILE: $path"
            log "================================================================================"
            cat
            log ""
            return 0
        fi
        log "[DRY-RUN] write file: $path"
        cat >/dev/null
        return 0
    fi
    cat >"$path"
}

append_file() {
    local path=$1
    if [[ $OPT_DRY_RUN -eq 1 ]]; then
        if [[ $OPT_REPORT -eq 1 ]]; then
            log ""
            log "================================================================================"
            log "RECOMMENDED APPEND: $path"
            log "================================================================================"
            cat
            log ""
            return 0
        fi
        log "[DRY-RUN] append file: $path"
        cat >/dev/null
        return 0
    fi
    cat >>"$path"
}

#-------------------------------------------------------------------------------
# Backup & Restore Functions
#-------------------------------------------------------------------------------

# Find latest backup directory
latest_backup_dir() {
    local name
    name=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "${BACKUP_PREFIX}-*" -printf '%T@ %f\n' 2>/dev/null | sort -nr | head -n1 | awk '{print $2}')
    [[ -n "$name" && -d "$BACKUP_ROOT/$name" ]] && echo "$BACKUP_ROOT/$name"
}

# Backup a file before modifying
backup_file() {
    local path=$1
    [[ -z "$BACKUP_DIR" ]] && return 0
    [[ -e "$path" ]] || return 0
    local dest_dir
    dest_dir="$BACKUP_DIR/files$(dirname "$path")"
    run mkdir -p "$dest_dir"
    run cp -a "$path" "$dest_dir/"
    log "  Backed up: $path"
}

# Restore a file from backup or remove if no backup exists
restore_or_remove() {
    local path=$1 restore_dir=$2
    local backup_path="$restore_dir/files$path"

    if [[ -f "$backup_path" ]]; then
        log "  Restoring: $path"
        run mkdir -p "$(dirname "$path")"
        run cp -a "$backup_path" "$path"
        return 0
    fi

    if [[ -e "$path" ]]; then
        log "  Removing: $path"
        run rm -f "$path"
        return 0
    fi
    return 1
}

# Cleanup function: restore from backup
do_cleanup() {
    log "================================================================================"
    log "                    NETWORK OPTIMIZATION CLEANUP"
    log "================================================================================"
    log ""

    local restore_dir=""
    if [[ -n "$OPT_RESTORE_FROM" ]]; then
        [[ -d "$OPT_RESTORE_FROM" ]] || die "Backup directory not found: $OPT_RESTORE_FROM"
        restore_dir="$OPT_RESTORE_FROM"
    else
        restore_dir=$(latest_backup_dir)
    fi

    if [[ -n "$restore_dir" ]]; then
        log "Restoring from backup: $restore_dir"
    else
        log "No backup found. Removing generated files..."
    fi
    log ""

    # Restore or remove config files
    restore_or_remove "/etc/sysctl.d/99-network-optimize.conf" "$restore_dir" || true
    restore_or_remove "/etc/systemd/system/network-optimize.service" "$restore_dir" || true

    # Disable service
    if systemctl is-enabled network-optimize.service &>/dev/null; then
        log "  Disabling network-optimize.service..."
        run systemctl disable network-optimize.service
    fi
    run systemctl daemon-reload

    # Reload sysctl to restore defaults
    log ""
    log "Reloading sysctl defaults..."
    run sysctl --system

    log ""
    log "================================================================================"
    log "Cleanup complete. Reboot recommended to fully restore defaults."
    if [[ -n "$restore_dir" ]]; then
        log "Restored from: $restore_dir"
    fi
    log "================================================================================"
    exit 0
}

# Run cleanup if requested
[[ $OPT_CLEANUP -eq 1 ]] && do_cleanup

# Create backup directory for this run
if [[ $OPT_DRY_RUN -eq 0 ]]; then
    BACKUP_DIR="$BACKUP_ROOT/${BACKUP_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    log "Backup directory: $BACKUP_DIR"
fi

# Check if irqbalance is running (affects IRQ affinity decisions)
irqbalance_running() {
    if command -v systemctl &>/dev/null; then
        systemctl is-active --quiet irqbalance.service 2>/dev/null && return 0
        systemctl is-active --quiet irqbalance 2>/dev/null && return 0
    fi
    if command -v pgrep &>/dev/null; then
        pgrep -x irqbalance &>/dev/null && return 0
    fi
    return 1
}

# --- Distribution Detection ---
# shellcheck source=/dev/null
. /etc/os-release 2>/dev/null || ID="unknown"
DISTRO=$ID
DISTRO_ID="${ID:-unknown}"
# DISTRO_VERSION_ID="${VERSION_ID:-}"  # Reserved for future use
DISTRO_PRETTY="${PRETTY_NAME:-}"
if [[ -z "$DISTRO_PRETTY" ]]; then
    DISTRO_PRETTY="${NAME:-$DISTRO}${VERSION_ID:+ $VERSION_ID}"
fi
KERNEL_RELEASE=$(uname -r 2>/dev/null || echo "unknown")

SUPPORTED_DISTRO=0
case "$DISTRO_ID" in
    ubuntu | debian | amzn | fedora | arch | rhel | centos | rocky | almalinux) SUPPORTED_DISTRO=1 ;;
esac
if [[ $SUPPORTED_DISTRO -ne 1 ]]; then
    if [[ $OPT_DRY_RUN -eq 1 || $OPT_REPORT -eq 1 ]]; then
        warn "Unsupported distro ID='$DISTRO_ID' (tested for: Ubuntu, Debian, Fedora, Arch, RHEL-family, Amazon Linux 2023). Proceeding in read-only mode."
    else
        die "Unsupported distro ID='$DISTRO_ID' (supported: Ubuntu, Debian, Fedora, Arch, RHEL-family, Amazon Linux 2023)"
    fi
fi

APT_UPDATED=0
pkg_install() {
    [[ $# -gt 0 ]] || return 0
    case $DISTRO in
        ubuntu | debian)
            if [[ $APT_UPDATED -eq 0 ]]; then
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
                run_quiet "$pm" install -y "$pkg" || true
            done
            ;;
    esac
}

#===============================================================================
# PHASE 2: HARDWARE DETECTION
#===============================================================================

log "================================================================================"
log "                    LINUX NETWORK PERFORMANCE OPTIMIZATION"
[[ $OPT_REPORT -eq 1 ]] && log "                              *** REPORT MODE ***"
[[ $OPT_REPORT -eq 0 && $OPT_DRY_RUN -eq 1 ]] && log "                              *** DRY-RUN MODE ***"
log "================================================================================"
log ""
[[ $OPT_DRY_RUN -eq 1 ]] && log "NOTE: No changes will be made. Commands shown for review only."
[[ $OPT_DRY_RUN -eq 1 ]] && log ""
log ">>> Phase 1: Detecting Network Configuration..."
log ""

# --- System Info ---
HW_MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
HW_MEM_TOTAL_GB=$((HW_MEM_TOTAL_KB / 1024 / 1024))
HW_CPU_CORES=$(nproc)
HW_IS_VM=$(systemd-detect-virt 2>/dev/null) || HW_IS_VM="none"

# --- Cloud Provider & Instance Type Detection ---
CLOUD_PROVIDER="none"
INSTANCE_TYPE=""
INSTANCE_NET_PERF="" # network performance tier: low/medium/high/ultra

if [ "$HW_IS_VM" != "none" ]; then
    # Check DMI/SMBIOS info
    DMI_VENDOR=$(tr '[:upper:]' '[:lower:]' </sys/devices/virtual/dmi/id/board_vendor 2>/dev/null) || DMI_VENDOR=""
    DMI_PRODUCT=$(tr '[:upper:]' '[:lower:]' </sys/devices/virtual/dmi/id/product_name 2>/dev/null) || DMI_PRODUCT=""
    DMI_ASSET=$(tr '[:upper:]' '[:lower:]' </sys/devices/virtual/dmi/id/chassis_asset_tag 2>/dev/null) || DMI_ASSET=""

    if [[ "$DMI_VENDOR" == *"amazon"* ]] || [[ "$DMI_PRODUCT" == *"ec2"* ]]; then
        CLOUD_PROVIDER="aws"
        # AWS: Get instance type from IMDS
        INSTANCE_TYPE=$(curl -sf -m1 http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo "")
    elif [[ "$DMI_VENDOR" == *"microsoft"* ]] || [[ "$DMI_ASSET" == *"azure"* ]]; then
        CLOUD_PROVIDER="azure"
        # Azure: Get VM size from IMDS
        INSTANCE_TYPE=$(curl -sf -m1 -H "Metadata:true" "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text" 2>/dev/null || echo "")
    elif [[ "$DMI_VENDOR" == *"google"* ]] || [[ "$DMI_PRODUCT" == *"google"* ]]; then
        CLOUD_PROVIDER="gcp"
        # GCP: Get machine type from metadata
        INSTANCE_TYPE=$(curl -sf -m1 -H "Metadata-Flavor: Google" "http://169.254.169.254/computeMetadata/v1/instance/machine-type" 2>/dev/null | awk -F/ '{print $NF}' || echo "")
    elif [[ "$DMI_VENDOR" == *"alibaba"* ]] || [[ "$DMI_PRODUCT" == *"alibaba"* ]] || [[ "$DMI_PRODUCT" == *"ecs"* ]]; then
        CLOUD_PROVIDER="alibaba"
        # Alibaba: Get instance type from metadata
        INSTANCE_TYPE=$(curl -sf -m1 http://100.100.100.200/latest/meta-data/instance/instance-type 2>/dev/null || echo "")
    fi

    # Determine network performance tier based on instance type
    if [ -n "$INSTANCE_TYPE" ]; then
        case $CLOUD_PROVIDER in
            aws)
                # AWS: metal, .24xlarge, .16xlarge, .12xlarge = ultra; .8xlarge, .4xlarge = high
                if [[ "$INSTANCE_TYPE" == *"metal"* ]] || [[ "$INSTANCE_TYPE" == *".24xl"* ]] || [[ "$INSTANCE_TYPE" == *".48xl"* ]]; then
                    INSTANCE_NET_PERF="ultra" # 100-200 Gbps
                elif [[ "$INSTANCE_TYPE" == *".16xl"* ]] || [[ "$INSTANCE_TYPE" == *".12xl"* ]] || [[ "$INSTANCE_TYPE" == *".8xl"* ]]; then
                    INSTANCE_NET_PERF="high" # 25-50 Gbps
                elif [[ "$INSTANCE_TYPE" == *".4xl"* ]] || [[ "$INSTANCE_TYPE" == *".2xl"* ]]; then
                    INSTANCE_NET_PERF="medium" # 10-25 Gbps
                else
                    INSTANCE_NET_PERF="low" # up to 10 Gbps
                fi
                # n-series (network optimized) boost
                [[ "$INSTANCE_TYPE" == *"n."* ]] && INSTANCE_NET_PERF="high"
                ;;
            azure)
                # Azure: based on VM size suffix
                if [[ "$INSTANCE_TYPE" == *"_v5"* ]] || [[ "$INSTANCE_TYPE" == *"96"* ]] || [[ "$INSTANCE_TYPE" == *"64"* ]]; then
                    INSTANCE_NET_PERF="ultra"
                elif [[ "$INSTANCE_TYPE" == *"32"* ]] || [[ "$INSTANCE_TYPE" == *"16"* ]]; then
                    INSTANCE_NET_PERF="high"
                elif [[ "$INSTANCE_TYPE" == *"8"* ]] || [[ "$INSTANCE_TYPE" == *"4"* ]]; then
                    INSTANCE_NET_PERF="medium"
                else
                    INSTANCE_NET_PERF="low"
                fi
                ;;
            gcp)
                # GCP: based on machine type
                if [[ "$INSTANCE_TYPE" == *"-96"* ]] || [[ "$INSTANCE_TYPE" == *"-64"* ]] || [[ "$INSTANCE_TYPE" == "c3-"* ]]; then
                    INSTANCE_NET_PERF="ultra"
                elif [[ "$INSTANCE_TYPE" == *"-32"* ]] || [[ "$INSTANCE_TYPE" == *"-16"* ]]; then
                    INSTANCE_NET_PERF="high"
                else
                    INSTANCE_NET_PERF="medium"
                fi
                ;;
            alibaba)
                # Alibaba: ecs.g7/c7/r7 series, 8xlarge+ = high
                if [[ "$INSTANCE_TYPE" == *"8xlarge"* ]] || [[ "$INSTANCE_TYPE" == *"16xlarge"* ]]; then
                    INSTANCE_NET_PERF="high"
                elif [[ "$INSTANCE_TYPE" == *"4xlarge"* ]] || [[ "$INSTANCE_TYPE" == *"2xlarge"* ]]; then
                    INSTANCE_NET_PERF="medium"
                else
                    INSTANCE_NET_PERF="low"
                fi
                ;;
        esac
    fi
fi

# --- Profile Auto-Detection ---
if [ "$OPT_PROFILE" = "auto" ]; then
    if [ "$HW_IS_VM" != "none" ]; then
        OPT_PROFILE="vm"
    elif [ -d /sys/class/power_supply/BAT0 ]; then
        OPT_PROFILE="laptop"
    elif [[ $HW_CPU_CORES -le 4 ]]; then
        OPT_PROFILE="workstation"
    else
        OPT_PROFILE="server"
    fi
fi

# --- Network Interface Detection ---
echo "┌─────────────────────────────────────────────────────────────────────────────┐"
echo "│ NETWORK CONFIGURATION                                                       │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
printf "│ %-75.75s │\n" "Profile: $OPT_PROFILE | Cloud: $CLOUD_PROVIDER | VM: $HW_IS_VM"
printf "│ %-75.75s │\n" "RAM: ${HW_MEM_TOTAL_GB}GB | CPUs: $HW_CPU_CORES"
printf "│ %-75.75s │\n" "OS: $DISTRO_PRETTY | Kernel: $KERNEL_RELEASE"
[ -n "$INSTANCE_TYPE" ] && printf "│ %-75.75s │\n" "Instance: $INSTANCE_TYPE | Network: $INSTANCE_NET_PERF"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ NETWORK INTERFACES                                                          │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"

# declare -A NIC_DRIVER  # Reserved for future use
# declare -A NIC_SPEED   # Reserved for future use
for iface in /sys/class/net/*; do
    IFACE=$(basename "$iface")
    [[ "$IFACE" == "lo" ]] && continue
    [[ ! -d "$iface/device" ]] && continue

    DRIVER=$(basename "$(readlink -f "$iface/device/driver" 2>/dev/null)" 2>/dev/null || echo "unknown")
    SPEED=$(cat "$iface/speed" 2>/dev/null || echo "?")
    STATE=$(cat "$iface/operstate" 2>/dev/null || echo "unknown")
    DRV_VER=""
    FW_VER=""
    if command -v ethtool &>/dev/null; then
        DRV_VER=$(timeout 2 ethtool -i "$IFACE" 2>/dev/null | awk -F': *' '/^version:/{print $2; exit}')
        FW_VER=$(timeout 2 ethtool -i "$IFACE" 2>/dev/null | awk -F': *' '/^firmware-version:/{print $2; exit}')
        FW_VER=${FW_VER# }
        FW_VER=${FW_VER% }
    fi
    if [[ -z "$DRV_VER" && "$DRIVER" != "unknown" && "$DRIVER" != "-" ]] && command -v modinfo &>/dev/null; then
        DRV_VER=$(modinfo -F version "$DRIVER" 2>/dev/null | head -n1 || true)
    fi

    # NIC_DRIVER[$IFACE]=$DRIVER  # Reserved
    # NIC_SPEED[$IFACE]=$SPEED    # Reserved

    printf "│ %-12.12s %-20.20s %-15.15s %-25.25s │\n" "$IFACE:" "driver=$DRIVER" "speed=${SPEED}Mb" "state=$STATE"
    if [[ -n "$DRV_VER" ]]; then
        [[ "$DRV_VER" == "$KERNEL_RELEASE" ]] && DRV_VER="$DRV_VER (kernel)"
        extra="  driver_version=$DRV_VER"
        [[ -n "$FW_VER" && "$FW_VER" != "N/A" ]] && extra="$extra firmware=$FW_VER"
        printf "│ %-75.75s │\n" "$extra"
    fi
done
echo "└─────────────────────────────────────────────────────────────────────────────┘"
echo ""

#===============================================================================
# PHASE 3: APPLY OPTIMIZATIONS
#===============================================================================

echo ">>> Phase 2: Applying Network Optimizations..."
echo ""

#-------------------------------------------------------------------------------
# 3.1 TCP/IP STACK TUNING
#-------------------------------------------------------------------------------
echo "[TCP/IP] Configuring network stack..."

# Calculate buffer sizes based on RAM and profile (using constants)
case $OPT_PROFILE in
    server)
        TCP_RMEM_MAX=$CONST_TCP_BUF_SERVER
        TCP_WMEM_MAX=$CONST_TCP_BUF_SERVER
        TCP_MEM_MAX=$((HW_MEM_TOTAL_KB / CONST_TCP_MEM_FRAC_SERVER))
        NETDEV_BUDGET=$CONST_NETDEV_BUDGET_SERVER
        NETDEV_BUDGET_USECS=8000
        SOMAXCONN=$CONST_SOMAXCONN_SERVER
        NETDEV_MAX_BACKLOG=$CONST_BACKLOG_SERVER
        ;;
    vm)
        TCP_RMEM_MAX=$CONST_TCP_BUF_VM
        TCP_WMEM_MAX=$CONST_TCP_BUF_VM
        TCP_MEM_MAX=$((HW_MEM_TOTAL_KB / CONST_TCP_MEM_FRAC_VM))
        NETDEV_BUDGET=$CONST_NETDEV_BUDGET_VM
        NETDEV_BUDGET_USECS=4000
        SOMAXCONN=$CONST_SOMAXCONN_VM
        NETDEV_MAX_BACKLOG=$CONST_BACKLOG_VM
        ;;
    workstation)
        TCP_RMEM_MAX=$CONST_TCP_BUF_WORKSTATION
        TCP_WMEM_MAX=$CONST_TCP_BUF_WORKSTATION
        TCP_MEM_MAX=$((HW_MEM_TOTAL_KB / CONST_TCP_MEM_FRAC_WORKSTATION))
        NETDEV_BUDGET=$CONST_NETDEV_BUDGET_WORKSTATION
        NETDEV_BUDGET_USECS=4000
        SOMAXCONN=$CONST_SOMAXCONN_WORKSTATION
        NETDEV_MAX_BACKLOG=$CONST_BACKLOG_WORKSTATION
        ;;
    laptop)
        TCP_RMEM_MAX=$CONST_TCP_BUF_LAPTOP
        TCP_WMEM_MAX=$CONST_TCP_BUF_LAPTOP
        TCP_MEM_MAX=$((HW_MEM_TOTAL_KB / CONST_TCP_MEM_FRAC_LAPTOP))
        NETDEV_BUDGET=$CONST_NETDEV_BUDGET_LAPTOP
        NETDEV_BUDGET_USECS=2000
        SOMAXCONN=$CONST_SOMAXCONN_LAPTOP
        NETDEV_MAX_BACKLOG=$CONST_BACKLOG_LAPTOP
        ;;
    latency)
        TCP_RMEM_MAX=$CONST_TCP_BUF_LATENCY
        TCP_WMEM_MAX=$CONST_TCP_BUF_LATENCY
        TCP_MEM_MAX=$((HW_MEM_TOTAL_KB / CONST_TCP_MEM_FRAC_LAPTOP))
        NETDEV_BUDGET=$CONST_NETDEV_BUDGET_LATENCY
        NETDEV_BUDGET_USECS=500
        SOMAXCONN=$CONST_SOMAXCONN_LATENCY
        NETDEV_MAX_BACKLOG=$CONST_BACKLOG_LATENCY
        echo "  -> Latency profile: minimal queuing"
        ;;
esac

# High throughput overrides
if [ $OPT_HIGH_THROUGHPUT -eq 1 ]; then
    TCP_RMEM_MAX=$CONST_TCP_BUF_HIGH_THROUGHPUT
    TCP_WMEM_MAX=$CONST_TCP_BUF_HIGH_THROUGHPUT
    NETDEV_BUDGET=$CONST_NETDEV_BUDGET_HIGH
    echo "  -> High-throughput mode enabled"
fi

# Cloud VM: Tune based on detected instance network performance tier
if [ "$OPT_PROFILE" = "vm" ] && [ -n "$INSTANCE_NET_PERF" ]; then
    case $INSTANCE_NET_PERF in
        ultra) # 100-200 Gbps instances
            TCP_RMEM_MAX=$CONST_TCP_BUF_HIGH_THROUGHPUT
            TCP_WMEM_MAX=$CONST_TCP_BUF_HIGH_THROUGHPUT
            NETDEV_BUDGET=$CONST_NETDEV_BUDGET_HIGH
            NETDEV_BUDGET_USECS=16000
            SOMAXCONN=$CONST_SOMAXCONN_SERVER
            NETDEV_MAX_BACKLOG=$CONST_BACKLOG_SERVER
            ;;
        high) # 25-50 Gbps instances
            TCP_RMEM_MAX=$CONST_TCP_BUF_HIGH
            TCP_WMEM_MAX=$CONST_TCP_BUF_HIGH
            NETDEV_BUDGET=$CONST_NETDEV_BUDGET_SERVER
            NETDEV_BUDGET_USECS=8000
            SOMAXCONN=$CONST_SOMAXCONN_VM
            NETDEV_MAX_BACKLOG=$CONST_BACKLOG_VM
            ;;
        medium) # 10-25 Gbps instances
            TCP_RMEM_MAX=$CONST_TCP_BUF_MEDIUM
            TCP_WMEM_MAX=$CONST_TCP_BUF_MEDIUM
            NETDEV_BUDGET=$CONST_NETDEV_BUDGET_VM
            NETDEV_BUDGET_USECS=4000
            SOMAXCONN=$CONST_SOMAXCONN_MEDIUM
            NETDEV_MAX_BACKLOG=$CONST_BACKLOG_MEDIUM
            ;;
        low) # up to 10 Gbps instances
            TCP_RMEM_MAX=$CONST_TCP_BUF_VM
            TCP_WMEM_MAX=$CONST_TCP_BUF_VM
            NETDEV_BUDGET=$CONST_NETDEV_BUDGET_VM
            NETDEV_BUDGET_USECS=4000
            SOMAXCONN=$CONST_SOMAXCONN_LOW
            NETDEV_MAX_BACKLOG=$CONST_BACKLOG_LOW
            ;;
    esac
    echo "  -> $CLOUD_PROVIDER ($INSTANCE_TYPE): $INSTANCE_NET_PERF network tier"
fi

# Select congestion control
TCP_CONGESTION_SOURCE="auto"
if [ $OPT_LOW_LATENCY -eq 1 ]; then
    TCP_CONGESTION="cubic" # More predictable latency than BBR
else
    TCP_CONGESTION="bbr" # Better throughput
fi

# User override
if [[ -n "$OPT_CONGESTION" ]]; then
    TCP_CONGESTION="$OPT_CONGESTION"
    TCP_CONGESTION_SOURCE="user"
fi

# Validate congestion control when applying (sysctl --system will fail hard on invalid values).
AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)
if [[ -n "$TCP_CONGESTION" && -n "$AVAILABLE_CC" ]]; then
    if ! grep -qw -- "$TCP_CONGESTION" <<<"$AVAILABLE_CC"; then
        if [[ $OPT_DRY_RUN -eq 1 || $OPT_REPORT -eq 1 ]]; then
            warn "TCP congestion control '$TCP_CONGESTION' not in available list: $AVAILABLE_CC"
        else
            die "TCP congestion control '$TCP_CONGESTION' is not available (available: $AVAILABLE_CC)"
        fi
    fi
fi

# Best-effort: load module for selected congestion control.
# (Many algorithms are built-in; modprobe failures are ignored.)
if [[ $OPT_DRY_RUN -eq 0 ]]; then
    run_quiet modprobe "tcp_$TCP_CONGESTION" 2>/dev/null || true
    [[ "$TCP_CONGESTION" == "bbr" ]] && run_quiet modprobe tcp_bbr 2>/dev/null || true
fi

# Calculate TCP memory limits
TCP_MEM_MIN=$((TCP_MEM_MAX / 4))
TCP_MEM_PRESSURE=$((TCP_MEM_MAX / 2))

backup_file "$CFG_SYSCTL"
[[ $OPT_DRY_RUN -eq 1 && $OPT_REPORT -eq 0 ]] && echo "[DRY-RUN] Would write: $CFG_SYSCTL"
write_file "$CFG_SYSCTL" <<EOF
#===============================================================================
# Network Performance Optimization
# Profile: $OPT_PROFILE | Generated: $(date)
#===============================================================================

#-------------------------------------------------------------------------------
# TCP Memory and Buffers
#-------------------------------------------------------------------------------
# TCP memory limits (pages): min pressure max
net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX

# TCP receive buffer: min default max
net.ipv4.tcp_rmem = 4096 87380 $TCP_RMEM_MAX
net.core.rmem_default = 262144
net.core.rmem_max = $TCP_RMEM_MAX

# TCP send buffer: min default max
net.ipv4.tcp_wmem = 4096 65536 $TCP_WMEM_MAX
net.core.wmem_default = 262144
net.core.wmem_max = $TCP_WMEM_MAX

# UDP buffers
net.core.optmem_max = 65536

#-------------------------------------------------------------------------------
# TCP Performance
#-------------------------------------------------------------------------------
# Congestion control
#
# Notes:
# - BBR works best with fq qdisc.
# - For low-latency profiles, pfifo_fast reduces queuing, but if you override CC
#   to BBR we still force fq to avoid poor behavior.
net.ipv4.tcp_congestion_control = $TCP_CONGESTION
net.core.default_qdisc = $(
    if [ "$TCP_CONGESTION" = "bbr" ]; then
        echo "fq"
    elif [ $OPT_LOW_LATENCY -eq 1 ]; then
        echo "pfifo_fast"
    else
        echo "fq"
    fi
)

# Window scaling and timestamps
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1

# Fast Open
net.ipv4.tcp_fastopen = 3

# MTU probing (disable for latency - adds delay)
net.ipv4.tcp_mtu_probing = $([ $OPT_LOW_LATENCY -eq 1 ] && echo 0 || echo 1)

# Low latency TCP
net.ipv4.tcp_low_latency = $([ $OPT_LOW_LATENCY -eq 1 ] && echo 1 || echo 0)

# Keepalive
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5

# Retries (fewer for latency = faster failure detection)
net.ipv4.tcp_syn_retries = $([ $OPT_LOW_LATENCY -eq 1 ] && echo 2 || echo 3)
net.ipv4.tcp_synack_retries = $([ $OPT_LOW_LATENCY -eq 1 ] && echo 2 || echo 3)
net.ipv4.tcp_retries2 = $([ $OPT_LOW_LATENCY -eq 1 ] && echo 5 || echo 8)

# Orphan handling
net.ipv4.tcp_max_orphans = 65536
net.ipv4.tcp_orphan_retries = 2

# FIN timeout
net.ipv4.tcp_fin_timeout = 15

# Reuse/Recycle
net.ipv4.tcp_tw_reuse = 1

#-------------------------------------------------------------------------------
# Connection Handling
#-------------------------------------------------------------------------------
# Listen backlog
net.core.somaxconn = $SOMAXCONN
net.ipv4.tcp_max_syn_backlog = $SOMAXCONN

# Netfilter conntrack (if loaded)
# net.netfilter.nf_conntrack_max = 1048576

#-------------------------------------------------------------------------------
# Network Device
#-------------------------------------------------------------------------------
net.core.netdev_max_backlog = $NETDEV_MAX_BACKLOG
net.core.netdev_budget = $NETDEV_BUDGET
net.core.netdev_budget_usecs = $NETDEV_BUDGET_USECS

# RPS/RFS global flow table (scaled by CPU cores)
net.core.rps_sock_flow_entries = $((32768 * HW_CPU_CORES))

# Busy polling (low latency)
net.core.busy_poll = $([ $OPT_LOW_LATENCY -eq 1 ] && echo $CONST_BUSY_POLL_LATENCY || echo $CONST_BUSY_POLL_OFF)
net.core.busy_read = $([ $OPT_LOW_LATENCY -eq 1 ] && echo $CONST_BUSY_POLL_LATENCY || echo $CONST_BUSY_POLL_OFF)

#-------------------------------------------------------------------------------
# IPv4 Settings
#-------------------------------------------------------------------------------
# Local port range
net.ipv4.ip_local_port_range = 1024 65535

# Reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ARP
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192
EOF

# IPv6: Only configure if enabled in kernel
if [ -d /proc/sys/net/ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]; then
    append_file "$CFG_SYSCTL" <<'EOF'

#-------------------------------------------------------------------------------
# IPv6 Settings
#-------------------------------------------------------------------------------
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.neigh.default.gc_thresh1 = 1024
net.ipv6.neigh.default.gc_thresh2 = 4096
net.ipv6.neigh.default.gc_thresh3 = 8192
EOF
    echo "  ✓ IPv6: configured"
else
    echo "  -> IPv6: disabled/not available, skipping"
fi

[[ $OPT_DRY_RUN -eq 0 ]] && run_quiet sysctl --system

echo "  ✓ TCP/IP stack: configured"
echo "  ✓ Congestion control: $TCP_CONGESTION ($TCP_CONGESTION_SOURCE)"
echo "  ✓ Buffers: rmem_max=$((TCP_RMEM_MAX / 1024 / 1024))MB, wmem_max=$((TCP_WMEM_MAX / 1024 / 1024))MB"

#-------------------------------------------------------------------------------
# 3.2 NIC HARDWARE OPTIMIZATION (Dynamic Detection)
#-------------------------------------------------------------------------------
echo ""
echo "[NIC] Detecting and optimizing network interfaces..."

command -v ethtool &>/dev/null || pkg_install ethtool || true

# Function: Dynamically detect NIC capabilities and apply optimal settings
optimize_nic() {
    local IFACE=$1
    local driver_link DRIVER
    driver_link=$(readlink "/sys/class/net/$IFACE/device/driver" 2>/dev/null || true)
    DRIVER="${driver_link##*/}"
    [ -z "$DRIVER" ] && return

    echo "  [$IFACE] driver=$DRIVER"

    # Gather all NIC capabilities once (with timeout to avoid hanging)
    local RING CHAN FEAT COAL PRIV SPEED MTU_MAX
    RING=$(timeout 2 ethtool -g "$IFACE" 2>/dev/null) || RING=""
    CHAN=$(timeout 2 ethtool -l "$IFACE" 2>/dev/null) || CHAN=""
    FEAT=$(timeout 2 ethtool -k "$IFACE" 2>/dev/null) || FEAT=""
    COAL=$(timeout 2 ethtool -c "$IFACE" 2>/dev/null) || COAL=""
    PRIV=$(timeout 2 ethtool --show-priv-flags "$IFACE" 2>/dev/null) || PRIV=""
    SPEED=$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null) || SPEED=1000
    [ "$SPEED" = "-1" ] && SPEED=1000
    MTU_MAX=$(ip -d link show "$IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="maxmtu"){print $(i+1); exit}}') || MTU_MAX=$CONST_MTU_FALLBACK
    [[ "$MTU_MAX" =~ ^[0-9]+$ ]] || MTU_MAX=$CONST_MTU_FALLBACK

    # --- Ring Buffers: Use detected max, scaled by profile ---
    # Latency profile uses small rings to reduce queuing delay
    local RX_MAX TX_MAX
    RX_MAX=$(echo "$RING" | awk '/Pre-set/,/Current/{if(/RX:/) print $2}' | head -1)
    TX_MAX=$(echo "$RING" | awk '/Pre-set/,/Current/{if(/TX:/) print $2}' | head -1)
    if [ -n "$RX_MAX" ] && [ "$RX_MAX" -gt 0 ]; then
        local SCALE=$CONST_RING_SCALE_SERVER
        case $OPT_PROFILE in
            vm) SCALE=$CONST_RING_SCALE_VM ;;
            workstation) SCALE=$CONST_RING_SCALE_WORKSTATION ;;
            laptop) SCALE=$CONST_RING_SCALE_LAPTOP ;;
            latency) SCALE=$CONST_RING_SCALE_LATENCY ;;
        esac
        local RX_T
        RX_T=$((RX_MAX * SCALE / 100))
        [ "$RX_T" -lt "$CONST_RING_MIN" ] && RX_T=$CONST_RING_MIN
        local TX_T
        TX_T=$((TX_MAX * SCALE / 100))
        [ "$TX_T" -lt "$CONST_RING_MIN" ] && TX_T=$CONST_RING_MIN
        run ethtool -G "$IFACE" rx "$RX_T" tx "$TX_T" 2>/dev/null &&
            echo "    ✓ Ring: RX=$RX_T/$RX_MAX TX=$TX_T/$TX_MAX"
    fi

    # --- Queues: Match to CPU cores (latency uses all for parallelism) ---
    local Q_MAX
    Q_MAX=$(echo "$CHAN" | awk '/Pre-set/,/Current/{if(/Combined:/) print $2}' | head -1)
    if [ -n "$Q_MAX" ] && [ "$Q_MAX" -gt 1 ]; then
        local Q_T=$Q_MAX
        [ "$Q_T" -gt "$HW_CPU_CORES" ] && Q_T=$HW_CPU_CORES
        [ "$OPT_PROFILE" = "laptop" ] && Q_T=$((Q_T / 2))
        [ "$Q_T" -lt 1 ] && Q_T=1
        run ethtool -L "$IFACE" combined "$Q_T" 2>/dev/null &&
            echo "    ✓ Queues: $Q_T/$Q_MAX (CPUs: $HW_CPU_CORES)"
    fi

    # --- MTU Optimization ---
    # Latency profile keeps default 1500 (smaller packets = faster)
    # Jumbo frames only for high-throughput scenarios with capable instances
    local MTU_CUR
    MTU_CUR=$(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null)
    local MTU_T=$MTU_CUR

    if [ "$OPT_PROFILE" != "latency" ] && [ "$OPT_LOW_LATENCY" -ne 1 ]; then
        if [ "$SPEED" -ge 1000 ] && [ "$MTU_MAX" -ge 1500 ]; then
            case $CLOUD_PROVIDER in
                aws)
                    # AWS: Jumbo frames (9001) supported within same VPC/placement group
                    case $INSTANCE_NET_PERF in
                        ultra | high | medium) MTU_T=$CONST_MTU_AWS ;;
                        *) MTU_T=1500 ;;
                    esac
                    ;;
                azure)
                    # Azure: Jumbo frames require accelerated networking
                    if [ "$DRIVER" = "mlx5_core" ] || [ "$DRIVER" = "mlx4_en" ]; then
                        MTU_T=$CONST_MTU_AZURE
                    elif [ "$DRIVER" = "hv_netvsc" ]; then
                        # Check for VF underneath
                        MTU_T=1500
                        for _vf in "/sys/class/net/$IFACE/lower_"*; do
                            [ -d "$_vf" ] && MTU_T=$CONST_MTU_AZURE && break
                        done
                    else
                        MTU_T=1500
                    fi
                    ;;
                gcp)
                    # GCP: MTU 8896 for gVNIC, 1460 default for VPC
                    if [ "$DRIVER" = "gve" ]; then
                        MTU_T=$CONST_MTU_GCP
                    else
                        MTU_T=$CONST_MTU_GCP_DEFAULT
                    fi
                    ;;
                alibaba)
                    # Alibaba: 8500 for VPC with jumbo frame support
                    case $INSTANCE_NET_PERF in
                        ultra | high | medium) MTU_T=$CONST_MTU_ALIBABA ;;
                        *) MTU_T=1500 ;;
                    esac
                    ;;
                none)
                    # Bare metal / on-prem: use detected max
                    [ "$MTU_MAX" -ge "$CONST_MTU_DEFAULT" ] && MTU_T=$CONST_MTU_DEFAULT
                    ;;
            esac

            # Respect detected max
            [ "$MTU_T" -gt "$MTU_MAX" ] && MTU_T=$MTU_MAX

            # Apply if different from current
            if [ "$MTU_T" != "$MTU_CUR" ]; then
                run_quiet ip link set "$IFACE" mtu "$MTU_T" 2>/dev/null &&
                    echo "    ✓ MTU: $MTU_T (was $MTU_CUR)"
            fi
        fi
    fi

    # --- TX Queue: Scale with link speed ---
    local TXQ
    TXQ=$((SPEED >= 10000 ? 10000 : SPEED >= 1000 ? 5000 : 1000))
    [ "$OPT_PROFILE" = "laptop" ] && TXQ=$((TXQ / 2))
    run_quiet ip link set "$IFACE" txqueuelen "$TXQ" 2>/dev/null || true

    # --- Offloading: Enable all supported (detect from features) ---
    for F in rx-checksumming tx-checksumming scatter-gather \
        generic-segmentation-offload generic-receive-offload tcp-segmentation-offload; do
        if echo "$FEAT" | grep -q "^$F: off"; then
            run_quiet timeout 2 ethtool -K "$IFACE" ${F//-/ } on
        fi
    done
    [[ "$OPT_LOW_LATENCY" -ne 1 ]] && run_quiet timeout 2 ethtool -K "$IFACE" large-receive-offload on || true
    echo "    ✓ Offloading: enabled"

    # --- Coalescing: Detect adaptive support ---
    if [ "$OPT_LOW_LATENCY" -eq 1 ]; then
        run_quiet timeout 2 ethtool -C "$IFACE" adaptive-rx off adaptive-tx off rx-usecs 0 tx-usecs 0 || true
        echo "    ✓ Coalescing: disabled (low-latency)"
    elif echo "$COAL" | grep -q "Adaptive RX"; then
        run_quiet timeout 2 ethtool -C "$IFACE" adaptive-rx on adaptive-tx on || true
        echo "    ✓ Coalescing: adaptive"
    fi

    # --- EEE (Energy Efficient Ethernet): Disable for latency, enable for power saving ---
    local EEE_INFO
    EEE_INFO=$(timeout 2 ethtool --show-eee "$IFACE" 2>/dev/null) || EEE_INFO=""
    if [ -n "$EEE_INFO" ]; then
        if [ "$OPT_PROFILE" = "latency" ] || [ "$OPT_LOW_LATENCY" -eq 1 ] || [ "$OPT_PROFILE" = "server" ]; then
            # Disable EEE: reduces latency jitter by ~10-50µs
            run_quiet timeout 2 ethtool --set-eee "$IFACE" eee off &&
                echo "    ✓ EEE: disabled (reduces latency jitter)"
        elif [ "$OPT_PROFILE" = "laptop" ]; then
            # Enable EEE for power saving
            run_quiet timeout 2 ethtool --set-eee "$IFACE" eee on &&
                echo "    ✓ EEE: enabled (power saving)"
        fi
    fi

    # --- Flow Control ---
    [ "$OPT_PROFILE" = "server" ] && run_quiet timeout 2 ethtool -A "$IFACE" rx on tx on || true

    # --- Driver-specific optimizations ---
    case $DRIVER in
        ena)
            # AWS ENA (Elastic Network Adapter)
            local ENA_VER
            ENA_VER=$(modinfo ena 2>/dev/null | awk '/^version:/{print $2}')

            # LLQ (Low Latency Queue) - reduces latency by ~20µs
            echo "$PRIV" | grep -q "enable_llq" &&
                run_quiet timeout 2 ethtool --set-priv-flags "$IFACE" enable_llq on || true

            # ENI metrics for CloudWatch (if supported)
            echo "$PRIV" | grep -q "enable_ena_admin" &&
                run_quiet timeout 2 ethtool --set-priv-flags "$IFACE" enable_ena_admin on || true

            # Optimize ring size based on instance type (detected from max)
            # Large instances (metal, 8xlarge+) support 16K, smaller support 1K-8K
            local ENA_RX_MAX
            ENA_RX_MAX=$(echo "$RING" | awk '/Pre-set/,/Current/{if(/RX:/) print $2}' | head -1)
            if [ -n "$ENA_RX_MAX" ]; then
                if [ "$OPT_PROFILE" = "latency" ]; then
                    run_quiet timeout 2 ethtool -G "$IFACE" rx 256 tx 256 || true
                elif [ "$ENA_RX_MAX" -ge 8192 ]; then
                    run_quiet timeout 2 ethtool -G "$IFACE" rx "$ENA_RX_MAX" tx "$ENA_RX_MAX" || true
                fi
            fi

            # Enable all supported offloads
            run_quiet timeout 2 ethtool -K "$IFACE" rxhash on || true
            echo "    ✓ ENA: LLQ + optimized (v$ENA_VER)"
            ;;

        efa)
            # AWS EFA (Elastic Fabric Adapter) - for HPC/ML
            # EFA bypasses kernel for RDMA, minimal kernel tuning needed
            echo "$PRIV" | grep -q "enable_llq" &&
                run_quiet timeout 2 ethtool --set-priv-flags "$IFACE" enable_llq on || true
            # Max out ring buffers for HPC workloads
            run_quiet timeout 2 ethtool -G "$IFACE" rx 16384 tx 16384 || true
            echo "    ✓ EFA: HPC mode (use libfabric for RDMA)"
            ;;

        virtio_net)
            # KVM/QEMU/GCP virtio
            run_quiet timeout 2 ethtool -K "$IFACE" rx-gro-hw on tx-nocache-copy off || true
            # Virtio multiqueue - ensure all queues active
            local VQ_MAX
            VQ_MAX=$(echo "$CHAN" | awk '/Pre-set/,/Current/{if(/Combined:/) print $2}' | head -1)
            [ -n "$VQ_MAX" ] && [ "$VQ_MAX" -gt 1 ] &&
                run_quiet timeout 2 ethtool -L "$IFACE" combined "$VQ_MAX" || true
            echo "    ✓ Virtio: multiqueue + GRO"
            ;;

        hv_netvsc)
            # Azure/Hyper-V - often paired with Mellanox VF (accelerated networking)
            # Check for VF (SR-IOV) presence
            local VF_IFACE
            VF_IFACE=$(find "/sys/class/net/$IFACE" -maxdepth 1 -name 'lower_*' 2>/dev/null | head -1 | xargs -r basename 2>/dev/null)
            if [ -n "$VF_IFACE" ]; then
                echo "    -> Azure accelerated networking: VF=$VF_IFACE"
                # Optimize the underlying VF instead
                optimize_nic "$VF_IFACE"
            else
                run_quiet timeout 2 ethtool -K "$IFACE" lro on sg on || true
                echo "    ✓ Hyper-V: LRO enabled"
            fi
            ;;

        gve)
            # GCP gVNIC (next-gen virtual NIC)
            run_quiet timeout 2 ethtool -K "$IFACE" rxhash on || true
            # GCP supports up to 16 queues
            local GVE_Q
            GVE_Q=$(echo "$CHAN" | awk '/Pre-set/,/Current/{if(/Combined:/) print $2}' | head -1)
            [ -n "$GVE_Q" ] && run_quiet timeout 2 ethtool -L "$IFACE" combined "$GVE_Q" || true
            echo "    ✓ gVNIC: multiqueue"
            ;;

        mlx5_core | mlx4_en)
            # Mellanox (bare metal, Azure VF, some cloud HPC)
            echo "$PRIV" | grep -q "rx_cqe_compress" &&
                run_quiet timeout 2 ethtool --set-priv-flags "$IFACE" rx_cqe_compress on || true
            echo "$PRIV" | grep -q "tx_cqe_compress" &&
                run_quiet timeout 2 ethtool --set-priv-flags "$IFACE" tx_cqe_compress on || true
            run_quiet timeout 2 ethtool -K "$IFACE" rxhash on || true
            echo "    ✓ Mellanox: CQE compression"
            ;;

        i40e | ice | ixgbe)
            # Intel (bare metal, some cloud)
            echo "$PRIV" | grep -q "flow-director-atr" &&
                run_quiet timeout 2 ethtool --set-priv-flags "$IFACE" flow-director-atr on || true
            run_quiet timeout 2 ethtool -K "$IFACE" ntuple on rxhash on || true
            echo "    ✓ Intel: Flow Director"
            ;;

        # Alibaba Cloud drivers
        aliyun_* | erdma)
            # Alibaba Cloud eRDMA (Elastic RDMA)
            run_quiet timeout 2 ethtool -K "$IFACE" rxhash on || true
            local ALI_Q
            ALI_Q=$(echo "$CHAN" | awk '/Pre-set/,/Current/{if(/Combined:/) print $2}' | head -1)
            [ -n "$ALI_Q" ] && run_quiet timeout 2 ethtool -L "$IFACE" combined "$ALI_Q" || true
            echo "    ✓ Alibaba eRDMA: multiqueue"
            ;;
    esac

    # Cloud-specific virtio tuning
    if [ "$DRIVER" = "virtio_net" ] && [ "$CLOUD_PROVIDER" = "alibaba" ]; then
        # Alibaba uses virtio with specific optimizations
        run_quiet timeout 2 ethtool -K "$IFACE" tx-udp_tnl-segmentation on || true
        echo "    ✓ Alibaba virtio: tunnel offload"
    fi
}

# Iterate physical interfaces
for IFACE in /sys/class/net/*; do
    IFACE=$(basename "$IFACE")
    [[ "$IFACE" =~ ^(lo|docker.*|br-.*|veth.*|virbr.*)$ ]] && continue
    [ -d "/sys/class/net/$IFACE/device" ] && optimize_nic "$IFACE"
done

# BPF JIT (best effort)
[ -f /proc/sys/net/core/bpf_jit_enable ] && write_value_quiet /proc/sys/net/core/bpf_jit_enable 1

#-------------------------------------------------------------------------------
# 3.3 IRQ AFFINITY AND RPS/RFS
#-------------------------------------------------------------------------------
echo ""
echo "[IRQ] Configuring packet steering..."

cpu_mask_for_cores() {
    local cores=$1
    [[ $cores -lt 1 ]] && cores=1
    local groups, rem, mask
    groups=$(((cores + 31) / 32))
    rem=$((cores % 32))
    mask=""
    local i
    for ((i = 0; i < groups; i++)); do
        if ((i == 0 && rem != 0)); then
            mask+=$(printf '%08x' $(((1 << rem) - 1)))
        else
            mask+="ffffffff"
        fi
        ((i < groups - 1)) && mask+=","
    done
    printf '%s\n' "$mask"
}

# Check if irqbalance is managing IRQ affinity
if irqbalance_running; then
    echo "  INFO: irqbalance is active - skipping manual IRQ affinity"
    echo "  INFO: RPS/RFS/XPS will still be configured"
fi

if [ "$HW_CPU_CORES" -gt 1 ]; then
    CPU_MASK=$(cpu_mask_for_cores "$HW_CPU_CORES")
    RFS_ENTRIES=$((32768 / HW_CPU_CORES))

    for IFACE in /sys/class/net/*; do
        IFACE=$(basename "$IFACE")
        [[ "$IFACE" =~ ^(lo|docker.*|br-.*|veth.*|virbr.*)$ ]] && continue
        [ -d "/sys/class/net/$IFACE/device" ] || continue

        if [ "$OPT_DRY_RUN" -eq 1 ]; then
            [[ $OPT_REPORT -eq 0 ]] && echo "  [DRY-RUN] Would configure RPS/RFS/XPS for $IFACE (mask=$CPU_MASK)"
        else
            # RPS/RFS
            for rxq in "/sys/class/net/$IFACE/queues/rx-"*/rps_cpus; do
                [ -f "$rxq" ] && write_value_quiet "$rxq" "$CPU_MASK"
            done
            for rxq in "/sys/class/net/$IFACE/queues/rx-"*/rps_flow_cnt; do
                [ -f "$rxq" ] && write_value_quiet "$rxq" "$RFS_ENTRIES"
            done

            # XPS: allow any CPU (simple + portable)
            for txq in "/sys/class/net/$IFACE/queues/tx-"*/xps_cpus; do
                [ -f "$txq" ] && write_value_quiet "$txq" "$CPU_MASK"
            done
            echo "  ✓ $IFACE: RPS/RFS/XPS"
        fi
    done

    write_value_quiet /proc/sys/net/core/rps_sock_flow_entries $((32768 * HW_CPU_CORES))
fi

#-------------------------------------------------------------------------------
# 3.4 CONNTRACK OPTIMIZATION
#-------------------------------------------------------------------------------
echo ""
echo "[CONNTRACK] Configuring connection tracking..."

if lsmod | grep -q nf_conntrack; then
    # Auto-tune conntrack based on RAM: ~256 bytes per entry
    case $OPT_PROFILE in
        server)
            CONNTRACK_MAX=$((HW_MEM_TOTAL_GB * CONST_CONNTRACK_PER_GB_SERVER))
            [ $CONNTRACK_MAX -gt $CONST_CONNTRACK_MAX_CAP ] && CONNTRACK_MAX=$CONST_CONNTRACK_MAX_CAP
            [ $CONNTRACK_MAX -lt 262144 ] && CONNTRACK_MAX=262144
            ;;
        vm)
            CONNTRACK_MAX=$((HW_MEM_TOTAL_GB * CONST_CONNTRACK_PER_GB_VM))
            [ $CONNTRACK_MAX -gt 1048576 ] && CONNTRACK_MAX=1048576
            [ $CONNTRACK_MAX -lt 131072 ] && CONNTRACK_MAX=131072
            ;;
        *)
            CONNTRACK_MAX=$((HW_MEM_TOTAL_GB * CONST_CONNTRACK_PER_GB_OTHER))
            [ $CONNTRACK_MAX -lt $CONST_CONNTRACK_MIN ] && CONNTRACK_MAX=$CONST_CONNTRACK_MIN
            ;;
    esac
    CONNTRACK_BUCKETS=$((CONNTRACK_MAX / 4))

    write_value_quiet /proc/sys/net/netfilter/nf_conntrack_max "$CONNTRACK_MAX"
    write_value_quiet /sys/module/nf_conntrack/parameters/hashsize "$CONNTRACK_BUCKETS"

    append_file "$CFG_SYSCTL" <<EOF

# Connection Tracking (auto-tuned: ${HW_MEM_TOTAL_GB}GB RAM)
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
EOF
    echo "  ✓ Conntrack: max=$CONNTRACK_MAX"
else
    echo "  -> Conntrack: not loaded"
fi

#===============================================================================
# PHASE 4: PERSISTENCE
#===============================================================================

echo ""
echo ">>> Phase 3: Creating Persistence Service..."

backup_file "$CFG_SERVICE"
write_file "$CFG_SERVICE" <<EOF
# =============================================================================
# $CFG_SERVICE
# Auto-generated by network_optimize.sh (profile=$OPT_PROFILE)
#
# This unit re-applies a subset of NIC/RPS tuning at boot. Kernel parameters are
# persisted in:
#   $CFG_SYSCTL
#
# Disable:
#   systemctl disable network-optimize.service
# =============================================================================

[Unit]
Description=Network Performance Optimization (network_optimize.sh)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot

# Re-apply sysctl parameters.
ExecStart=/usr/bin/env sysctl --system

# Re-apply RPS CPU masks (best effort).
ExecStart=/bin/bash -c 'cores=\$(nproc 2>/dev/null || echo 1); groups=\$(( (cores + 31) / 32 )); rem=\$(( cores % 32 )); mask=""; for ((i=0; i<groups; i++)); do if (( i==0 && rem!=0 )); then mask+=\$(printf "%08x" \$(( (1<<rem) - 1 ))); else mask+="ffffffff"; fi; (( i<groups-1 )) && mask+=","; done; for f in /sys/class/net/*/queues/rx-*/rps_cpus /sys/class/net/*/queues/tx-*/xps_cpus; do [ -f "\$f" ] && echo "\$mask" > "\$f" 2>/dev/null || true; done'

# Re-enable common offloads (best effort).
ExecStart=/bin/bash -c 'command -v ethtool >/dev/null 2>&1 || exit 0; for dev in /sys/class/net/*/device; do dev=\${dev%/device}; iface=\${dev##*/}; ethtool -K "\$iface" gro on gso on tso on >/dev/null 2>&1 || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

run systemctl daemon-reload
run systemctl enable network-optimize.service 2>/dev/null || true
echo "  ✓ Service: network-optimize.service enabled"

#===============================================================================
# PHASE 5: SUMMARY
#===============================================================================

echo ""
echo "================================================================================"
echo "                           OPTIMIZATION COMPLETE"
echo "================================================================================"
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────────┐"
echo "│ APPLIED OPTIMIZATIONS                                                       │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
printf "│   %-73.73s │\n" "- Profile: $OPT_PROFILE"
printf "│   %-73.73s │\n" "- Congestion control: $TCP_CONGESTION ($TCP_CONGESTION_SOURCE)"
printf "│   %-73.73s │\n" "- TCP buffers: rmem=$((TCP_RMEM_MAX / 1024 / 1024))MB wmem=$((TCP_WMEM_MAX / 1024 / 1024))MB"
printf "│   %-73.73s │\n" "- somaxconn: $SOMAXCONN"
printf "│   %-73.73s │\n" "- netdev_max_backlog: $NETDEV_MAX_BACKLOG"
[ $OPT_LOW_LATENCY -eq 1 ] && printf "│   %-73.73s │\n" "- Low-latency: busy_poll enabled"
[ $OPT_HIGH_THROUGHPUT -eq 1 ] && printf "│   %-73.73s │\n" "- High-throughput: large buffers"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
echo "│ FILES CREATED                                                               │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
printf "│   %-73s │\n" "$CFG_SYSCTL"
printf "│   %-73s │\n" "$CFG_SERVICE"
echo "└─────────────────────────────────────────────────────────────────────────────┘"

# --- Rollback Instructions ---
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────────┐"
echo "│ ROLLBACK INSTRUCTIONS                                                       │"
echo "├─────────────────────────────────────────────────────────────────────────────┤"
printf "│   %-73s │\n" "# Remove all optimization configs"
printf "│   %-73.73s │\n" "sudo rm -f $CFG_SYSCTL \\"
printf "│   %-73.73s │\n" "           $CFG_SERVICE"
printf "│   %-73s │\n" ""
printf "│   %-73s │\n" "# Disable boot service"
printf "│   %-73s │\n" "sudo systemctl disable network-optimize.service"
printf "│   %-73s │\n" ""
printf "│   %-73s │\n" "# Reload sysctl defaults"
printf "│   %-73s │\n" "sudo sysctl --system"
printf "│   %-73s │\n" ""
printf "│   %-73s │\n" "# Or use built-in cleanup"
printf "│   %-73s │\n" "sudo $0 --cleanup"
echo "└─────────────────────────────────────────────────────────────────────────────┘"

echo ""
if [ $OPT_DRY_RUN -eq 1 ]; then
    echo "INFO: DRY-RUN complete. No changes were made."
else
    echo "OK: Network optimizations active. No reboot required."
fi
echo ""
echo "================================================================================"
