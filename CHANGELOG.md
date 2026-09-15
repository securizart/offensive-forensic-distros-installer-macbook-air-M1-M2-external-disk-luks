# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
All dates in YYYY-MM-DD.

## [1.3.0] — Parrot codename, desktop, and multi-OS GRUB merge
### Fixed
- **`steps/08_repositories.sh`/`steps/09_package_installation.sh` —
  `404 Not Found` on `deb.parrot.sh` for Parrot's repositories**: Parrot
  renamed its stable/rolling suite from the old `lts` codename to
  `echo` (Parrot OS 7.x, aligned with Debian "trixie", confirmed via
  ParrotSec's own mirrors documentation). Updated `sources.list`,
  `preferences.d/parrot.pref`, and every `-t lts` flag to `-t echo`.
  `echo-security` now points at `deb.parrot.sh/direct/parrot` per
  upstream's own recommendation, instead of a regular mirror.
- **`steps/09_package_installation.sh` — Parrot booted with no
  graphical desktop**: `parrot-core` and `parrot-tools-full` never
  pulled in a desktop environment — Parrot ships that separately as
  `parrot-interface` (which depends on one of
  `parrot-desktop-kde`/`-mate`/`-xfce`/... as apt alternatives). Since
  Parrot OS 7.0 the default DE is KDE Plasma (it was MATE up to 6.x),
  so `parrot-desktop-kde` and `parrot-interface` are now installed
  explicitly for the `parrot` target, pinning that alternative instead
  of leaving it to apt's dependency resolution.
- **`steps/07_grub_merge.sh` — a previous OS's native GRUB entry
  silently disappears when a THIRD operating system is added**: every
  OS's root partition lives inside its own LUKS container, but
  `os-prober` needs to mount an OS's root filesystem to identify it —
  it can't look inside one that's closed. Relying on `os-prober` to
  recover a previously-merged entry (as this step used to) only ever
  worked for the single most recently processed OS; adding a third one
  silently dropped whichever entry wasn't currently open. This step now
  loops over every OS in `OS_LIST` and merges each one's own
  `10_linux` GRUB fragment explicitly, mounting only that OS's
  (unencrypted) boot partition to read it — no LUKS passphrase needed,
  since `grub.cfg` lives on `boot`, not on the encrypted root.
  `STRINGS[step07_reboot_notice]` updated accordingly: it used to say
  "pick the second entry", which stops being correct once there are
  more than two operating systems in the merged menu; it now names the
  OS being processed and says to pick the LAST entry instead, since
  this step always merges the active OS in last.
### Added
- **`steps/07_grub_merge.sh` — step 06's progress no longer shows as
  permanently "pending" in the menu**: step 06 runs inside the chroot,
  where `STATE_DIR` resolves to the *external disk's own* filesystem,
  not the host's, so its "done" mark never reached the host's
  `state.conf` that the menu reads from (`NO_GATE_STEPS=("06")` in
  `install.sh` already accounted for this not blocking progress, but
  the display itself stayed wrong). Step 07 now reads that mark back
  from the disk's own copy of `state.conf` — still mounted at this
  point — and propagates it to the host, purely cosmetic, no behavior
  change.

## [1.2.0] — Project logo
### Added
- **Project logo** (`assets/logo.jpeg`), embedded at the top of
  `README.md`.
### Changed
- **README title**: dropped the `— internal codename \`base_inst_kali\``
  suffix. The codename is still documented inline where it's actually
  relevant (state directory, support-file paths, chroot copy target).
- **`docs/USAGE.md` / `README.md` — made explicit where/how to get the
  installer onto the machine**: added a basic checklist at the top of
  "Before you start" (boot into the matching Asahi base on the
  internal disk → copy the installer into a folder there → run it as
  root from that folder) and clarified in "Getting started"/"Starting
  the installer" that this all happens on the booted Asahi base
  itself, not on macOS or another machine. Also corrected the initial
  copy method to **USB drive** instead of `git clone`: a fresh Asahi
  base has no `git` installed and no network yet (until step 01a
  runs), so `git clone` isn't actually usable for getting the
  installer onto the machine the first time.
- **README — video 4 link added** (Kali conversion) and **disk-size
  guidance**: documented the ≈89.5 GB per-OS minimum on the external
  disk (from `steps/02_partitions.sh`'s 512 MB + 2 GB + 87 GB) and
  recommended at least a 500 GB external disk when installing more
  than one operating system on it, in `README.md` and
  `docs/USAGE.md`.
### Fixed
- **`steps/01a_network.sh` — wpa_supplicant.conf missing directives on
  Debian Trixie**: `wpa_passphrase` never emits `scan_ssid`/`key_mgmt`
  (confirmed on Trixie's wpasupplicant, though this is inherent to the
  tool everywhere, not version-specific); now inserted explicitly so
  hidden-SSID networks still connect.
- **`steps/01a_network.sh` — no interface actually brought up**: writing
  `wpa_supplicant.conf` alone did nothing on this ifupdown-based base
  (no NetworkManager). Now auto-detects the wireless interface (via
  `/sys/class/net/*/wireless`) and writes the matching
  `/etc/network/interfaces.d/<iface>` stanza, adding
  `source /etc/network/interfaces.d/*` to `/etc/network/interfaces` if
  missing. Bring-up now retries up to 5 times (5s apart), checking for
  an actual IPv4 address rather than trusting `ifup`'s exit code alone,
  and never aborts the main install flow if it can't confirm a
  connection.
- **Host step order**: `HOST_STEPS` in `install.sh` now runs
  `00 → 01a → 01` (was `00 → 01 → 01a`) — step 01 needs network for its
  own `apt update`/`apt install`. Updated the walkthrough numbering in
  `docs/USAGE.md` and the step table in `docs/ARCHITECTURE.md` to
  match. Added a warning in `steps/01a_network.sh` that the console
  keyboard layout is still the base image's default (normally US
  English) at this point, since keyboard/locale setup (step 01) hasn't
  run yet.
- **`steps/01_preparation.sh`**: replaced the deprecated `ntpdate`
  package with `ntpsec-ntpdate`.
- **`steps/05_chroot_prep.sh`**: added a 5s pause after `cryptsetup
  open` and before mounting, to let udev/LVM finish enumerating the
  volume group inside the just-opened LUKS container.
- **`steps/08_repositories.sh` — `apt-key: command not found` on Debian
  Trixie**: `apt-key` was fully removed in Debian 13 "Trixie" (deprecated
  since Debian 11/12). Kali's signing key now uses the same
  `gpg --dearmor` + `signed-by=` pattern already used for Parrot,
  instead of `apt-key add`.
- **`steps/07_grub_merge.sh` — duplicated `### END
  /etc/grub.d/30_os-prober ###` marker in the merged `grub.cfg`**:
  off-by-one in the final `sed` range (started at `c1` instead of
  `c1+1`), re-copying a line already included by the first `sed` call.
  Harmless to GRUB itself (a duplicated comment), but left the file
  structurally wrong.
- **`steps/08_repositories.sh` — stale "Debian GNU/Linux" boot menu
  title after conversion**: added `update-grub` at the end of the step
  (Kali/Parrot only) so this disk's own `grub.cfg` picks up the real
  distro name from `/etc/os-release` once `dist-upgrade` has replaced
  `base-files`. Note this only fixes this disk's own copy — re-run step
  07 from the host afterward to refresh the merged entry there too.
- **`steps/04_cloning.sh` — UUID resolution for fstab/crypttab**:
  switched from parsing default-format `blkid` output with a regex to
  `blkid -o export` (the `KEY=value`, unquoted format util-linux itself
  recommends for scripting), more robust across util-linux versions.
- **`steps/08_repositories.sh` — `dpkg: trying to overwrite '/usr/bin/rev',
  which is also in package util-linux` during Kali's `dist-upgrade`**:
  package-file moves between the Debian trixie and kali-rolling
  generations (`rev` moved from `util-linux` to `bsdextrautils`, per
  util-linux's own changelog) can trip dpkg's overwrite-conflict check
  on a jump this big. Added `-o Dpkg::Options::="--force-overwrite"` to
  the `dist-upgrade`/`--fix-broken install` calls for both Kali and
  Parrot — the standard, documented way through this class of
  cross-repo file-conflict.
- **`steps/08_repositories.sh` — `pkgProblemResolver::Resolve generated
  breaks` when repairing after the above**: `apt --fix-broken install`
  had no way to reach the kali-rolling/lts package versions needed to
  resolve the break, since `kali.pref`/`parrot.pref` pin those repos at
  priority 50 precisely so apt won't touch them without being asked.
  Tried `-t kali-rolling` first, but that can itself fail ("no es
  válido para APT::Default-Release") if the release/index state is
  stale mid-repair; switched to disabling preferences entirely for that
  one call (`-o Dir::Etc::Preferences=/dev/null -o
  Dir::Etc::PreferencesParts=/dev/null`) instead.
- **`steps/08_repositories.sh` — Kali's `dist-upgrade` removing
  `grub-efi-arm64`/`grub-efi-arm64-bin` in favor of `systemd-boot`**:
  kali-rolling's arm64 packaging can pull in `systemd-boot`/
  `shim-signed` and drop GRUB as part of a big `dist-upgrade`.
  `systemd-boot`'s own boot-entry creation then failed to configure on
  this Asahi/EFI setup, leaving `dpkg` broken either way, and this
  project's boot chain is entirely GRUB-based (steps 05-07 hand-build
  the merged `grub.cfg`). Added `/etc/apt/preferences.d/
  no-systemd-boot.pref` (`Pin-Priority: -1` for `systemd-boot*`,
  `shim-signed*`, `shim-unsigned`) before the `dist-upgrade` call so
  apt's solver can't pull them in or remove GRUB to begin with.
- **`steps/08_repositories.sh` — hibernate/resume warning during
  `update-initramfs`**: the swap volume on this external/clonable disk
  has no stable UUID/device-numbering guarantee across disks, and this
  project has no hibernate use case. Set `RESUME=none` explicitly in
  `/etc/initramfs-tools/conf.d/resume` at the start of the step (before
  any `apt update`/`dist-upgrade` triggers a rebuild), instead of
  leaving it to auto-detection.
- **`steps/08_repositories.sh` — cloned WiFi config pointed at the wrong
  interface name**: `wpa_supplicant.conf`/`interfaces.d` are cloned from
  the host in step 04 with the HOST kernel's interface name (e.g.
  `wlan0` on Debian/Asahi); the target OS's own kernel can name the
  same physical adapter differently (observed: `wld0` on Kali),
  intermittent connectivity followed (likely from some other fallback,
  not the stale config). Step 08 now re-detects the wireless interface
  on ITS OWN kernel first and rewrites the `interfaces.d` stanza under
  the current name before any `apt` operation.
- **`steps/09_package_installation.sh` — `kali-linux-arm` unsatisfiable
  dependencies**: that metapackage is Kali's own bundle for their ARM
  SBC images (Raspberry Pi, Rockchip, Allwinner boards), depending on
  SBC-specific firmware/tools (`rkflashtool`, `sunxi-tools`,
  `dphys-swapfile`, `firmware-realtek`, etc.) that don't apply to — and
  in several cases aren't installable on — a MacBook Air M1/M2. Removed
  from the metapackage install list; `kali-linux-default`,
  `kali-desktop-gnome` and `kali-linux-large` are unaffected and cover
  everything this project actually needs.
- **`steps/09_package_installation.sh` — WiFi interface name drifting
  between boots**: on top of the host→clone naming mismatch from step
  08 (see above), this same adapter's kernel-assigned name has been
  observed to change again between reboots on this hardware alone
  (`wld0` vs `wlp1s0f0` for the SAME physical MAC), so whatever step 08
  detected before its own reboot can already be stale by the time this
  step runs. Added a fresh re-detection at the start of step 09 that
  also drops any orphaned `interfaces.d` stanza left under a previous
  name, and pins the adapter's MAC to a fixed `wlan0` via a udev rule
  so future boots stop drifting.
- **`steps/07_grub_merge.sh` — reboot instructions were too vague**:
  both GRUB entries are still labeled "Debian GNU/Linux" at this point
  (conversion happens in step 08, not before), so "pick the
  corresponding entry" left room for picking the wrong one. Added an
  explicit notice to pick the SECOND entry, and step 07 now reboots
  automatically after a 5s pause (matching step 08's pattern) instead
  of ending and leaving the reboot to the user.
- **`steps/04_cloning.sh` and `steps/07_grub_merge.sh` — step wrongly
  shown as still pending after booting from the cloned disk**:
  `sync_state_to_mount` (which copies progress onto the external disk
  for the installer to pick up once booted from there) ran BEFORE
  `mark_os_step_done`, so the copy it left out was always missing that
  same step's own completion. Swapped the order in both steps.

## [1.1.0] — Ubuntu/Asahi 24.04 source-base workaround
### Added
- **Documented workaround for installing the Ubuntu/Asahi source base
  on Ubuntu 24.04 LTS**: the stable installer published on
  `ubuntuasahi.org` resolves its installable-release list from a JSON
  file that, as of this writing, doesn't list 24.04 LTS. Tracing the
  installer's own source turned up the maintainer's **beta** channel,
  whose release JSON does include 24.04 LTS (`curl -sL
  https://files3.tobhe.de/ubuntu/install-beta | sh`). Documented in
  `docs/OPERATING_SYSTEMS.md`, with the usual `curl | sh` caution
  (inspect before piping to `sh`) and a note that it only affects how
  the source base itself is installed — nothing in `lib/os_catalog.sh`
  or `steps/*.sh` changes.
- **Internal disk partitioning guidance for both source bases**: 90 GB
  combined (60 GB Ubuntu Desktop 24.04 + 30 GB minimal Debian),
  validated on real MacBook Air M1/M2 hardware. Added to
  `docs/OPERATING_SYSTEMS.md` and referenced from `docs/USAGE.md`.
- **README "Step-by-step video walkthroughs" table**: new first entry
  covering internal disk partition preparation, ahead of the Debian/
  Asahi and Ubuntu/Asahi install videos and the four conversion videos
  (Kali, Parrot, SIFT, REMnux).

## [1.0.0] - 2026-09-13
### Changed
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
