# Sudden shutdown right after GRUB following a macOS update (SMC power firmware)

**Labels:** bug, upstream (asahi), hardware, workaround-available
**Affects:** MacBook Air M1 / M2, after a recent macOS update · linux-asahi 6.11.x
**Status:** Open (upstream Asahi) — per-boot workaround documented

## Symptoms
After a recent macOS update, the distribution **powers off abruptly** a
moment after GRUB hands off to Linux. Boot never reaches a login. Systems
that were working before the macOS update start failing.

## Root cause
The macOS update bundles a **firmware update** that changes the MacBook's
**SMC power stack**. The current Asahi kernel's power-management driver
(`macsmc_power`) no longer understands the new firmware and triggers an
immediate power-off.

## Workaround (per boot)
At the GRUB menu press `e`, go to the end of the line that starts with
`linux`, append:

```
modprobe.blacklist=macsmc_power
```

then boot with `Ctrl+X` (or `F10`).

## Why NOT make it persistent
A future Asahi kernel is expected to understand the new power-management
firmware; once that lands, MacBook power management works again on its own.
A **persistent** blacklist would survive that fix and leave the machine
permanently without proper power management. Keep it per-boot.

## Fix path
Upstream Asahi kernel update that handles the new SMC firmware. Nothing to
change in this installer.
