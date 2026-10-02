# Software write-blocker: limitations and per-hardware verification

**Labels:** documentation, forensics, by-design, needs-verification
**Affects:** iK4lN3 (`forensics/ik4ln3/writeblock/`)
**Status:** Open — by-design limitation (documented) + detection to verify per hardware

## Summary
The iK4lN3 write-blocker is a **software** safety net, not a hardware write
blocker. Two things to be aware of before relying on it in a case.

## 1. Software write-blocking is advisory
- `blockdev --setro` and the `ro` mount flag instruct the drivers but do
  **not** stop every possible kernel write.
- On an **already-mounted** disk the read-only flag is effectively cosmetic
  (writes buffer through the page cache) — the same behaviour as any
  software write-blocker installed to disk rather than run from a live
  medium. On an **unmounted** evidence disk the block is effective
  (confirmed: `dd` to it fails).
- The **SG_IO** interface passes SCSI commands straight past the flag.

**Implication:** for court-defensible acquisition use a hardware write
blocker and verify with hashes. See
`forensics/ik4ln3/writeblock/README.md`.

## 2. System-disk detection must be verified per hardware
The write-blocker detects the disks that carry the running OS (root/boot/
swap + LUKS/LVM chain) and leaves them writable, blocking everything else.
On some real-hardware disk layouts (e.g. Apple internal NVMe namespaces +
external USB + LUKS/LVM) the detection has mis-flagged system disks.

**Fail-safe:** if the boot service cannot confirm the root disk, it does NOT
arm (leaves everything writable) rather than freeze the OS.

**Always verify after install:**
```
ik4ln3-writeblock status
```
Your system disks must show `SYSTEM (never blocked)`; only evidence media
should show `READ-ONLY`. If a system disk shows as evidence:
```
sudo ik4ln3-writeblock off
sudo systemctl disable ik4ln3-writeblock.service
```
and open an issue with `findmnt / /boot /boot/efi` and
`lsblk -o NAME,TYPE,MOUNTPOINT,SIZE` so detection can be fixed for that
layout.
