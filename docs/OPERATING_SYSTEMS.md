# Several operating systems on the same disk — base_inst_kali

## Currently supported systems

| Id | Name | Method | Required source base | arm64 support |
|---|---|---|---|---|
| `kali` | Kali Linux | Conversion: adds repos on top of the cloned base | Debian/Asahi | Official and mature |
| `parrot` | Parrot OS | Conversion: adds repos on top of the cloned base | Debian/Asahi | Official, but less tested than Kali on Apple Silicon |
| `sift` | Ubuntu + SIFT | Cloned as-is, no conversion | Ubuntu/Asahi | Official arm64 (SIFT itself) |
| `remnux` | Ubuntu + REMnux | Cloned as-is, no conversion | Ubuntu/Asahi | ~88% of remnux.addon states succeed on arm64 |

Kali and Parrot are Debian-based distributions with their own `arm64`
repository: they're obtained by **converting** an already-cloned
Debian/Asahi base, adding their repository and signing key on top
(steps 08-09). `sift`/`remnux` are different: there's no meaningful
"conversion" (neither Kali nor Parrot are officially Ubuntu-based, and
Ubuntu is already Ubuntu), so each is **cloned as-is** from a genuine,
separate **Ubuntu/Asahi** installation on the internal disk (see
[Ubuntu Asahi](https://ubuntuasahi.org/), the community project that
natively installs Ubuntu Desktop 24.04/24.10 on Apple Silicon). There's
no plain "ubuntu" target — this installer only cares about Ubuntu as a
forensics base, not as a general-purpose desktop clone.

### `sift` and `remnux` are two separate clones, not sub-options of one Ubuntu

`sift` and `remnux` are two distinct ids in `SUPPORTED_OS`, each cloned
independently from the same Ubuntu/Asahi source — **not** two
sub-options of a single "Ubuntu" install. Every `os_*` helper in
`lib/os_catalog.sh` (partition labels, LVM volume group name, LUKS
mapper name, mountpoint) derives its name from the target id, so each
gets its **own partitions, its own volume group** (`vgsift`,
`vgremnux`) **and its own LUKS container**, fully independent of the
other. You can have both installed on the same external disk at once,
each picked separately from the "Operating systems" menu, each with its
own GRUB boot entry after its own steps 02-09 run — as opposed to a
single Ubuntu where answering "yes" to both would install them into the
same volume group.

This split used to be a single `ubuntu` target with two `confirm_yes_no`
prompts in step 09 (install SIFT? install REMnux?), and before that
briefly had a third, plain `ubuntu` id alongside `ubuntu_sift`/
`ubuntu_remnux`. Both were dropped: choosing `sift` or `remnux` from the
"Operating systems" menu now **is** the decision — step 09 installs the
corresponding toolkit unconditionally, with no further prompt, and
there's no bare-Ubuntu-with-no-toolkit option since this installer's
Ubuntu targets exist specifically for forensics.

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

## SIFT and REMnux: what steps 08-09 do

- **Step 08**: no repositories to add for either (they're already
  genuine Ubuntu) — just `apt update`, no system upgrade (see
  `docs/TROUBLESHOOTING.md` for why a full-upgrade here previously
  broke the graphical session on real hardware).
- **Step 09**:
  1. Installs `ubuntu-desktop` **idempotently** (checks with `dpkg -l`
     whether it's already there and skips if so — the Ubuntu Asahi image
     usually already ships with a desktop). Runs for both targets.
  2. `sift`: installs **SIFT Workstation** (SANS) — see the full
     verdict below. Unconditional: choosing this target already is the
     decision to have SIFT here.
  3. `remnux`: installs **REMnux** — see the verdict below and
     `forensics/README.md` for where its scripts come from. Also
     unconditional, same reasoning.

## Forensic tools investigated for Ubuntu: verdict

Three candidate forensic distributions/toolkits were evaluated for
running on top of a cloned Ubuntu. Result:

### ✅ SIFT Workstation (SANS) — integrated as the `sift` target

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

### 🟡 REMnux — in doubt, not fully discarded (open investigation), now its own `remnux` target

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
and structurally different problem. **Now integrated as its own
`remnux` target** (step 09, unconditional — no confirmation
prompt, since choosing that target already is the decision), by
orchestrating the
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
  can have Kali fully done and `sift` half-way through, and the menu
  shows the right thing for each.

Host steps (00, 01, 01a) are done **only once**, not per system: the
`iac` user, the root password, WiFi and the base packages belong to the
source Debian/Asahi system, not to each clone. (If you're also going to
clone toward `sift`/`remnux`, keep in mind those host steps were done on
whichever Debian/Asahi was booted at the time — the Ubuntu/Asahi you'll
boot to clone toward `sift`/`remnux` is a different filesystem with its own
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

> **Want both internal bases' boot menus to see each other?** (e.g.
> Debian/Asahi's menu also offering an entry into Ubuntu+SIFT, or vice
> versa.) Run the optional `07b_grub_cross_merge.sh` step (menu, right
> after 07) once per direction — it's a `NO_GATE_STEPS` entry, so it
> never blocks 08/09. See
> [docs/ARCHITECTURE.md](ARCHITECTURE.md#two-independent-grubs-and-how-07b-bridges-them)
> for how it works and why it doesn't need re-syncing after future
> `update-grub` runs.

## Adding a new operating system to the catalogue

All the generalization work is already done in the framework; adding a
new operating system (e.g. BlackArch) only requires touching three
places:

### 1. `lib/os_catalog.sh`

```bash
SUPPORTED_OS=(kali parrot sift remnux blackarch)

declare -A OS_LABEL_CODE=(
    [kali]="KALI"
    [parrot]="PARROT"
    [sift]="SIFT"
    [remnux]="REMNUX"
    [blackarch]="BLKARCH"   # max. 11 characters for the EFI (FAT) label
)

# If the new OS needs CONVERSION (like Kali/Parrot), its source base is
# "debian". If it's CLONED AS-IS (like sift/remnux), its source base is
# "ubuntu", and requires a separate Ubuntu/Asahi installation on the
# internal disk.
declare -A OS_SOURCE_BASE=(
    [kali]="debian"
    [parrot]="debian"
    [sift]="ubuntu"
    [remnux]="ubuntu"
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
OS requires conversion), or just an `apt update` (if it's cloned
as-is, like `sift`/`remnux`).

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
