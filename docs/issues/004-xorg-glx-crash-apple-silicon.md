# X server crashes on Apple Silicon; software rendering on M2

**Labels:** bug, graphics, apple-silicon, worked-around
**Affects:** iK4lN3 (MATE/Xorg) · Apple Silicon, M2 especially · linux-asahi 6.11.x
**Status:** Worked around in v2.0.1 (software rendering) — full GPU accel pending upstream

## Symptoms
After installing iK4lN3, the system reaches `graphical.target` (LightDM is
running) but the **X server crashes** instead of showing the desktop. On
**M1** the desktop comes up fine; on **M2** it crashes. `/var/log/Xorg.0.log`
ends with:

```
(II) modeset(0): Refusing to try glamor on llvmpipe
(II) modeset(0): glamor initialization failed
...
(II) Initializing extension GLX
(II) AIGLX: Screen 0 is not DRI2 capable
(EE) Segmentation fault at address 0x40
(EE) Caught signal 11 (Segmentation fault). Server aborting
```

## Root cause
Two factors combine:

1. **MATE uses Xorg; the Ubuntu/Asahi base uses GNOME on Wayland.** The
   other targets (SIFT/REMnux, GNOME) never exercise Xorg, so they're
   unaffected. On Apple Silicon the AGX GPU is a **separate render node**
   (`card1`) from the display controller (`card2`); Xorg's `modesetting`
   binds the display, can't get hardware GL, and falls back to `llvmpipe`.

2. **Mesa version mismatch on the cloned base.** On the affected system most
   of mesa is `25.1` (ubuntu-asahi archive) but `libglapi-mesa` is pinned at
   `24.2` (ubuntu-asahi PPA) — two repos overlapping. The software GL path
   links the mismatched `libglapi` and **segfaults** during GLX init.

**Why M1 works and M2 doesn't:** M1's GPU (G13) has working hardware GL in
this kernel, so GLX uses the hardware path and never touches the broken
software `libglapi`. M2's GPU (G14) has no working hardware GL yet, so it
falls to the software path and hits the mismatch. Same mesa state on both;
only the M2 triggers it.

## Workaround (shipped in v2.0.1)
`forensics/ik4ln3/16_install_ik4ln3_xorg.sh` installs
`/usr/share/X11/xorg.conf.d/20-ik4ln3-noglamor.conf`, which disables glamor
**and** the GLX extension:

```
Section "Device"
    Identifier "ik4ln3-modeset"
    Driver "modesetting"
    Option "AccelMethod" "none"
EndSection
Section "Module"
    Disable "glamoregl"
EndSection
Section "Extensions"
    Option "GLX" "Disable"
EndSection
```

X then starts with **software (framebuffer) rendering** — fine for a MATE
forensic desktop (no OpenGL-under-X; 2D only). Applied to both M1 and M2 for
safety (so the M1 also renders in software — acceptable trade-off; see
"Future").

## What was tried and did NOT work
- Disabling only glamor: X still crashed in GLX.
- Upgrading `libglapi-mesa` to its candidate `25.0`: still mismatched against
  the `25.1` rest of mesa; X still crashed. Fully aligning mesa would require
  a large (~586-package) upgrade that risks the Asahi kernel/GPU coupling —
  deliberately avoided.

## Future / fix path
- An Asahi **kernel + mesa** update with complete G14 (M2) GL support, which
  would make the hardware path work and the workaround unnecessary.
- Or a **Wayland** MATE session (agx works much better on Wayland than Xorg),
  if/when MATE's Wayland support matures.
- Optional: make the Xorg workaround **conditional** (apply only on M2/G14,
  let M1 keep hardware GL). Left unconditional in v2.0.1 for robustness.

## Benign noise (not the cause)
`dmesg` around desktop start shows `snd-soc-macaudio` speaker-volume
lock/unlock (SMC speaker protection) and `apparmor="DENIED"` for
`snapd-desktop-integration` reading `/etc/vulkan/` (confined snap). Both are
harmless and unrelated to this crash.
