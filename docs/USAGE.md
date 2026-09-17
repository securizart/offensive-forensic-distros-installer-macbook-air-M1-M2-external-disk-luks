# Usage guide — base_inst_kali

## Before you start

- **This installer requires deep Linux system administration
  knowledge** (partitioning, LVM, LUKS, chroot, GRUB, APT package
  management). It's not suitable for someone new to Linux: a
  misunderstood step can leave the Mac unable to boot. If you're unsure
  what any of those terms mean, learn them before continuing.
- **The MacBook Air must already have the matching base installed and
  up to date** on the internal disk (NVMe): Asahi Linux/Debian
  (following <https://wiki.debian.org/InstallingDebianOn/Apple/M1>) to
  clone toward Kali or Parrot, or Ubuntu Asahi
  (<https://ubuntuasahi.org/>) to clone toward the `sift`/`remnux`
  targets. This installer
  does not install or replace it; it assumes it's already there and
  working.
- **If you want both offensive distros (Kali/Parrot) and forensic tools
  (`sift`/`remnux`, cloned from Ubuntu/Asahi) on the same external
  disk, install BOTH bases on the internal disk**: Debian/Asahi and
  Ubuntu/Asahi, as two separate installs. There's no conversion between
  them, so you switch by rebooting and picking the corresponding
  internal boot entry before cloning toward each target. Host steps
  00/01/01a need to be repeated once per base the first time you use it
  (see [docs/OPERATING_SYSTEMS.md](OPERATING_SYSTEMS.md)).
- **Check for yourself that this Debian/Asahi base is compatible with
  the version of Kali or Parrot you're about to install** before
  reaching steps 08-09 (repositories and metapackages). This installer
  does not validate that compatibility for you — check each
  distribution's official documentation.
- **Make as many backups of your macOS as necessary** before starting
  (Time Machine and, if possible, a full disk clone), and verify
  they're restorable before touching anything.
- You need an **external USB disk**. It can host more than one
  operating system (e.g. Kali and Parrot at once), each in its own
  partitions. Note its size so you can tell it apart from the internal
  NVMe when step 00 asks you to pick it.
- Everything must run as **root** (`sudo bash install.sh` or already
  logged in as root).
- Keep the `/base_inst_kali/preparation/` directory handy with the
  supporting files if you use them (`sudoers`, `grub`, `modules.txt`,
  `interfaces`, `keyboard`, `locale`, the Kali keyring `.deb`). If they
  don't exist, each step detects it and warns what it's skipping, but
  doesn't fail.

## Starting the installer

```bash
sudo bash install.sh
```

You'll see a menu (whiptail if already installed, plain text otherwise)
with:

- The **host** steps (00, 01, 01a) — done once.
- An **active operating system** selector ("Operating systems" option).
- Steps **02-09**, which always correspond to the currently active
  operating system.

| Status | Meaning |
|---|---|
| `✓ done` | Step completed successfully. |
| `▶ next` | The next pending step, in order. |
| `pending` | Not its turn yet (earlier steps aren't finished). |
| `✖ failed, retry` | The last run ended in error; check the log before retrying. |
| `locked` | Requires finishing the previous step first (a warning, doesn't stop you from picking it manually if you know what you're doing). |

## Recommended order — first install (e.g. Kali)

1. **00 · Check prerequisites and pick the disk** — detects the
   architecture, warns if it sees no `asahi-*` packages, and has you
   choose the external disk from a list (or type it manually). Saved for
   the rest of the steps and for every operating system you install on
   it.
2. **01 · Base preparation** — changes the root password, installs the
   base packages (including `whiptail`), configures locale/keyboard, and
   creates the `iac` user. Done once.
3. **01a · WiFi network** — optional if you already have wired network.
   Once.
4. **Operating systems → pick "Kali Linux"** — from here on, the menu's
   02-09 steps are Kali's.
5. **02 · Partition external disk** — computes and creates Kali's
   partitions on the chosen disk. **Requires an explicit destructive
   confirmation.**
6. **03 · LUKS + LVM + formatting** — encrypts Kali's root partition.
   **You will be asked for a passphrase here: write it down somewhere
   safe, there's no way to recover the data without it.**
7. **04 · Cloning** — copies the current system onto Kali's partitions
   (takes a while, depending on how much is used).
8. **05 · Mount and enter chroot** — leaves you inside a `chroot` when
   done. From there, run:
   ```bash
   /base_inst_kali_installer/steps/06_grub_finalize.sh
   ```
9. **06 · Finalize GRUB** (inside the chroot) — exit with `exit` when
   done.
10. **07 · Merge grub.cfg** — runs outside the chroot, on the host.
    Reboots when done.
11. **Reboot and pick Kali's entry** from the GRUB boot menu (not the
    normal Debian/Asahi entry).

    > If the boot hangs or drops to a `u-boot` prompt because the
    > firmware doesn't detect the external disk, see
    > [docs/TROUBLESHOOTING.md#the-firmware-doesnt-detect-the-external-disk-at-boot](TROUBLESHOOTING.md#the-firmware-doesnt-detect-the-external-disk-at-boot).
12. **08 · Kali repositories** — already booted into the cloned system.
13. **09 · Install Kali metapackages** — last step for Kali.

## Adding a second operating system (e.g. Parrot) on the same disk

No need to repeat steps 00/01/01a (already done at the host level).
Simply:

1. Boot back into the original Debian/Asahi system (not Kali).
2. Open `install.sh`, **"Operating systems" → "Parrot OS"**.
3. Repeat steps **02-09** as-is, but now they run for Parrot: step 02
   will automatically compute new partitions (e.g. 4, 5 and 6 if Kali
   already took 1, 2 and 3), without touching what Kali already has.
4. When done, the GRUB boot menu should show **three** entries: the
   original Debian/Asahi, Kali, and Parrot. See
   `docs/OPERATING_SYSTEMS.md` for why it's worth checking this after
   adding a second system.

> **Adding a system from the *other* base** (e.g. Ubuntu after Kali, or
> Kali after Ubuntu): this isn't "boot back into the original system",
> it's booting into the **other, separately-installed base** on the
> internal disk (Ubuntu/Asahi for Ubuntu, Debian/Asahi for Kali/Parrot —
> see [docs/OPERATING_SYSTEMS.md](OPERATING_SYSTEMS.md)). Since the
> "Operating systems" menu only offers targets matching whatever base is
> currently booted, you won't see Ubuntu listed while booted into
> Debian/Asahi, or vice versa. You'll also need to redo host steps
> 00/01/01a on that other base the first time, since it's a separate
> filesystem with its own state.

## Resuming after a reboot

State is saved in `/var/lib/base_inst_kali/state.conf` and survives
`reboot`s. To have the menu reopen on its own, add to `/root/.bashrc`:

```bash
if [ -t 0 ]; then
    bash /base_inst_kali/install.sh
fi
```

## Viewing the logs

From the menu, option `l`/`LOGS`, or directly:

```bash
ls logs/
cat logs/install.log              # summary of all steps
cat logs/step_03_<date>.log       # full output of a specific step
```

## Running a single step without the menu

Every script is self-contained (it reads `ACTIVE_OS`/`TARGET_DISK` from
the saved state):

```bash
sudo bash steps/03_formatting.sh
```

Useful for debugging or retrying a failed step, though it's normally
better to do it from `install.sh` so the active operating system and the
state stay in sync.
