# Contributing to base_inst_kali (Offensive Installer Silicon Chip)

Thanks for your interest in improving this project. Before anything
else, read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) to understand the
design: "host" steps vs. "per operating system" steps, the three
execution environments (host / chroot / already-booted cloned system),
and why state is synced by hand between them.

## Reporting an issue

Open an [Issue](../../issues) including:

- Exact Mac model (Air/Pro, M1/M2) and amount of RAM.
- macOS version you started from before installing Asahi/Debian.
- Chosen distro (Kali or Parrot) and which step (`00`…`09`) the process
  failed on.
- Full error output, along with that specific step's log
  (`logs/step_<id>_<date>.log`), with any sensitive data (SSID,
  passwords, UUIDs if you're concerned) removed by hand. Use code
  blocks (```` ``` ````) to paste it.

## Proposing an improvement

1. Fork the repository.
2. Create a descriptive branch: `git checkout -b fix/external-partitioning`.
3. **Test your change on a real machine before opening the PR.** Given
   the risk involved in these scripts (partitioning, encryption, GRUB),
   changes without evidence of testing won't be accepted — at least on
   one specific Mac model, which you should state.
4. Open the Pull Request describing what problem it solves and on which
   Mac model you tested it. Also state whether it affects Kali, Parrot,
   or both.

## Testing changes without real hardware (logic only, not destructive steps)

Menu, state, i18n and partition-calculation logic can be tested without
touching real disks:

```bash
# Check syntax across the whole project
for f in install.sh lib/*.sh i18n/*.sh steps/*.sh; do bash -n "$f" || echo "ERROR: $f"; done

# Try the menu in text mode, without running any destructive step
rm -f /var/lib/base_inst_kali/state.conf   # clean state
printf '\n' | bash install.sh              # navigate with numbers + Enter
```

This **does not replace** the real-hardware testing required in point 3
above for any change touching steps `02` onward (partitioning, LUKS,
cloning, GRUB, repositories): those are only considered tested if
they've actually run on an Apple Silicon Mac with an external disk.

## Script style

- Bash with `set -euo pipefail` at the top of every script (inherited
  automatically when loading `lib/common.sh`).
- Comments that explain the *why*, not just the *what* — especially in
  the non-obvious parts (for example, why step 06 doesn't block the host
  menu, or why state is namespaced per operating system; see
  `docs/ARCHITECTURE.md`).
- Any destructive step (partitioning, formatting, deleting) must ask for
  explicit user confirmation before executing
  (`confirm_destructive` in `lib/common.sh`).
- Any command that can fail is wrapped in
  `run_cmd "description" command...` so it gets logged.
- With `pipefail` on, a `grep`/`awk` with no matches fails the line
  under `set -e`; add `|| true` when "empty" is a valid outcome and
  check it explicitly afterwards.
- Any name derived from the operating system (partition, VG, mapper,
  mountpoint) comes from `lib/os_catalog.sh`, never hardcoded.

## Adding a new operating system

See [docs/OPERATING_SYSTEMS.md](docs/OPERATING_SYSTEMS.md) — in
short, you only need to touch `lib/os_catalog.sh`, the files in
`i18n/`, and the `case` branches in `steps/08_repositories.sh` and
`steps/09_package_installation.sh`.

## Adding strings (i18n)

Strings live in `i18n/strings.en.sh`, the project's only language file,
as entries of an associative array `STRINGS[key]="text with %s"`. The
engine (`lib/i18n.sh`) is written to support more than one language, but
no language selector is currently exposed in `install.sh`; adding a
second language would mean creating `i18n/strings.<lang>.sh` with the
same keys and wiring a way to choose it.

## Pull requests

- One PR per logical change (don't mix, for example, a security fix
  with adding a new operating system).
- Update `CHANGELOG.md` under the `[Unreleased]` section.
- If the change affects documented behaviour, also update the
  corresponding file(s) in `docs/`, plus the root `README.md` and
  `CONTRIBUTING.md` if relevant.
- Describe how you tested it: on which Mac model (mandatory for changes
  to steps `02`-`09`), or just `bash -n` + menu navigation if the change
  doesn't touch destructive logic.
