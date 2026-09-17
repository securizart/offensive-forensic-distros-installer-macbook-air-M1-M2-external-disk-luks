# Troubleshooting — base_inst_kali

## How to check if a package exists for arm64 (before adding it to a new OS)

Useful whenever you're considering adding a new tool or distro to the
catalogue (see `docs/OPERATING_SYSTEMS.md`), so you don't assume
anything:

**On a real Debian/Ubuntu machine** (arm64, or cross-checking from
amd64):

```bash
sudo dpkg --add-architecture arm64
sudo apt update
apt-cache policy <package>:arm64
```

If "Candidate" is empty, no arm64 build exists in the configured repos.
To catch broken dependency chains before installing anything for real:

```bash
apt-get install --simulate <package>
```

**Without touching any machine** (web lookup):

| Source | Architecture search URL |
|---|---|
| Debian | `packages.debian.org/search?arch=arm64&keywords=PKG` |
| Ubuntu | `packages.ubuntu.com/search?arch=arm64&keywords=PKG` |
| PPA (Launchpad) | `launchpad.net/~USER/+archive/ubuntu/NAME` → "View package details" tab |

Important: Ubuntu splits its mirror — `archive.ubuntu.com` only serves
`amd64`/`i386`; `arm64` lives on `ports.ubuntu.com`. If a `sources.list`
points at the former, `arm64` will never show up even if it exists on
the latter.

**`rmadison`** (from the `devscripts` package), a quick check without
needing a local `dpkg --add-architecture`:

```bash
rmadison -a arm64 <package>                # Debian
rmadison -u ubuntu -a arm64 <package>      # Ubuntu
```

## The firmware doesn't detect the external disk at boot

On some MacBooks (seen on Air M1 and M2), after step 07, when picking
the Kali/Parrot entry from the boot menu, the process can hang or drop
to the `u-boot` prompt because the firmware hasn't detected the
external USB disk in time (the USB bus isn't always ready when u-boot
does its first scan of boot devices).

If you land at the `u-boot` prompt (something like `=>`), type:

```
env set boot_efi_mgr
run bootcmd_usb0
```

- `env set boot_efi_mgr` sets up the environment variable u-boot uses
  for the EFI boot manager.
- `run bootcmd_usb0` forces a new scan of the first USB controller,
  which is usually enough for the external disk to show up so u-boot
  can continue on to the GRUB menu normally.

If this happens on every boot, try connecting the disk to a different
port (MacBook Airs only have 2 Thunderbolt/USB-C ports and they don't
all behave the same during early boot), or use a better-quality
cable/adapter — this is an early bus-detection issue, not a problem
with the partitions or the cloned system itself.

## "No active operating system"

Steps 02-09 need an active OS. Go to the menu, "Operating systems"
option, and pick Kali or Parrot before continuing.

## "TARGET_DISK is not set or invalid"

Step 00 hasn't run, or it ran but the selected disk later disappeared
(e.g. you unplugged the USB). Check:

```bash
cat /var/lib/base_inst_kali/state.conf | grep TARGET_DISK
lsblk
```

Re-run step 00 if it needs fixing. Note: `TARGET_DISK` is shared across
every operating system you install on that disk, no need to repeat it
per OS.

## The menu marks a step as "✖ failed, retry"

Look at that specific step's log:

```bash
ls -t logs/step_<ID>_*.log | head -1 | xargs cat
```

The full run output (including `apt`, `sgdisk`, etc.) is there. The
master log (`logs/install.log`) only has the summary line with where and
with what exit code it failed.

## whiptail doesn't show up even though I already ran step 01

Check the package actually installed:

```bash
dpkg -l whiptail
```

If it's missing, install it manually (`apt install whiptail`) and retry
the step; you don't need to redo anything earlier, `lib/ui.sh` picks it
up on its own the next time any script runs.

If `whiptail` is installed but the installer still runs in text mode,
there may be no real interactive terminal (for example, you're piping
input/output, or running inside `screen`/`tmux` in a way that doesn't
expose a tty). Run the script directly in a normal terminal.

## Exiting the chroot (step 06) doesn't mark "06" as done on the host menu

This is expected, not a bug: step 06 runs inside the chroot and writes
its progress to the mounted external disk's filesystem, not the host's.
That's why step 07 doesn't depend on that mark (see `NO_GATE_STEPS` in
`install.sh` and the corresponding section in
`docs/ARCHITECTURE.md`). Just continue with step 07 as normal.

## "/part/dest_<os>/boot/grub/grub.cfg does not exist" in step 07

The external disk got unmounted between step 05/06 and 07 (for example,
if you rebooted by accident). Repeat from step 05 (with the same active
OS) to mount and enter the chroot again, run 06 again, and continue with
07 without rebooting.

## I forgot an operating system's LUKS passphrase

There's no way to recover the data without it; it's real encryption.
You'll have to repeat from step 02 (repartition) or step 03
(reformat/re-encrypt) **for that specific operating system**, losing
whatever was on its partitions up to that point. Other operating systems
on the same disk are unaffected.

## After adding a second operating system, the first one no longer boots

See the corresponding section in `docs/OPERATING_SYSTEMS.md`: step 07
regenerates `grub.cfg` from scratch every time, and the most recently
processed system is the one that gets the full native entry. Switch the
active OS to the affected system and re-run step 07 to regenerate its
entry.

## I want to redo a step already marked "done"

Pick it from the menu anyway (it isn't locked — only the steps *after*
the first pending one are) or run it standalone:

```bash
sudo bash steps/04_cloning.sh
```

Keep in mind that partitioning/formatting/cloning steps are destructive
and will ask you for explicit confirmation, but redoing them means
losing whatever was done afterwards **for that operating system**.

## WiFi doesn't connect after step 01a

Check the generated file:

```bash
cat /etc/wpa_supplicant/wpa_supplicant.conf
```

If the SSID or password contain special characters and `wpa_passphrase`
wasn't used (because it wasn't available at the time), retry the step:
the script itself tries to use it automatically whenever it's present on
the system.

## A Parrot OS metapackage fails to install (step 09)

Parrot's arm64 support is official but less mature than Kali's. Check
`logs/step_09_*.log` to see which specific package failed, then install
or replace it manually afterwards (`apt install <package>`); there's no
need to redo the whole step 09 over a single problematic package.

## "⚠ Active operating system: X. This system needs to be cloned from a Y base booted..."

You picked an active OS (e.g. `ubuntu`) but the system currently booted
on the internal disk doesn't match the base that OS requires
(`verify_source_base` in `lib/os_catalog.sh`, see
`docs/ARCHITECTURE.md`). Reboot the Mac and pick the correct internal
boot entry in the firmware:

- For `kali`/`parrot`: the Debian/Asahi entry.
- For `ubuntu`: the Ubuntu/Asahi entry.

This check is intentionally blocking — the next step clones whatever is
currently booted, so a wrong source would mean cloning the wrong system
onto already-destructive partitions.

## SIFT installation (Ubuntu, step 09) skips some packages

This is expected and documented by the SIFT project itself
(`teamdfir/sift-saltstack`): "a handful of packages are amd64-only and
are skipped on arm64." Check `logs/step_09_*.log` (the full output of
`cast install teamdfir/sift-saltstack`) to see exactly which ones were
skipped in your specific install — it can vary between SIFT versions.
This isn't a failure of the installer or of `install_cast_arm64`; it's
a known, accepted upstream limitation.

## `install_cast_arm64` fails to install `cast` (SIFT, Ubuntu)

Check the internet connection on the already-booted Ubuntu. The
function (`lib/common.sh`) resolves the latest version of
[ekristen/cast](https://github.com/ekristen/cast) by following the
`.../releases/latest` redirect (avoiding the GitHub API, which has an
easily-exhausted rate limit); if GitHub isn't reachable, it will fail
there without interrupting the rest of the install. You can test it by
hand:

```bash
curl -fsSL -o /dev/null -w '%{url_effective}\n' https://github.com/ekristen/cast/releases/latest
```

If this doesn't return a URL with `/releases/tag/vX.Y.Z`, the problem
is network/DNS/firewall related, not the script.

## Step 01 fails on Ubuntu/Asahi: `run-parts: missing operand` / kernel package half-configured

Symptom, during `apt upgrade`/`apt install` (step 01):

```
Processing triggers for linux-image-7.0.0-1001-asahi-arm (7.0.0-1001.1)…
run-parts: missing operand
Try `run-parts --help' for more information.
dpkg: error processing package linux-image-7.0.0-1001-asahi-arm (--configure):
 installed linux-image-7.0.0-1001-asahi-arm package post-installation script subprocess returned error exit status 1
```

This is a **confirmed, open Ubuntu kernel-packaging bug**
([Launchpad #2148348](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2148348)),
not something wrong with this installer or your hardware: the 7.0.x
kernel package's maintainer scripts call `run-parts` with two hook
directories at once (`/etc/kernel/postinst.d` and
`/usr/share/kernel/postinst.d`), but the `run-parts` shipped with
Ubuntu 24.04 (noble) only accepts one directory per call and aborts.
Ubuntu/Asahi inherits it because its kernel tracks that same 7.0.x
series. Step 01 (since this version) no longer forces a blanket
`apt upgrade -y` on Ubuntu/Asahi for this reason — but if you already
hit this before that change, or triggered a kernel upgrade some other
way, dpkg is left with that kernel package half-configured and every
further `apt`/`dpkg` call will fail the same way until it's resolved.

**To recover**, on the affected Ubuntu/Asahi (adjust the version
numbers to whatever your `dpkg -l | grep linux-image` shows):

```bash
# 1) Stop apt from retrying the broken kernel package version
sudo apt-mark hold linux-image-7.0.0-1001-asahi-arm linux-image-asahi-arm \
    linux-headers-7.0.0-1001-asahi-arm linux-headers-asahi-arm \
    linux-asahi-arm-headers-7.0.0-1001

# 2) Confirm your previously-working kernel is still installed and was
#    the one you actually booted
uname -r
dpkg -l | grep linux-image

# 3) Remove the half-configured new kernel package instead of forcing
#    it to finish configuring (it never will, until Ubuntu fixes the
#    bug upstream)
sudo apt-get remove --purge linux-image-7.0.0-1001-asahi-arm linux-headers-7.0.0-1001-asahi-arm
sudo dpkg --configure -a
sudo apt-get install -f
```

If step 3's `remove --purge` itself fails on the same `run-parts`
error (it runs the same broken postrm trigger), force it without
running that trigger instead:

```bash
sudo dpkg --remove --force-remove-reinstreq linux-image-7.0.0-1001-asahi-arm
sudo dpkg --configure -a
```

Re-run step 01 once `dpkg -l | grep ^..r` (broken/half-configured
packages) comes back empty.

## Graphical session breaks after step 09 (SIFT or REMnux), kernel unchanged

Symptom: `uname -r` still shows the same kernel step 08 left in place
(e.g. `6.11.0-1001-asahi-arm`), but after step 09 finishes and reboots,
the graphical session doesn't start (console only, no GDM/GNOME) — the
same symptom as the step 08 `apt full-upgrade` mismatch described
above, but this time with no `apt upgrade`/`full-upgrade`/`dist-upgrade`
run by this installer's own code anywhere in step 08 or 09.

The cause is the same class of problem, triggered from a different
place: SIFT's own SaltStack states (`teamdfir/sift-saltstack`, applied
via `cast install`) and REMnux's own `remnux.addon` run both add
several apt repositories of their own (`gift`, `sift`, `openjdk`,
`dotnet-backports`, Microsoft's repo, REMnux's own PPA) as part of
provisioning. Refreshing package lists against those new repositories
can pull in newer versions of already-installed packages — including
`mesa-vulkan-drivers`, `gnome-shell`, and other pieces of the GPU
userspace stack that are version-coupled to the kernel on Ubuntu/Asahi
(see the step 08 section above) — as a side effect of SIFT/REMnux's own
provisioning logic, not from any `apt upgrade` this installer runs
itself.

Step 09 holds the kernel/GPU-userspace family (`apt-mark hold`) around
both `cast install teamdfir/sift-saltstack` and REMnux's
`install_remnux_arm64`, releasing the hold again right after —
specifically the kernel image/headers/modules, `ubuntu-asahi` itself,
Mesa, the display manager/compositor, and Xorg/Wayland
(`hold_graphics_kernel_packages` in `lib/common.sh`). This blocks
SIFT/REMnux's provisioning from silently upgrading the pieces that
actually caused the graphical session to break; everything else,
including genuinely new packages they install, is unaffected.

**This used to hold every currently-installed package**, not just this
family — found on real hardware that this was too broad: SIFT's own
SaltStack states couldn't resolve their own package dependencies
anymore (`E: Unable to correct problems, you have held broken
packages.`, 140 of 846 salt states failing, starting with
`sift.packages.g++`), because a hold blocks upgrading a shared
dependency too, not just the packages you actually care about. Narrowed
to the specific family above for that reason. If you still hit a
similar "held broken packages" error with the narrower list, that
specific package needs something in the held family — check which one
in the log and, if you're confident it's safe, `apt-mark unhold
<package>` by hand before retrying step 09.

If you're on an older run from before this guard existed and already
hit this, the recovery is the same as for the step 08 case: reboot into
the internal Ubuntu/Asahi and redo the clone from step 03 onward.
