# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
All dates in YYYY-MM-DD.

## [1.5.0] - 2026-09-19
### Fixed
- **`apt` breaks system-wide after WineHQ registers i386** (part of
  REMnux/SIFT's own package set): `ports.ubuntu.com` (this base's arm64
  repo) never serves i386 packages, so once i386 is registered every
  subsequent `apt update`/`apt install` — not just REMnux's own —
  fails with 404s on i386 indices, including on a retry of the very
  same step. `lib/common.sh`'s new `ensure_apt_repos_sane()`, called
  at the very start of `steps/09_package_installation.sh` (idempotent,
  safe on every retry), restricts `ports.ubuntu.com` to `arch=arm64`
  and adds a working i386 mirror (`archive.ubuntu.com`/
  `security.ubuntu.com`) for whenever i386 packages are actually
  needed.
- **REMnux's own desktop theme/shortcuts landed in the wrong home
  directory** (`/home/iac` instead of `/home/remnux`), confirmed
  directly from a real `saltstack.log`: every `remnux-gnome-config-*`
  state wrote `user: iac`. Cause: `cast`'s own `.cast.yml` declares
  `remnux_user_template: "{{ .User }}"`, and `cast` resolves that
  `.User` via `$SUDO_USER` (whoever originally ran `sudo` at the very
  top of the install), not `$USER`/`$LOGNAME` — which is all the
  previous fix in this same release overrode. `install_remnux_arm64()`
  now also sets `SUDO_USER=remnux` alongside `HOME`/`USER`/`LOGNAME`
  for both `cast install` and `remnux-installer.sh`.
- **Invisible mouse pointer after installing REMnux, in every session**
  (not REMnux-specific to begin with — confirmed absent on plain
  Ubuntu and on SIFT): REMnux's own `remnux.config.display` state
  appends `MUTTER_DEBUG_FORCE_KMS_MODE=simple` to `/etc/environment`
  on Ubuntu 24.04 as a VMware/GNOME display accommodation, which breaks
  Mutter's hardware cursor plane on real Apple Silicon (Asahi) GPUs.
  `install_remnux_arm64()` strips that one line from `/etc/environment`
  right after REMnux finishes installing (leaves `NO_AT_BRIDGE=1`,
  the other line REMnux adds, untouched — harmless).
- **Stable external-disk identification**: `/dev/sdX` can be reassigned
  by the kernel between reboots (several USB/Thunderbolt disks on the
  same Mac). `lib/state.sh`'s new `get_target_disk()` resolves the disk
  from a stable identifier (`TARGET_DISK_ID`: `/dev/disk/by-id/`
  symlink, falling back to the GPT `PTUUID`) instead of trusting the
  cached `/dev/sdX`, self-healing `state.conf` if it moved. Wired into
  steps 00 (saves it), 02 (backfills it after creating the partition
  table), 03/04/05 (resolve through it).
- **Unreliable fixed `sleep` after `luksOpen`**: the LUKS mapper node
  and, more importantly, the LVM volume on top of it
  (`/dev/mapper/<vg>-root`) can take longer than a flat 5s to appear,
  depending on disk/boot timing — replaced with an active wait (poll,
  up to 30s) for the real device node in steps 03 (LUKS mapper) and
  04/05 (LVM `root` volume).
### Changed
- **REMnux install flow replaced**: `forensics/remnux/install.sh` +
  `cleanup.sh` + `verify.sh` (moved to `forensics/remnux/legacy/`,
  kept for reference) superseded by a single vendored
  `remnux-installer.sh` from the forensics satellite project (fuses
  those three plus an `extra`-tools phase and a `menu` phase that
  generates GNOME `.desktop` launchers for whatever actually
  installed — the old flow never generated any).
- `lib/common.sh`'s `install_remnux_arm64()` now runs `cast install
  remnux/salt-states` and `remnux-installer.sh --cleanup --verify
  --extra --partial --menu` as the `remnux` user (`sudo -u remnux -i
  --`), not as root: `remnux-installer.sh` reads `$HOME` throughout
  (salt-states, rustup, dotnet tools, and critically where `--menu`
  writes its `.desktop` files) — running it as root put all of that
  under `/root`, invisible to the `remnux` user's actual GNOME session.
  No longer calls `remnux-installer.sh`'s own `--base` phase: `cast
  install` already applies the full `remnux.dedicated` state on its
  own.
- `steps/09_package_installation.sh`'s `remnux)` branch grants the
  `remnux` account passwordless sudo (`/etc/sudoers.d/remnux-
  nopasswd`) — being in the `sudo` group alone still prompts for a
  password interactively, which the non-TTY install flow can't answer.

## [1.4.0] - 2026-09-17
### Fixed
- **`grub_set_var` helper (`lib/common.sh`) replaces the fragile
  per-setting `grep`/`sed` blocks in steps 07 and 10**: those only
  matched an already-uncommented line (`^NAME=`), so a stock, commented
  default (Debian/Ubuntu ship `GRUB_DISABLE_OS_PROBER` and others
  commented out) was never found, and a second, active line got
  appended after it instead — confusing, and apparently not reliably
  taking effect in practice. `grub_set_var` matches and replaces the
  existing line whether it's commented or not, in place.
- **Steps 07 and 10 keep `GRUB_DISABLE_OS_PROBER=true`** (Debian/
  Ubuntu's own default) rather than enabling it: briefly tried
  enabling it so os-prober could auto-detect the sibling base as a
  complement to step 07b's own cross-link script, but confirmed on
  real hardware that os-prober's guessed entry for a LUKS-rooted
  sibling doesn't pick up that base's real boot parameters
  (`root=`, `cryptdevice=`, initrd path) and fails to boot — unlike
  07b's `45_iac_cross_<base>` script, which loads the sibling's live
  `grub.cfg` via `configfile` and always gets it right. Reverted;
  `grub_set_var` explicitly re-asserts `true` in both steps now.
### Added
- **New step 10, GRUB menu safety net**, only for Ubuntu-sourced
  targets (`sift`, `remnux`): re-applies `GRUB_TIMEOUT_STYLE=menu`,
  `GRUB_TIMEOUT=10`, `GRUB_RECORDFAIL_TIMEOUT=10`, `GRUB_DEFAULT=0` and
  clears any saved GRUB default again, right after step 09. Nothing
  between step 07 and here is supposed to touch `/etc/default/grub` or
  GRUB's saved-entry state, but step 09 installs a large number of
  packages and a kernel-related trigger firing an automatic
  `update-grub`/`grub-install` somewhere in that process is a
  plausible way for step 07's settings to end up reverted. Cheap and
  idempotent to redo either way. Skips immediately (no-op) for
  `kali`/`parrot`.
### Fixed
- **Step 09's `cast install` (SIFT) no longer aborts the whole step on
  a partial failure**: a handful of failed salt states out of hundreds
  (expected on arm64 per SIFT's own docs — some packages are amd64-only)
  still makes `cast` exit non-zero, which fired the script's global
  `ERR` trap since the call wasn't inside a conditional — aborting step
  09 immediately and skipping `unhold_packages`, leaving the
  kernel/GPU-userspace hold in place indefinitely even though the bulk
  of the install (840/846 states in one real run) had actually
  succeeded. Now checked in an `if`, so a partial failure just logs a
  warning and still releases the hold and finishes the step normally.
- **Step 07's merge is now persistent**: instead of one-time splicing
  the target's native GRUB entries directly into the host's
  `grub.cfg`, it bakes them into a small script at
  `/etc/grub.d/46_iac_merged_<target>`. Found on real hardware that
  the one-time splice silently disappeared the moment anything else
  regenerated `grub.cfg` — specifically, step 07b's own `update-grub`
  on the *sibling* base wiped out previously-merged Kali/Parrot
  entries there, since they'd never been captured in `/etc/grub.d/`
  at all. Every target already processed now keeps showing up on any
  future `update-grub`, on either base, without needing that target's
  disk mounted or step 07 re-run for it.
- **Step 01's keyboard/locale setup no longer relies on
  `dpkg-reconfigure`'s own interactive dialog**: `debconf`'s Dialog
  frontend checks whether stdout is a real terminal, and
  `init_step_log`'s per-step log capture (`exec > >(tee ...)`) means
  it isn't — so it was silently falling back to noninteractive and
  keeping Ubuntu/Asahi's own "us" default without ever actually
  asking, even though the step appeared to pause for several minutes.
  `whiptail` itself is unaffected (it talks to `/dev/tty` directly),
  so step 01 now asks for the keyboard layout and locale with our own
  `ui_inputbox` and writes `/etc/default/keyboard`/`/etc/default/locale`
  directly, for both bases.
- **`07b`'s partition scan now handles a separate `/boot` partition
  for the sibling base**: it required `grub.cfg` to live directly
  inside the candidate root partition, so a Debian/Asahi (or
  Ubuntu/Asahi) install with root and boot as two different
  partitions — confirmed on real hardware via `blkid`/`lsblk` — was
  never found even though `/etc/os-release` matched correctly. Now
  reads the candidate root's own `/etc/fstab` for where `/boot` is
  mounted when it isn't co-located, and mounts that partition too
  (at `<root>/boot`) before touching `grub.cfg`.
- **Step 01 now reconfigures locale/keyboard for Ubuntu/Asahi too**,
  interactively, instead of skipping it: Ubuntu/Asahi's own image
  ships with `XKBLAYOUT="us"` and an English locale by default, and
  relying on the user creating `preparation/keyboard`/
  `preparation/locale` on the host kept not happening in practice.
  Fixing it at the source (the host, before step 04 clones `/`) means
  the clone inherits the right layout/language automatically.
- **Step 07 now also forces `GRUB_DEFAULT=0` and clears any saved
  GRUB default (`grub-editenv ... unset saved_entry`)**: found on real
  hardware that manually picking a merged external entry once (to
  test that it boots) gets remembered under `GRUB_DEFAULT=saved`
  (Ubuntu's common setting) and silently reused on every later
  automatic reboot — including steps 02/03's own unattended reboots —
  landing back on the external clone instead of the internal host on
  the next run, and masking both the "menu doesn't wait" and 07b's
  "wrong root device" symptoms as if they were separate bugs.
- **Step 07's merge could produce an unparseable `grub.cfg`**, dropping
  GRUB to its `grub>` command prompt instead of showing the menu at
  all: the "widest span" fix for multiple `BEGIN`/`END
  /etc/grub.d/10_linux` marker pairs (first `BEGIN` to last `END`)
  could splice in whatever sits between two separate pairs, which
  isn't guaranteed to be valid GRUB script on its own. Now uses only
  the first complete pair — always a self-contained unit exactly as
  `grub-mkconfig` generated it — and logs a warning that the rest is
  ignored, instead of merging it in.
### Added
- **Step 06 also applies `/base_inst_kali/preparation/locale` inside
  the chroot** (system-wide `LANG`, distinct from the keyboard layout):
  runs `locale-gen`/`update-locale` and installs the matching
  `language-pack-gnome-<code>` so the GNOME UI itself is translated,
  not just `LC_*` categories. Same file-based mechanism as
  `preparation/keyboard`; never ran on Ubuntu/Asahi before since step
  01 skips it there.
- **Step 07 also forces `GRUB_RECORDFAIL_TIMEOUT=10`**: found on real
  hardware that `GRUB_TIMEOUT_STYLE=menu`/`GRUB_TIMEOUT=10` alone
  weren't enough — Ubuntu's own `/etc/grub.d/00_header` checks GRUB's
  `recordfail` variable at boot and forces `timeout=0` anyway on a
  successful previous boot, unless `GRUB_RECORDFAIL_TIMEOUT` is also
  set. Without it the menu never actually waited.
- **`hold_graphics_kernel_packages`/`unhold_packages` (`lib/common.sh`)**,
  used by step 09 around both `cast install teamdfir/sift-saltstack`
  (target `sift`) and `install_remnux_arm64` (target `remnux`): found
  on real hardware that SIFT's and REMnux's own SaltStack provisioning
  add their own apt repositories and can silently upgrade
  already-installed packages (mesa, gnome-shell) to versions expecting
  a newer kernel than the one left in place, breaking the graphical
  session on reboot — the same class of mismatch as the step 08
  `full-upgrade` issue below, but triggered from inside third-party
  provisioning this time, not from any upgrade command this installer
  runs itself. Holds only the kernel/GPU-userspace family (kernel
  image/headers/modules, `ubuntu-asahi`, Mesa, the display
  manager/compositor, Xorg/Wayland) — an earlier version held every
  installed package, which broke SIFT's own dependency resolution
  instead (`held broken packages`, 140/846 salt states failed). See
  docs/TROUBLESHOOTING.md.
- **`sift` and `remnux` as separate catalog targets**, each with its
  own partitions, LVM volume group (`vgsift`, `vgremnux`) and LUKS
  container, so both can be installed side by side on the same
  external disk as fully independent, separately bootable systems —
  was a real limitation reported after testing, since SIFT and REMnux
  used to be `confirm_yes_no` sub-options of a single `ubuntu` install
  and could only ever land in the same volume group. There is
  deliberately no plain "ubuntu" target: this installer only cares
  about Ubuntu as a forensics base, so `sift`/`remnux` are the only two
  Ubuntu-sourced ids in the catalogue (a brief intermediate design kept
  `ubuntu`/`ubuntu_sift`/`ubuntu_remnux` as three ids — dropped in favor
  of this simpler two-id naming before release). Step 09 installs
  SIFT/REMnux unconditionally for their respective id (choosing the
  target already is the decision, no separate prompt); step 08 treats
  both identically (no repos, no upgrade). See
  docs/OPERATING_SYSTEMS.md for the full model.
- **`remnux`/`malware` demo account**: step 09's Ubuntu branch now
  creates a `remnux` user (sudo group) with REMnux's own well-known
  public demo password `malware` right before installing it — matching
  REMnux's upstream convention, since the vendored scripts themselves
  don't create this account. Documented with an explicit security
  warning (README.md, `forensics/README.md`) since this is a public
  repository.
- **New optional step `07b_grub_cross_merge.sh`**: after merging an OS's
  native GRUB entry into its own host's `grub.cfg` (step 07), this lets
  you also drop a small `/etc/grub.d/` chainload script onto the
  *sibling* internal base (Debian/Asahi <-> Ubuntu/Asahi), so its boot
  menu offers an entry that `configfile`-loads this host's live
  `grub.cfg`. No menuentry text is duplicated, so it survives future
  `update-grub` runs (new kernels, new OS merges) on either side without
  re-syncing anything by hand. Marked as a `NO_GATE_STEPS` entry: it
  never blocks progression to step 08, and can be run at any point
  after 07.
- Documented, in `docs/ARCHITECTURE.md`, why the internal disk ends up
  with **two independent GRUB installations** (one per internal base),
  not a single unified menu — and how `07b` bridges them without
  duplicating boot logic.
### Investigated
- Reviewed the SIFT Workstation install path (step 09, Ubuntu target):
  confirmed `cryptodisk`/`luks`(1)/`lvm` GRUB modules ship by default on
  a stock Ubuntu/Asahi install, which is what makes `07b`'s chainload
  entries actually bootable without installing any extra GRUB module on
  either internal base.
### Changed
- **Step 08's Ubuntu branch no longer runs any upgrade at all**
  (reverting the earlier kernel/`ubuntu-asahi` hold approach): on real
  hardware, letting everything else fully upgrade while holding back
  the kernel desynced it from its GPU userspace stack
  (mesa-vulkan-drivers, gnome-shell, xorg — all version-coupled to the
  kernel on Ubuntu/Asahi), breaking the graphical session on reboot
  (console only, no GDM/GNOME). The clone already has a self-consistent
  kernel+userspace combination from the source boot; step 08 now just
  runs `apt update` and leaves packages untouched, same philosophy as
  step 01. Any system upgrade is left to the user, and should be a full
  one (kernel included) if attempted, not a partial one.
- **Step 07 now forces `GRUB_TIMEOUT_STYLE=menu` and `GRUB_TIMEOUT=10`**
  in `/etc/default/grub`: Ubuntu ships with the menu hidden and a 0s
  timeout by default, which on real hardware meant the merged external
  entry was never actually reachable — GRUB just boots straight through
  with no way to pick it. Overrides whatever `preparation/grub` (if
  used) set too, since the whole point of merging in an entry is being
  able to select it.
- **Step 03 now resets steps 04-09's recorded status for the target OS**
  before reformatting: found on real hardware that reformatting/
  recloning left stale "done" flags from a previous attempt, letting
  the menu jump straight to 07b/08/09 without 04-07 ever touching the
  fresh clone.
- **Fixed physical-disk resolution (`resolve_physical_disk`, new in
  `lib/common.sh`) for roots on LVM/LUKS**: a single `lsblk -no PKNAME`
  lookup only returns the immediate parent, which for an LVM root is
  the underlying PV/crypt device, not the physical disk — this broke
  `07b`'s internal-disk detection (and silently no-opped step 00's
  internal-disk exclusion) whenever the booted system's own root uses
  LVM. Now walks the full parent chain. `07b` also now detects and
  refuses to run if it resolves to the external `TARGET_DISK` itself
  (a sign of being booted from the external clone, not the internal
  host).
- **Step 06 now also applies `/base_inst_kali/preparation/keyboard`
  inside the chroot**, before the first `update-initramfs`: the LUKS
  passphrase prompt actually seen at boot comes from the initramfs's
  own cryptsetup hook (crypttab-driven), not GRUB — `/boot` itself
  isn't encrypted, so GRUB never needs to decrypt anything and its own
  keymap (step 07's fix) never actually applied to this prompt. This
  chroot-side copy is what actually fixes it.
- **`01a` no longer listed in the menu when booted into Ubuntu/Asahi**:
  it always self-skips there (see its own note), so showing it added
  nothing.
- **Step 07 now also applies `/base_inst_kali/preparation/keyboard`**
  (if present) before deriving the layout for the GRUB keymap below,
  and always regenerates that keymap script on every run instead of
  only when absent: Ubuntu/Asahi's own install can leave
  `/etc/default/keyboard` at `XKBLAYOUT="us"`, and step 01 deliberately
  skips this file on Ubuntu/Asahi, so this was the first — and, being
  skip-if-exists before, the only — point where it could take effect,
  even after fixing the file.
- **Step 07 now installs a GRUB keymap for the host**, compiled from
  its own `/etc/default/keyboard` (`XKBLAYOUT`) via `grub-kbdcomp`, as
  a small `/etc/grub.d/05_iac_keymap` script: GRUB's own text prompts
  — including the LUKS passphrase asked by `cryptomount` for the
  merged entry — default to a raw US-like layout otherwise, regardless
  of the OS's own configured layout, which made typing a non-US
  passphrase unreliable. Skipped with a warning if `XKBLAYOUT` can't be
  resolved or `grub-kbdcomp` fails; existing US behavior is unaffected.
- **Step 05 also pauses 5 seconds right after mounting root**, before
  mounting boot/efi and the pseudo-filesystems (sysfs, efivarfs, proc,
  dev binds) on top of it: those were failing intermittently on real
  hardware with no pause in between.
- **Steps 03, 04 and 05 now pause 5 seconds right after `cryptsetup
  open` (luksOpen), before touching the resulting device-mapper node**:
  on real hardware, mounting or running `pvcreate`/`mkfs` on
  `/dev/mapper/<cryptname>` immediately after opening it could race
  udev, which hasn't finished settling the new node yet.
- **`07b_grub_cross_merge.sh`'s partition scan fixed**: `lsblk -no NAME`
  defaults to tree-formatted output (`├─nvme0n1p1`), which broke every
  `/dev/${part}` device path built from it and made the sibling-base
  search silently skip every partition ("Could not find a debian/ubuntu
  root partition..." even when one existed). Now uses `-lno NAME`
  (list mode) for plain names.
- **Step 08's Ubuntu branch also holds `ubuntu-asahi` itself** before
  the full-upgrade, not just the `linux-*` kernel packages: on real
  hardware, holding only the kernel packages wasn't enough, because
  `ubuntu-asahi`'s own upgrade directly depends on a specific new
  kernel version and pulled it in anyway, hitting the same Launchpad
  #2148348 bug the earlier hold was meant to avoid.
- **Step 07 no longer breaks when the cloned system's `grub.cfg` has
  more than one `BEGIN`/`END /etc/grub.d/10_linux` marker pair**, seen
  on real hardware (Ubuntu target): `awk` returned multiple line
  numbers, which broke the `a2=$((a1+1))` arithmetic outright
  (`syntax error in expression`, then `a2: unbound variable`). Now
  takes the first `BEGIN` and the last `END` found, covering every
  10_linux block regardless of how many there are, and logs a warning
  if more than one pair was found instead of failing silently on the
  wrong assumption.
- **Step 03 now checks that the target EFI/boot/root partitions aren't
  currently mounted before formatting them**, and unmounts them first
  if they are (e.g. a previous partial run, or the desktop's automount
  service picking up a partition it recognizes on the external disk).
  It also detects and tears down a leftover LUKS mapping (with its LVs)
  from a previous run for the same OS, so `luksFormat` doesn't fail
  with "device is mounted/busy".
- **Steps 01 and 01a skip locale/keyboard configuration and WiFi setup
  entirely when booted into Ubuntu/Asahi**: that base already has both
  configured from its own separate install. Debian/Asahi's behavior is
  unchanged. `01a` now exits immediately (marked done) on Ubuntu/Asahi
  without prompting for any WiFi credentials.
- **Step 08's Ubuntu branch now holds the currently-installed kernel
  package(s) around its `apt full-upgrade -y`**, releasing them again
  right after: same Launchpad #2148348 exposure as step 01 (this runs
  on the same Ubuntu/noble clone), but here the upgrade itself is the
  point of the step, so instead of skipping it we just pin the kernel
  in place so apt can't pull a newer, possibly-broken one while still
  upgrading everything else. Kali/Parrot's `dist-upgrade` in the same
  file are untouched — different kernel packaging family, no evidence
  they're affected by this bug.
- **Step 01 no longer runs a blanket `apt upgrade -y` when booted into
  Ubuntu/Asahi**: only installs the specific packages this installer
  needs there. Found on real hardware: the unconditional full-system
  upgrade pulled in a kernel package hit by a confirmed, currently open
  Ubuntu bug (Launchpad #2148348 — 7.0.x kernel maintainer scripts call
  `run-parts` with two directories at once, which fails with
  `run-parts: missing operand` on noble), leaving dpkg half-configured.
  Documented the symptom and recovery steps in
  `docs/TROUBLESHOOTING.md`. Debian/Asahi's behavior is unchanged.
- **Step 01 (base preparation) now skips the root password reset and
  the `iac` user creation/password prompt when booted into Ubuntu/Asahi**:
  that base already has its own login from its own separate install, so
  re-prompting for both was redundant. Debian/Asahi's behavior is
  unchanged. Package installation, locale/keyboard configuration still
  run for both bases.
- **Project renamed and moved to its definitive repository**:
  `offensive-forensic-distros-installer-macbook-air-M1-M2-external-disk-luks`,
  merging `offensive-installer-silicon-chip` and the vendored
  `forensics/` content into a single final repo. The internal codename
  `base_inst_kali` (state directory, support-file paths, chroot copy
  target) is kept as-is throughout the scripts — only the repository
  name and top-level branding changed, not the runtime path convention.
### Added
- **Documentation clarified on needing both internal bases** to combine
  offensive distros and forensic tools on the same external disk: the
  README's prerequisite section and `docs/USAGE.md` now spell out that
  Debian/Asahi (for Kali/Parrot) and Ubuntu/Asahi (for the Ubuntu target,
  where SIFT/REMnux hang off) are two separate internal installs with no
  conversion between them, and that host steps 00/01/01a need repeating
  once per base since each is a separate filesystem with its own state.
- **Automatic source-base detection and menu filtering**: step 00 now
  resolves the currently booted base (`detect_booted_base` in
  `lib/os_catalog.sh`) and saves it as `BOOTED_BASE`. The "Operating
  systems" menu (`manage_os` in `install.sh`) uses `os_targets_for_base`
  to only list the operating systems that actually target that base
  (Kali/Parrot when booted into Debian/Asahi, Ubuntu when booted into
  Ubuntu/Asahi), instead of listing every catalogued OS unconditionally.
  `verify_source_base` is kept as a blocking safety net at steps 02-04
  in case the booted system changes in between.
- **REMnux offered as an optional step 09 sub-option under Ubuntu**
  (same pattern as SIFT): new `forensics/` directory vendoring the
  `remnux/install.sh`, `cleanup.sh`, `verify.sh` and `exclude-list.txt`
  scripts as-is from the `forensic-distros-silicon-external-disk`
  satellite project, which owns their actual logic and validation.
  `lib/common.sh`'s new `install_remnux_arm64` function only
  orchestrates them (ensures `git`/`cast`, runs `cast install
  remnux/salt-states`, then the three vendored scripts in sequence).
  See `forensics/README.md` for how to pull in newer approved versions.
### Changed
- **All Spanish removed from the project, ahead of merging with the
  `forensic-distros-silicon-external-disk` satellite repository.** The
  installer is now English-only end to end:
  - Dropped the whole dual-language layer: `i18n/strings.es.sh` deleted,
    `docs/es/` deleted, root `README.md`/`CONTRIBUTING.md` replaced by
    their former `.en.md` versions, and the in-menu language switch
    (`LANG`/`switch_language`, the `menu_option_lang`/
    `menu_choose_lang_prompt`/`menu_lang_set`/`menu_current_lang`/
    `lang_name` keys) removed from `install.sh` and
    `i18n/strings.en.sh`. `lib/i18n.sh` simplified to load English by
    default, with no more `es` fallback/locale sniffing. The engine
    itself stays generic (`i18n_load <lang>`), so a language could be
    reintroduced later.
  - All `steps/*.sh` scripts renamed to English: `00_check_prerreq.sh` →
    `00_check_prereq.sh`, `01_preparacion.sh` → `01_preparation.sh`,
    `02_particiones.sh` → `02_partitions.sh`, `03_formateo.sh` →
    `03_formatting.sh`, `04_clonado.sh` → `04_cloning.sh`,
    `06_grub_finiquitar.sh` → `06_grub_finalize.sh`,
    `07_fusion_grub.sh` → `07_grub_merge.sh`, `08_repositorios.sh` →
    `08_repositories.sh`, `09_instalacion_paquetes.sh` →
    `09_package_installation.sh`. `install.sh`'s `STEP_FILE` map and
    every cross-reference in the docs updated accordingly.
  - Support-file path renamed: `/base_inst_kali/preparacion/` →
    `/base_inst_kali/preparation/`.
  - Per-step log filenames renamed: `logs/paso_<id>_<date>.log` →
    `logs/step_<id>_<date>.log` (`lib/common.sh`, `init_step_log`).
  - Spanish variable names translated: `nombre_wifi`/`paso_wifi` →
    `wifi_ssid`/`wifi_password` in `steps/01a_network.sh`.
  - `lib/ui.sh`'s `ui_yesno` text fallback no longer accepts "sí"/"si" as
    an affirmative answer, only "y"/"yes".
  - Every Spanish code comment and `log_*`/`echo` message across
    `lib/*.sh` and `steps/*.sh` translated to English. User-facing
    strings routed through `t()` were already in English via
    `i18n/strings.en.sh` and are unaffected.
  - **Not touched, on purpose**: the target system's own locale and
    keyboard configuration. `steps/01_preparation.sh` still runs
    `dpkg-reconfigure locales`/`keyboard-configuration` interactively,
    so whoever installs Kali/Parrot/Ubuntu can still choose a Spanish
    keyboard layout or `es_ES` locale for the **installed** system; only
    the installer's own interface (menus, logs, prompts) is English-only
    now.

## [0.4.0] — Ubuntu as a third operating system (no conversion)
### Changed
- REMnux's verdict softened from "discarded" to "in doubt, open
  investigation": a direct comparison of its `.sls` (SaltStack) files
  against SIFT's revealed that REMnux's core mechanism (repo via a
  Launchpad PPA, an already arm64-aware `cast.sls`) doesn't have the
  same structural bug SIFT had before its official arm64 support, though
  a different category of risk remains (Wine-dependent tools,
  amd64-only third-party binaries such as PolarProxy). Added to both
  READMEs' roadmap as planned investigation for a future version (`cast
  install --mode=addon` with a Wine-free subset). Documented in detail
  in `docs/OPERATING_SYSTEMS.md`.
### Added
- `ubuntu` added to `SUPPORTED_OS` (`lib/os_catalog.sh`): unlike
  Kali/Parrot, it isn't converted, it's **cloned as-is** from a genuine,
  separate Ubuntu/Asahi installation on the internal disk.
- New `OS_SOURCE_BASE` mapping and **blocking**
  `verify_source_base "$TARGET_OS"` function: checks, by reading
  `/etc/os-release`, that the booted system matches the base the active
  OS needs (Debian/Asahi for Kali/Parrot, Ubuntu/Asahi for Ubuntu)
  before partitioning (02), formatting (03) and cloning (04).
- `steps/08_repositories.sh`, `ubuntu)` branch: no repositories to add,
  just `apt update && apt full-upgrade`.
- `steps/09_package_installation.sh`, `ubuntu)` branch: idempotent
  install of `ubuntu-desktop`, and an **optional** install (explicit
  confirmation) of **SIFT Workstation (SANS)** — official arm64 support
  confirmed on Ubuntu 22.04/24.04 directly by the
  `teamdfir/sift-saltstack` project.
- `lib/common.sh`, `install_cast_arm64` function: downloads and installs
  the latest version of `cast` (ekristen/cast, the SIFT installer) for
  arm64, resolving the version without hardcoding it and without using
  the GitHub API (rate limit), instead following the
  `.../releases/latest` redirect. Tested end to end (real download
  verified, `.deb` architecture confirmed).
- Documentation (`docs/OPERATING_SYSTEMS.md`, `docs/ARCHITECTURE.md`,
  `docs/TROUBLESHOOTING.md`): final verdict on the three forensic tools
  investigated for Ubuntu — SIFT integrated (official arm64), REMnux
  discarded (no ARM support per its own documentation, confirmed live),
  CAINE discarded (not a convertible-repository model). Also added the
  general method for checking arm64 package availability
  (`apt-cache policy`, `rmadison`, architecture searches on
  Debian/Ubuntu/Launchpad).
- Source-base requirement updated in both READMEs and in the usage
  guide: it now depends on the target system (Debian/Asahi for
  Kali/Parrot, Ubuntu/Asahi for Ubuntu).
### Changed
- Both READMEs' roadmap updated: Ubuntu moves from "planned" to
  "implemented".

## [0.3.0] — multi-OS support (Parrot OS)
### Added
- `lib/os_catalog.sh`: catalogue of supported operating systems
  (`kali`, `parrot`), with automatic derivation of partition labels, LVM
  group, LUKS mapper name and mount point per OS.
- Support for **Parrot OS** as a second installable operating system on
  the same external disk (official `deb.parrot.sh` repository,
  `parrot-core`/`parrot-tools-full` metapackages).
- Progress namespaced per operating system (`os_state_*`,
  `mark_os_step_done`, `os_step_status`), so Kali and Parrot keep
  independent step counters.
- Automatic computation of free partition numbers per OS, so a second
  operating system doesn't overwrite the first one's partitions on the
  same disk.
- Main menu split into "host" steps (00, 01, 01a — once) and "per
  operating system" steps (02-09 — repeatable), with an "active
  operating system" selector.
- Expanded bilingual documentation at the time:
  `docs/{es,en}/SISTEMAS_OPERATIVOS.md`/`OPERATING_SYSTEMS.md`, and the
  rest of the documents updated to reflect the multi-OS design.
- Repository files: `CHANGELOG.md`, `CONTRIBUTING.md`, `LICENSE`.
### Changed
- Creating the `iac` user and the `sudoers` file moved from the old
  step 02 (partitioning) to step 01 (host preparation), since it's a
  one-time action, not a per-OS one.
- `steps/02_particiones.sh` through `07_fusion_grub.sh` (original
  Spanish names at the time) rewritten to operate on the active
  operating system (`$TARGET_OS`), instead of a disk with fixed
  `1/2/3` partitioning.
- `09_instalacion_kali.sh` renamed to `09_instalacion_paquetes.sh`
  (original Spanish name at the time) and generalized per OS.

## [0.2.0] — whiptail
### Added
- `lib/ui.sh`: UI layer (`ui_msgbox`, `ui_yesno`, `ui_inputbox`,
  `ui_passwordbox`, `ui_menu`) using `whiptail` when available, with a
  plain-text (`read`/`echo`) fallback otherwise.
- `whiptail` added to step 01's base package list.
### Changed
- Main menu, language selector, target disk selection (step 00) and
  WiFi credentials (step 01a) migrated to the UI layer.
### Fixed
- Bug in `ui_menu`'s text fallback: the header/listing leaked into the
  value returned by `$(...)`, since visual output (stderr) wasn't
  separated from the return value (stdout).

## [0.1.0] — initial framework version
### Added
- `install.sh`: main menu with persistent progress
  (`✓ done`/`▶ next`/`locked`/`✖ failed, retry`).
- `lib/common.sh`, `lib/i18n.sh`, `lib/state.sh`: logging core, error
  handling (`set -e -u -o pipefail` + `trap ERR`), i18n (Spanish/English
  at the time) and state persistence across reboots.
- 1:1 refactor of the 10 original scripts
  (`0_preparacion.sh` … `8_red_e_instala.sh`) into `steps/00`…`09`, with
  per-step logging and explicit destructive confirmations.
- New `00_check_prerreq.sh` step (original name at the time): arm64
  architecture check, a warning if the Asahi/Debian base isn't detected,
  and validated selection of the external disk (avoids accidentally
  picking the internal NVMe).
- Security fix: the WiFi password is no longer stored outside `/etc`,
  and the credentials file ends up with `600` permissions.
