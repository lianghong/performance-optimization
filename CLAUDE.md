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

### Persistence: keep shell out of `ExecStart=`

The systemd units generated in Phase 4 must contain nothing but plain
`ExecStart=-<absolute path>` lines. Everything else — globs, loops, parameter
expansion — belongs in the generated boot helper script
(`CFG_BOOT_SCRIPT`, i.e. `/usr/local/sbin/{system,network}-optimize-boot.sh`),
which is written with `write_file "$path" 0755`. Reasons:

- systemd erases `${NAME}` when the variable is unset and does not run a shell,
  so an inline `for`/`${var%suffix}` silently becomes a no-op, not an error.
- `%` is a specifier prefix and needs `%%` escaping in a unit but not in a script.
- Every `ExecStart=` needs the `-` prefix. Under `Type=oneshot`, one failing
  un-prefixed line aborts the unit and **skips all later `ExecStart=` lines**
  (`systemd.service(5)`), so a missing sysctl key can cost you every
  subsequent setting.

The boot script must mirror the live apply path (same interface filter, same
guards, same values) and must stay silent: wrap sysfs writes as
`{ printf '%s\n' "$v" >"$p"; } 2>/dev/null` — a bare `>"$p" 2>/dev/null`
still leaks the redirect-open error and spams the journal each boot.
Bake literal values into the heredoc; `tests/boot_script.bats` fails if a
`${PROFILE_*}`/`${SERVICE_*}`/`${TUNE_*}` reference survives into the artifact.

## Common Pitfalls

- Array access without existence check (use `${array[key]:-}`)
- Commands that may fail with `set -e` (add `|| true` where appropriate)
- Integer division truncation (add rounding for GB calculations)
- Cloud metadata timeouts (use `-m1` timeout with curl)
- Systemd unit file specifier escaping (use `%%` for literal `%`)
- Bare `VAR=$(cmd | grep ...)` aborts the script under `pipefail` when `grep`
  finds nothing or the binary is missing — wrap such probes in a function that
  returns 0 (see `sar_interval_from_cron`, `xfs_log_line`, `btrfs_uuid_for`)
- The kernel strips leading zeros from CPU masks it echoes back, so compare
  `rps_cpus`/`xps_cpus` through `normalize_cpu_mask`, never verbatim

## Testing Guidance

`make check` runs the full gate. It covers:
1. Syntax (`bash -n`) for both scripts
2. Shellcheck and bashate (`-i E006`)
3. Bats suite under `tests/`:
   - `cli.bats` — black-box CLI contracts (help, unknown flags, profile validation, every profile dry-runs, `--report` snippet content, root guard, `--isolate-cpus` range, `ExecStart=` invariants)
   - `boot_script.bats` — the generated `/usr/local/sbin/*-boot.sh` helpers: extracted from `--report`, parsed with `bash -n`, run unprivileged (must exit 0 and print nothing), checked for baked-in literal values and mask agreement with the live path
   - `report_probes.bats` — the `sar_interval_from_cron` / `xfs_log_line` / `btrfs_uuid_for` probes, which must survive no-match `grep` and missing binaries under `pipefail`
   - `cpu_mask.bats` — `cpu_mask_for_cores` and `normalize_cpu_mask` (the kernel strips leading zeros from the mask it echoes back)
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
