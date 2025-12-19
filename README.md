# Linux System Optimization Scripts

Comprehensive, hardware-aware performance tuning scripts for Linux systems. Automatically detects hardware configuration and applies tailored optimizations.

## Features

- **Auto-Detection**: Automatically detects CPU, RAM, storage, cloud provider, and instance type
- **Profile-Based**: Multiple optimization profiles for different use cases
- **Cloud-Aware**: Specific optimizations for AWS, Azure, GCP, and Alibaba Cloud
- **Dynamic Tuning**: Values scaled based on detected hardware capabilities
- **Safe Defaults**: Conservative defaults with optional aggressive tuning
- **Dry-Run Mode**: Preview changes before applying

## Scripts

| Script | Purpose |
|--------|---------|
| `system_optimize.sh` | CPU, memory, I/O, filesystem, and kernel tuning |
| `network_optimize.sh` | TCP/IP stack, NIC hardware, and packet steering |

## Quick Start

```bash
# Make scripts executable
chmod +x system_optimize.sh network_optimize.sh

# Run with auto-detection (recommended first run; no sudo needed)
./system_optimize.sh --dry-run
./network_optimize.sh --dry-run

# Or generate recommended config files (no sudo needed)
./system_optimize.sh --report > system_report.txt

# Apply optimizations
sudo ./system_optimize.sh
sudo ./network_optimize.sh
```

## Profiles

| Profile | Use Case | Characteristics |
|---------|----------|-----------------|
| `server` | Web/DB servers, high-load systems | Max throughput, large buffers, aggressive caching |
| `vm` | Cloud VMs (EC2, Azure, GCP) | Cloud-optimized, instance-type aware |
| `workstation` | Desktop/development machines | Balanced performance and responsiveness |
| `laptop` | Battery-powered devices | Power efficiency, conservative settings |
| `latency` | Trading, gaming, real-time | Minimal latency, no buffering, busy polling |
| `auto` | Auto-detect based on hardware | Default - detects VM, battery, CPU count |

### TuneD Profile Equivalents

These scripts can be used alongside or instead of TuneD. Equivalent TuneD profiles:

| Script Profile | TuneD Equivalent |
|----------------|------------------|
| `server` | `throughput-performance` |
| `vm` | `virtual-guest` |
| `workstation` | `desktop` |
| `laptop` | `powersave` |
| `latency` | `latency-performance` or `network-latency` |

## Usage Examples

### Basic Usage
```bash
# Auto-detect and optimize
sudo ./system_optimize.sh
sudo ./network_optimize.sh

# Specify profile
sudo ./system_optimize.sh --profile=server
sudo ./network_optimize.sh --profile=server
```

### Low-Latency Optimization
```bash
# For trading, gaming, or real-time applications
sudo ./system_optimize.sh --profile=latency
sudo ./network_optimize.sh --profile=latency
```

### High-Throughput Optimization
```bash
# For bulk data transfer, backup servers
sudo ./network_optimize.sh --profile=server --high-throughput
```

### Cloud VM Optimization
```bash
# Auto-detects cloud provider and instance type
sudo ./system_optimize.sh --profile=vm
sudo ./network_optimize.sh --profile=vm
```

### Preview Changes (Dry-Run)
```bash
# See what would be changed without applying
sudo ./system_optimize.sh --dry-run
sudo ./network_optimize.sh --dry-run
```

## Command-Line Options

### system_optimize.sh

| Option | Description |
|--------|-------------|
| `--profile=TYPE` | Optimization profile (server/vm/workstation/laptop/latency/auto) |
| `--disable-mitigations` | Disable CPU security mitigations (DANGEROUS, requires reboot) |
| `--disable-smt` | Disable SMT/Hyper-Threading |
| `--low-latency` | Same as --profile=latency |
| `--isolate-cpus=N-M` | Isolate CPUs from scheduler (requires reboot) |
| `--relax-security` | Disable non-essential security services |
| `--disable-services` | Disable non-essential system services |
| `--reclaim-memory` | Run one-time memory reclaim actions (drop caches/compact) |
| `--apply-fs-tuning` | Apply filesystem-changing actions (tune2fs/xfs_io/btrfs sysfs/fstrim) |
| `--report` | Print recommended config files and exit (no changes) |
| `--yes` | Assume "yes" for dangerous prompts (non-interactive) |
| `--dry-run` | Preview changes without applying |
| `--cleanup` | Remove all changes and restore defaults |
| `--help` | Show help |

### network_optimize.sh

| Option | Description |
|--------|-------------|
| `--profile=TYPE` | Optimization profile (server/vm/workstation/laptop/latency/auto) |
| `--congestion=ALG` | Override TCP congestion control (e.g., bbr, cubic) |
| `--high-throughput` | Optimize for maximum bandwidth (64MB buffers) |
| `--low-latency` | Same as --profile=latency |
| `--dry-run` | Preview changes without applying |
| `--report` | Print recommended config files and exit (no changes) |
| `--cleanup` | Remove all changes and restore defaults |
| `--help` | Show help |

## Files Created

### system_optimize.sh
```
/etc/sysctl.d/99-system-optimize.conf         - Kernel parameters
/etc/security/limits.d/99-system-optimize.conf - Resource limits
/etc/modprobe.d/99-system-optimize-blacklist.conf - Module blacklist
/etc/systemd/system/system-optimize.service   - Persistence service
```

### network_optimize.sh
```
/etc/sysctl.d/99-network-optimize.conf        - Network parameters
/etc/systemd/system/network-optimize.service  - Persistence service
```

## Auto-Tuning

The scripts automatically scale settings based on detected hardware:

| Setting | Auto-Tuning Method |
|---------|-------------------|
| TCP buffers | Profile + instance network tier |
| TCP memory | Percentage of total RAM |
| NIC ring buffers | Percentage of detected max |
| NIC queues | Min(device max, CPU cores) |
| nofile limit | RAM_GB × multiplier |
| nproc limit | CPU_cores × multiplier |
| nr_requests | Percentage of device max |
| read_ahead_kb | Scaled by RAM size |
| conntrack_max | RAM_GB × entries_per_GB |
| MTU | Detected max + cloud-specific |

## Cloud Support

### AWS EC2
- Instance type detection via IMDSv2 (with IMDSv1 fallback)
- EBS vs Instance Store detection and tuning
- ENA driver optimization (LLQ, ring buffers)
- EFA support for HPC workloads
- Network performance tier classification
- Jumbo frames (MTU 9001) enabled by default for VPC traffic
- NVMe device detection with proper sysfs path handling

### Azure
- VM size detection via IMDS
- Accelerated networking (Mellanox VF) detection
- Managed Disk vs Temp Disk optimization
- Lsv2/Lsv3 local NVMe support

### GCP
- Machine type detection via metadata
- gVNIC and virtio_net optimization
- Persistent Disk vs Local SSD tuning
- Tier_1 networking support
- Proper handling of unknown link speeds

### Alibaba Cloud
- Instance type detection
- Cloud Disk vs Local SSD optimization
- eRDMA support

## Customization

### Modifying Constants

All tuning constants are consolidated at the top of each script:

```bash
# In network_optimize.sh
readonly CONST_TCP_BUF_SERVER=$((16 * 1024 * 1024))  # Adjust buffer size
readonly CONST_RING_SCALE_SERVER=100                  # Adjust ring buffer %

# In system_optimize.sh
readonly CONST_SCHED_LATENCY_SERVER=24000000         # Adjust scheduler
readonly CONST_NOFILE_PER_GB_SERVER=65536            # Adjust limits
```

### Adding Custom Profiles

1. Add constants for the new profile
2. Add case statement handling in profile selection
3. Test with `--dry-run`

## Requirements

- Linux kernel 4.x, 5.x, or 6.x
- x86_64 architecture (Intel or AMD)
- Root privileges (sudo)
- ethtool (for NIC optimization)
- curl (for cloud metadata)

## Supported Distributions

- Ubuntu / Debian
- Arch Linux
- Fedora
- RHEL / CentOS / Rocky Linux
- Amazon Linux 2023

## Safety Notes

1. **Always test in non-production first**
2. **Use `--dry-run` to preview changes**
3. **Backup important data before running**
4. **Some changes require reboot** (mitigations, CPU isolation, GRUB params)
5. **`--disable-mitigations` is dangerous** - only use if you understand the security implications

### Risk Levels by Option

| Option | Risk Level | Description |
|--------|------------|-------------|
| `--dry-run` | None | Preview only, no changes made |
| `--report` | None | Generate config files only |
| `--profile=*` | Low | Safe kernel parameter tuning |
| `--reclaim-memory` | Low | Temporary cache clearing |
| `--apply-fs-tuning` | Medium | Modifies filesystem metadata |
| `--disable-services` | Medium | Disables system services |
| `--relax-security` | Medium | Reduces security monitoring |
| `--isolate-cpus` | Medium | Requires reboot, affects scheduling |
| `--disable-smt` | Medium | Disables Hyper-Threading |
| `--disable-mitigations` | **HIGH** | Disables CPU security protections |

### Operations That Require Confirmation

The following options prompt for confirmation (bypass with `--yes`):
- `--disable-mitigations` - Disables Spectre/Meltdown protections
- `--relax-security` - Disables audit daemon
- `--disable-services` - Stops and disables system services
- `--apply-fs-tuning` - Modifies filesystem metadata

## Backup & Restore

The scripts automatically backup original files before modification:

### Backup Location
```
/var/backups/system-optimize-YYYYMMDD-HHMMSS/
/var/backups/network-optimize-YYYYMMDD-HHMMSS/
```

### Reverting Changes

Use the built-in cleanup command (recommended):
```bash
# Restore from latest backup
sudo ./system_optimize.sh --cleanup
sudo ./network_optimize.sh --cleanup

# Restore from specific backup
sudo ./system_optimize.sh --restore-from=/var/backups/system-optimize-20231218-120000
```

Manual cleanup (if needed):
```bash
# Remove configuration files
sudo rm /etc/sysctl.d/99-system-optimize.conf
sudo rm /etc/sysctl.d/99-network-optimize.conf
sudo rm /etc/security/limits.d/99-system-optimize.conf
sudo rm /etc/modprobe.d/99-system-optimize-blacklist.conf

# Disable services
sudo systemctl disable system-optimize.service
sudo systemctl disable network-optimize.service

# Reload sysctl
sudo sysctl --system

# Reboot to fully revert
sudo reboot
```

## irqbalance Integration

The network optimization script detects if `irqbalance` is running:
- If active: skips manual IRQ affinity settings (lets irqbalance manage)
- RPS/RFS/XPS are still configured regardless

This prevents conflicts between manual IRQ affinity and irqbalance.

## License

MIT License - See LICENSE file for details.

## Contributing

Contributions welcome! Please test changes thoroughly and include documentation updates.
