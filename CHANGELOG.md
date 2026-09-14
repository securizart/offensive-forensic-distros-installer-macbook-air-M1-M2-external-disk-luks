# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
All dates in YYYY-MM-DD.

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
