# Known issues

Issues found while validating **iK4lN3** on real hardware (MacBook Air
M1/M2). Each has a ready-to-post write-up under [`docs/issues/`](issues/).
Resolved items ship in **v2.0.1** (see [`CHANGELOG.md`](../CHANGELOG.md));
open items have a workaround and are tracked below.

| # | Issue | Affects | Status (v2.0.1) |
|---|---|---|---|
| 001 | [Sudden shutdown after GRUB following a macOS update (SMC firmware)](issues/001-macsmc-power-shutdown.md) | M1 / M2 after a macOS update | **Open** — per-boot workaround (`modprobe.blacklist=macsmc_power`) |
| 002 | [Repository GPG key errors for Kali and Parrot (NO_PUBKEY)](issues/002-repo-gpg-keys.md) | Kali, Parrot targets | **Fixed** |
| 003 | [Software write-blocker: limits and per-hardware verification](issues/003-writeblocker-software-limits.md) | iK4lN3 | **Open / by design** — verify per hardware |
| 004 | [X server crashes on Apple Silicon; software rendering on M2](issues/004-xorg-glx-crash-apple-silicon.md) | iK4lN3 (MATE/Xorg), M2 esp. | **Worked around** — glamor+GLX disabled (software render) |

## Quick reference

- **Black/instant power-off right after GRUB, after a macOS update** → at the
  GRUB menu press `e`, append `modprobe.blacklist=macsmc_power` to the
  `linux` line, boot with `Ctrl+X`. See issue 001.
- **`NO_PUBKEY` / "repository is not signed" on Kali or Parrot** → the repo
  key rotated; v2.0.1 fixes the installer. Manual fix in issue 002.
- **iK4lN3 boots but X doesn't start / crashes (segfault)** → the Xorg fix
  (`forensics/ik4ln3/xorg/20-ik4ln3-noglamor.conf`) disables glamor + GLX so
  X starts with software rendering. See issue 004.
- **Write-blocker says a disk is blocked but it still writes** → expected for
  an already-mounted disk; software write-blocking is a safety net, not a
  hardware blocker. Always check `ik4ln3-writeblock status`. See issue 003.

## Hardware note (M1 vs M2)

iK4lN3's desktop uses **MATE on Xorg** (the Ubuntu/Asahi base runs GNOME on
Wayland). On Apple Silicon the GPU GL path through Xorg is fragile:

- **M1 (Apple G13 GPU):** GL works by hardware; the desktop is accelerated.
- **M2 (Apple G14 GPU):** no working hardware GL in the current Asahi kernel,
  so X falls back to software — which also hits a mesa version mismatch on
  the cloned base and crashes without the workaround.

The workaround (software rendering) is applied to both for safety. This is a
limitation of the current Asahi kernel/mesa on the M2, expected to improve as
Asahi matures (or by moving to a Wayland session). See issue 004.
