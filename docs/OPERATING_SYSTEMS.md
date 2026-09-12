# Several operating systems on the same disk — base_inst_kali

## Currently supported systems

| Id | Name | Method | Required source base | arm64 support |
|---|---|---|---|---|
| `kali` | Kali Linux | Conversion: adds repos on top of the cloned base | Debian/Asahi | Official and mature |
| `parrot` | Parrot OS | Conversion: adds repos on top of the cloned base | Debian/Asahi | Official, but less tested than Kali on Apple Silicon |
| `ubuntu` | Ubuntu | Cloned as-is, no conversion | Ubuntu/Asahi | It's the native base; doesn't apply |

Kali and Parrot are Debian-based distributions with their own `arm64`
repository: they're obtained by **converting** an already-cloned
Debian/Asahi base, adding their repository and signing key on top
(steps 08-09). Ubuntu is different: there's no meaningful "conversion"
(neither Kali nor Parrot are officially Ubuntu-based, and Ubuntu is
already Ubuntu), so it's **cloned as-is** from a genuine, separate
**Ubuntu/Asahi** installation on the internal disk (see
[Ubuntu Asahi](https://ubuntuasahi.org/), the community project that
natively installs Ubuntu Desktop 24.04/24.10 on Apple Silicon).

### Source base verification and automatic menu filtering

Since Kali/Parrot need Debian/Asahi booted and Ubuntu needs Ubuntu/Asahi
booted, step 00 resolves and saves the currently booted base
(`BOOTED_BASE` in the state, via `detect_booted_base` in
`lib/os_catalog.sh`). The "Operating systems" menu (`manage_os` in
`install.sh`) uses it to only list the OSes that actually target that
base (`os_targets_for_base`) — booted into Debian/Asahi, you only see
Kali/Parrot; booted into Ubuntu/Asahi, only Ubuntu. If the base can't be
resolved, every catalogued OS is listed, unfiltered.

This is a **convenience filter**, not the only safety net: since you
could in theory reboot into a different base between picking the active
OS and reaching step 02, `verify_source_base` still runs — and still
blocks — at the start of steps 02, 03 and 04, reading `ID=` from
`/etc/os-release` again at that point. If it doesn't match, it stops
with clear instructions on which internal boot entry to pick — see
`docs/ARCHITECTURE.md` for the full technical detail.

> **Note on Parrot OS**: its arm64 support is real (official repository
> with `arch=arm64`), but less mature and with fewer users testing it on
> Apple Silicon than Kali. If some `parrot-tools-full` metapackage fails
> to install, check the log (`logs/step_09_*.log`) and install the
> individual tools you need afterwards instead of blocking the whole
> install over one problematic package.

## Ubuntu: what steps 08-09 do

- **Step 08**: no repositories to add (it's already genuine Ubuntu) —
  just `apt update && apt full-upgrade`, to keep the clone current.
- **Step 09**:
  1. Installs `ubuntu-desktop` **idempotently** (checks with `dpkg -l`
     whether it's already there and skips if so — the Ubuntu Asahi image
     usually already ships with a desktop).
  2. **Optionally** offers (`confirm_yes_no`, never automatic) to
     install **SIFT Workstation** (SANS), the forensic toolkit — see the
     full verdict below.
  3. **Optionally** offers, also via explicit confirmation, to install
     **REMnux**, the malware-analysis toolkit — see the REMnux verdict
     below and `forensics/README.md` for where its scripts come from.

## Forensic tools investigated for Ubuntu: verdict

Three candidate forensic distributions/toolkits were evaluated for
running on top of the cloned Ubuntu. Result:

### ✅ SIFT Workstation (SANS) — integrated as an option in step 09

The project itself (`teamdfir/sift-saltstack`) states in its live,
official README: **support for Ubuntu 22.04 (Jammy) and 24.04
(Noble)**, **both `amd64` and `arm64`**, with a known caveat: *"a
handful of packages are amd64-only and are skipped on arm64"*. This
exactly matches the version Ubuntu Asahi uses (24.04), and it's
**official arm64 support from the maintaining team itself**, not a
community patch.

It's installed with `cast` (the official installer, successor to
`sift-cli`), whose arm64 binary is resolved and downloaded
automatically without hardcoding any version (`lib/common.sh`,
`install_cast_arm64` function — follows the `.../releases/latest`
redirect instead of the GitHub API, which has an easily-exhausted
rate limit).

*Historical note*: a community project,
[`jonathanlooi/sift-on-arm`](https://github.com/jonathanlooi/sift-on-arm),
documents how to manually patch SIFT for arm64 — but it's written
against **Ubuntu 22.04**, an earlier version than what the project now
officially supports (22.04 and 24.04, with arm64 already integrated).
It has been superseded by current official support; there's no need to
follow that guide anymore.

### 🟡 REMnux — in doubt, not fully discarded (open investigation), now offered as an option under Ubuntu

REMnux's official documentation (`docs.remnux.org`) still states,
repeatedly and recently updated across several pages: *"REMnux is
currently based on an x86/amd64 version of Ubuntu, and won't run on ARM
processors such as Apple's M-series chips."* Its base is also Ubuntu
24.04 (matching Ubuntu Asahi). However, a direct comparison of its
`.sls` (SaltStack) files against SIFT's (`teamdfir/sift-saltstack`,
which does officially support arm64) softens that categorical "no":

**In favor of reconsidering it:**
- `remnux/packages/cast.sls` (the installer's own bootstrap) **already
  has a native arm64 branch**, needing no patch — unlike SIFT's
  `docker.sls`, which `jonathanlooi/sift-on-arm` had to fix by hand due
  to an architecture bug.
- `remnux/repos/remnux.sls` (the main repository) uses a **Launchpad
  PPA** (`pkgrepo.managed`, `ppa: remnux/stable`), an architecture-
  transparent mechanism by design — it doesn't have the same kind of bug
  that broke the Docker repo in SIFT.

**Against it — a risk of a different category than SIFT's:**
- `remnux/packages/runsc.sls` (and presumably other Windows-malware
  analysis tools) depend on **Wine**, whose arm64 support is still
  immature (needs FEX-Emu/box86 or Wine's native WoW64, still under
  development). This is an **architectural** problem, not a packaging
  one — it can't be fixed with a one-line patch.
- `remnux/tools/polarproxy.sls` downloads a `linux-x64` binary directly,
  with no architecture branch at all, because the vendor (NETRESEC)
  **only publishes an x64 build**. There's no possible patch without the
  external vendor publishing an arm64 build.

**Conclusion**: unlike SIFT, which describes its arm64 gaps as "a
handful of packages," REMnux — focused on Windows malware analysis —
likely has a larger fraction of its ~300 tools affected by Wine
dependencies or vendor-specific amd64-only binaries — a more widespread
and structurally different problem. **Now offered as an optional step 09
sub-option** (`confirm_yes_no`, never automatic), by orchestrating the
scripts vendored under `forensics/remnux/` from the
`forensic-distros-silicon-external-disk` satellite project: a full
`remnux.addon` run (~88% of states succeed), followed by cleanup of
known-broken x86-64 binaries and an attempt to install native arm64
alternatives for some of them (`docker-compose`, `redress`, `yara-x`,
`detect-it-easy`). See `forensics/remnux/FINDINGS.md` for the full,
up-to-date breakdown of what does and doesn't work, and
`forensics/README.md` for how to pull in a newer approved version.

### ❌ CAINE — discarded, not a convertible-repository model

CAINE ships as a **modified Live ISO** ("a simple Ubuntu 18.04
customized for the computer forensics", per its own documentation), not
as an APT repository that can be added on top of an already-installed
base. There's no "conversion" mechanism like the one Kali, Parrot, or
SIFT have. Discarded due to a model mismatch, not lack of arm64
support.

## How several systems coexist on the same external disk

Each active operating system (`ACTIVE_OS` in the state) has:

- **Its own partitions** on the external disk (numbers computed
  automatically by step 02 from whatever already exists).
- **Its own LVM volume group** (`vg<id>`) and its own LUKS container
  (`<id>_root_crypt`), with its own passphrase.
- **Its own progress** in the menu (`OS_<id>_STEP_<N>_STATUS`), so you
  can have Kali fully done and Ubuntu half-way through, and the menu
  shows the right thing for each.

Host steps (00, 01, 01a) are done **only once**, not per system: the
`iac` user, the root password, WiFi and the base packages belong to the
source Debian/Asahi system, not to each clone. (If you're also going to
clone toward Ubuntu, keep in mind those host steps were done on
whichever Debian/Asahi was booted at the time — the Ubuntu/Asahi you'll
boot to clone toward `ubuntu` is a different filesystem with its own
starting user/packages, see `docs/ARCHITECTURE.md`.)

## What to check after adding a second operating system

Step 07 (grub.cfg merge) runs `update-grub` on the host before merging
the entry of the system being processed at that moment. That
**regenerates the host's `grub.cfg` from scratch**, so:

- The entry of the system you processed **first** (e.g. Kali) may
  reappear thanks to `os-prober` (which detects existing Linux
  installations), but as a generic "chainload" boot entry, not the
  native one with the correct kernel parameters that this script builds
  by hand.
- The entry of the system you're processing **now** (e.g. Parrot or
  Ubuntu) does get the full, native treatment.

**Recommendation**: after adding a second operating system, boot and
check that both entries still appear in the GRUB menu and that both boot
correctly. If the older entry is missing or fails, you can re-run step
07 for that system (switch the active OS to it and re-run 07) to
regenerate its native merge.

## Adding a new operating system to the catalogue

All the generalization work is already done in the framework; adding a
new operating system (e.g. BlackArch) only requires touching three
places:

### 1. `lib/os_catalog.sh`

```bash
SUPPORTED_OS=(kali parrot ubuntu blackarch)

declare -A OS_LABEL_CODE=(
    [kali]="KALI"
    [parrot]="PARROT"
    [ubuntu]="UBUNTU"
    [blackarch]="BLKARCH"   # max. 11 characters for the EFI (FAT) label
)

# If the new OS needs CONVERSION (like Kali/Parrot), its source base is
# "debian". If it's CLONED AS-IS (like Ubuntu), its source base is its
# own id, and requires a separate installation of that OS on the
# internal disk.
declare -A OS_SOURCE_BASE=(
    [kali]="debian"
    [parrot]="debian"
    [ubuntu]="ubuntu"
    [blackarch]="debian"   # or whatever applies
)
```

### 2. `i18n/strings.en.sh`

```bash
STRINGS[os_blackarch_name]="BlackArch Linux"
STRINGS[os_blackarch_desc]="Short description..."
```

### 3. `steps/08_repositories.sh` and `steps/09_package_installation.sh`

Add a `blackarch)` branch to the `case "$TARGET_OS" in ... esac` in each
one, with the corresponding keys/repositories and metapackages (if the
OS requires conversion), or just an `apt update/upgrade` (if it's cloned
as-is, like Ubuntu).

**Nothing else needs to change**: the menu, partition-number
calculation, partitioning, LUKS encryption, cloning, chroot, source-base
verification, and `grub.cfg` merging are all fully generic and work for
any id that appears in `SUPPORTED_OS`.

### Before adding a system, check

- If it requires **conversion**: that it has an **official apt
  repository with `arm64` architecture** (a desktop ISO for x86/amd64
  alone isn't enough). Same requirement Kali and Parrot both meet.
- If it's **cloned as-is** (like Ubuntu): that a native install of that
  OS for Apple Silicon exists to boot the internal disk with
  (equivalent to Ubuntu Asahi).
- Which **metapackage(s)** install the desired toolset (the equivalent
  of `kali-linux-default`, `parrot-tools-full`, or `ubuntu-desktop`).
- Whether it needs any Apple Silicon/u-boot-specific boot tweak not
  already covered by the generic step 06 (unlikely for a Debian/Ubuntu-based
  distribution, but worth checking).
- Check real arm64 package availability before assuming anything — see
  the general method (with concrete commands) in
  `docs/TROUBLESHOOTING.md`.
