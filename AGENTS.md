# Repository Guidelines

## Project Structure

- `system_optimize.sh`: system performance tuning (CPU/memory/storage/filesystems) with `--dry-run`/`--report`/`--verify` safety modes.
- `network_optimize.sh`: network tuning (TCP/IP, NIC offloads, RPS/RFS/XPS) with `--dry-run`/`--report`/`--verify`.
- `lib/common.sh`: shared helpers (logging, `run`/`write_value`/`write_file`, `verify_*`, backup/restore, `parse_os_release`). Sourced by both scripts — keep it free of script-specific logic and side effects at top level.
- `README.md`: usage, options, and examples.
- `tests/`: Bats suite (`*.bats`) covering the CLI, `grub_sed_atomic`, `/etc/os-release` parsing, and `--isolate-cpus` validation. Run with `make test` or `bats tests/`.
- `Makefile`: `make check` runs syntax + shellcheck + bashate + bats.
- `completions/system-optimize.bash`: bash completion shared by both scripts.
  - Separation rule: keep `net.*` sysctl tuning in `network_optimize.sh` and avoid introducing overlapping `net.*` keys in `system_optimize.sh`.

## Build, Test, and Development Commands

- Full gate (required before PRs): `make check` (syntax + shellcheck + bashate + bats)
- Individual gates: `make syntax`, `make shellcheck`, `make bashate`, `make test`
- Safe preview (no root required):
  - `./system_optimize.sh --dry-run --profile=workstation`
  - `./network_optimize.sh --dry-run --profile=workstation`
- Generate recommended configs (no root required):
  - `./system_optimize.sh --report > system_report.txt`
  - `./network_optimize.sh --report > network_report.txt`

## Coding Style & Naming Conventions

- Language: Bash. Keep `set -euo pipefail` and quote variables (`"$var"`).
- Prefer existing safety helpers for side effects:
  - Use `run`/`run_quiet` for commands and `write_value`/`write_file`/`append_file` for writes (ensures `--dry-run`/`--report`/`--verify` remain non-destructive).
  - Use `verify_sysctl`/`verify_sysfs` for `--verify` drift detection checks.
- Output formatting: box tables assume fixed widths; avoid Unicode bullets/arrows inside padded `printf` fields (use ASCII like `-` and `->`).
- File names: generated configs use `99-*.conf` naming in `/etc/*` and `*.service` in `/etc/systemd/system/`.

## Testing Guidelines

- Automated: `make check` (syntax, shellcheck, bashate, bats). Bats suites in `tests/` cover CLI contracts, `grub_sed_atomic`, `/etc/os-release` parsing, and `--isolate-cpus` range validation. No root required.
- For a new pure function, use `tests/helpers/extract_fn.sh` to pluck the function body and eval it into the test shell — do not source the full script (it `die`s early on non-root hosts).
- Live-host checks: run `--dry-run`, `--report`, and `--verify` before proposing changes to ensure output/heredoc rendering still works.
- Test on multiple platforms when possible:
  - AWS EC2 (various instance types, IMDSv2)
  - GCP Compute Engine (e2-micro and larger)
  - Azure VMs
  - Bare metal / on-premises
- Common issues to watch for:
  - Unbound variables with `set -u` (use `${var:-}` for optional variables)
  - Array access without checking existence (use `${array[key]:-}`)
  - Commands that may fail with `set -e` (add `|| true` where appropriate)
  - Integer division truncation (add rounding for GB calculations)
  - Cloud metadata timeouts (use `-m1` timeout with curl)

## Commit & Pull Request Guidelines

- This workspace currently has no `.git` history; if you add Git, use clear, imperative commit messages (e.g., “Fix dry-run side effects”).
- PRs should include:
  - The exact command used to reproduce/validate (`--dry-run`/`--report` outputs if relevant)
  - Notes on distro/profile assumptions (Ubuntu/Debian/Fedora/Arch/RHEL-family/AL2023)
  - Any safety-impacting changes called out explicitly (writes to `/etc`, sysctl, systemd, NIC settings).

## Security & Safety Notes

- Treat apply mode as high-impact: prefer `--dry-run`/`--report` first.
- Avoid destructive defaults; gate disruptive actions behind explicit flags.
