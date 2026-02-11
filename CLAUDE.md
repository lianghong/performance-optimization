# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Linux system optimization scripts (~5,400 lines of Bash) providing hardware-aware performance tuning. Two independent scripts handle separate concerns:
- `system_optimize.sh`: CPU, memory, I/O, filesystem, kernel parameters
- `network_optimize.sh`: TCP/IP stack, NIC hardware, packet steering

**Separation rule:** Keep `net.*` sysctl keys exclusively in `network_optimize.sh`.

## Build and Validation Commands

```bash
# Syntax check (required before PRs)
bash -n system_optimize.sh
bash -n network_optimize.sh

# Linting
shellcheck system_optimize.sh network_optimize.sh
bashate -i E006 system_optimize.sh network_optimize.sh

# Safe preview (no root required)
./system_optimize.sh --dry-run --profile=workstation
./network_optimize.sh --dry-run --profile=workstation

# Generate config reports (no root required)
./system_optimize.sh --report > system_report.txt
./network_optimize.sh --report > network_report.txt

# Verify applied settings match live system (no root required)
./system_optimize.sh --verify
./network_optimize.sh --verify
```

## Architecture

Both scripts follow a 5-phase execution pattern:
1. **Initialization** - Parse args, validate options, setup helpers
2. **Hardware Detection** - CPU/RAM/NUMA, VM vs bare metal, cloud provider/instance type
3. **Apply Optimizations** - Calculate profile values, configure kernel params, apply settings
4. **Persistence** - Create systemd service for boot-time re-application
5. **Summary** - Display changes, provide rollback instructions

### Profile System

Six profiles with distinct tuning: `server`, `vm`, `workstation`, `laptop`, `latency`, `auto` (default, auto-detects environment).

### Cloud Provider Support

AWS EC2 (IMDSv2 with v1 fallback, ENA/EFA), Azure (accelerated networking), GCP (gVNIC), Alibaba (eRDMA). Instance type detection drives network performance tier classification.

## Coding Conventions

- Strict mode: `set -euo pipefail` with quoted variables (`"$var"`)
- Use `${var:-}` for optional variables (prevents unbound variable errors)
- Side effects through helpers only:
  - `run`/`run_quiet` for commands
  - `write_value`/`write_file`/`append_file` for writes
  - `verify_sysctl`/`verify_sysfs` for drift detection
  - These respect `--dry-run`, `--report`, and `--verify` modes
- Concurrent execution prevented by `flock`-based lock file (`/var/run/*.lock`)
- Tuning constants consolidated at script top for easy customization
- Generated config files use `99-*.conf` naming pattern

## Common Pitfalls

- Array access without existence check (use `${array[key]:-}`)
- Commands that may fail with `set -e` (add `|| true` where appropriate)
- Integer division truncation (add rounding for GB calculations)
- Cloud metadata timeouts (use `-m1` timeout with curl)
- Systemd unit file specifier escaping (use `%%` for literal `%`)

## Testing Guidance

No automated test suite. Minimum validation:
1. Syntax check (`bash -n`) for both scripts
2. Shellcheck and bashate for both scripts
3. At least one `--dry-run` and one `--report` run per change
4. Run `--verify` to confirm drift detection works (exits 0 if all match, 1 if drift)
5. Multi-platform testing when possible (AWS/GCP/Azure/bare metal)
