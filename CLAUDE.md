# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Linux system optimization scripts providing hardware-aware performance tuning. Two independent scripts plus a shared helper library:
- `system_optimize.sh`: CPU, memory, I/O, filesystem, kernel parameters
- `network_optimize.sh`: TCP/IP stack, NIC hardware, packet steering
- `lib/common.sh`: sourced by both scripts — logging, `run`/`run_quiet`, `write_value*`/`write_file`/`append_file`, `verify_sysctl`/`verify_sysfs`, backup/restore, `parse_os_release`, `validate_input`/`validate_dir`

**Separation rule:** Keep `net.*` sysctl keys exclusively in `network_optimize.sh`.

**lib/common.sh rule:** No top-level side effects, no script-specific mode switches. If only one script needs it, keep it in that script.

## Build and Validation Commands

```bash
# Full gate: syntax + shellcheck + bashate + bats (required before PRs)
make check

# Individual gates
make syntax      # bash -n on both scripts
make shellcheck  # shellcheck
make bashate     # bashate -i E006
make test        # bats tests/

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

`make check` runs the full gate. It covers:
1. Syntax (`bash -n`) for both scripts
2. Shellcheck and bashate (`-i E006`)
3. Bats suite under `tests/`:
   - `cli.bats` — black-box CLI contracts (help, unknown flags, profile validation, every profile dry-runs, `--report` snippet content, root guard, `--isolate-cpus` range)
   - `grub_sed_atomic.bats` — the atomic GRUB-edit helper (single + multi-expr, permission preservation, rollback on sed failure, dry-run/report modes)
   - `os_release.bats` — `/etc/os-release` parser against Ubuntu/RHEL/Amazon Linux/Arch fixtures plus an injection canary
   - `isolate_cpus.bats` — range validator edge cases

Before PRs, also run at least one `--dry-run` and `--report` on a live host,
and `--verify` to exercise drift detection (exits 0 if all match, 1 if drift).
Multi-platform testing (AWS/GCP/Azure/bare metal) when possible.

### Adding tests

Prefer black-box CLI tests in `cli.bats` for new flags. For a new pure
function, use `tests/helpers/extract_fn.sh` to pluck the function body out
of the script and `eval` it into the test shell (see `grub_sed_atomic.bats`
for the pattern). Avoid sourcing the full script — it calls `die` during
setup on non-root hosts.
