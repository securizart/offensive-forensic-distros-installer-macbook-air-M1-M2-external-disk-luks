# forensics/ik4ln3/ — iK4lN3 toolset on Ubuntu 24.04 / Asahi (arm64)

There is no upstream APT repository for this toolset, so
there is no "conversion" path like Kali/Parrot (repo on top of Debian)
or REMnux (PPA + Salt states). What this addon does instead: install the
**subset of the forensic tool set that already exists in the Ubuntu archive
for arm64**, straight onto an Ubuntu clone, plus a small audited set of
pip-only tools in an isolated venv.

Offered as an **optional step-09 sub-option under Ubuntu**, exactly like
SIFT and REMnux.

## The two things this addon must never break

1. **GRUB.** The Mac boots `m1n1 → U-Boot → GRUB`, and `/boot` lives on
   the internal disk. GRUB is owned by steps 06/07 and the step-10 safety
   net. `guard.sh` therefore **holds every grub package** and **shims
   `update-grub`/`grub-install`/`grub-mkconfig` to no-ops** for the whole
   apt transaction, releasing them on exit. No grub package is ever
   installed, reinstalled or reconfigured by this addon.

2. **The Asahi kernel.** Asahi runs `linux-asahi`, not the stock
   `linux-image-generic`. `guard.sh` **holds the linux-asahi stack**,
   **refuses any stock-kernel / DKMS / bootloader package** via a
   forbidden-glob filter (defence in depth even if a name slips into a
   list), does a **dry-run before every install** and aborts a group if a
   forbidden package would be pulled as a dependency, and **never passes
   `--autoremove`** (which is what dragged out the kernel before).

`lime-forensics-dkms` is the one DKMS forensic tool worth having; it is
**not** in `packages-apt.txt` and only ever gets installed if you add an
explicit opt-in that first checks `linux-headers-$(uname -r)` for the
running Asahi kernel exists. Left as a deliberate manual step.

## Files

| File | Role |
|---|---|
| `guard.sh` | kernel + GRUB holds, grub-tool shims, forbidden-glob filter, `ik4ln3_apt_safe`. Sourced by both installers. |
| `10_install_ik4ln3_apt.sh` | installs `packages-apt.txt` + `packages-renamed.txt` (renamed → new name) under the guard. |
| `11_install_ik4ln3_pip.sh` | installs `packages-pip.txt` into `/opt/ik4ln3-venv`, linked into `/usr/local/bin`. Optional. |
| `packages-apt.txt` | 121 forensic tools, arm64-confirmed against noble, grouped by function. |
| `packages-renamed.txt` | jammy→noble name changes (e.g. `wireshark-qt`→`wireshark`). |
| `packages-pip.txt` | small audited set not in noble (`pytsk3`, libyal bindings). |
| `packages-skip.txt` | documentation only: what was dropped and why (X86 / PC / PPA / OLD / KERNEL). |

## Wiring into the main installer

1. Copy this directory to `forensics/ik4ln3/` in the repo and `chmod +x`
   the `.sh` files.
2. Paste `install_ik4ln3_arm64` from
   `snippets/common.sh.install_ik4ln3_arm64.sh` into `lib/common.sh`
   (right after `install_remnux_arm64`).
3. Paste block (A) from
   `snippets/09_package_installation.sh.ik4ln3_branch.sh` into the
   `ubuntu)` branch of `steps/09_package_installation.sh`, after the
   REMnux prompt.
4. Paste the strings from `snippets/strings.en.sh.ik4ln3.sh` into
   `i18n/strings.en.sh` (step 09 section).

No change to `lib/os_catalog.sh` is needed for option (A) — this is a
toolset on Ubuntu, not a new cloneable OS. Only add a catalogue entry if
you deliberately want a top-level `ik4ln3` target.

## Re-running / testing

Both scripts are idempotent and can run standalone (they self-shim the
`log_*`/`run_cmd` helpers when `lib/common.sh` isn't sourced), so you can
test the list-parsing and the guard on any arm64 Ubuntu box before a real
run. On real hardware, always snapshot first, per the project's
convention.

## Provenance

The arm64 availability of every package here was checked against the
Ubuntu 24.04 (noble) `binary-arm64` Packages indexes for
`main`/`universe`/`multiverse`, from a full package list of a jammy-based forensic live system. See `packages-skip.txt` for the excluded set and the
reason class for each.
