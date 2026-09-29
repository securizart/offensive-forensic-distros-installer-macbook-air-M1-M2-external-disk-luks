# iK4lN3 forensic software write-blocker

Holds every **non-system** disk read-only at the block layer, at boot and
on hot-plug, so evidence media can't be altered by accident — while the
disks that carry the running OS stay writable so the machine keeps working.

## Why this is different from a live forensic distro

A live forensic distro runs from RAM and can block *every* disk. iK4lN3 is
an **installed** system, so blocking everything would freeze the root disk
and the machine won't boot. This write-blocker therefore **detects the
system disks and never blocks them**:

- the whole disks backing `/`, `/boot`, `/boot/efi`, `/usr`, `/var`, and
  active swap — including the full **LUKS → LVM → partition → disk** chain
  beneath them (resolved with `lsblk --inverse`).

Everything else is treated as evidence and marked read-only with
`blockdev --setro` (parent disk **and** every partition — marking only a
partition is not enough).

## Fail-safe

The boot service refuses to arm if it can't confirm the root disk is in the
protected set. A misdetection leaves everything **writable** (OS keeps
running) rather than risking a frozen system. Nothing is blocked until the
system-disk whitelist exists, so an early-boot hot-plug can't catch the
root disk.

## Parts

| File | Installed to | Role |
|---|---|---|
| `writeblock-lib.sh` | `/usr/lib/ik4ln3/` | system-disk detection + block helpers |
| `writeblock-boot` | `/usr/lib/ik4ln3/` | boot service: build whitelist, arm, block present evidence |
| `writeblock-udev` | `/usr/lib/ik4ln3/` | per-device helper, blocks non-system disks on hot-plug |
| `99-ik4ln3-writeblock.rules` | `/etc/udev/rules.d/` | fires the helper on every block `add` |
| `ik4ln3-writeblock.service` | `/etc/systemd/system/` | arms at boot after fs/swap are up |
| `ik4ln3-writeblock` | `/usr/local/bin/` | CLI: `status / on / off / allow / block` |
| `ik4ln3-mounter` | `/usr/local/bin/` | GUI (yad) in the Forensic Tools menu |

## Use

```
ik4ln3-writeblock status        # every disk, its RO/RW state, system vs evidence
ik4ln3-writeblock allow sdX     # deliberately make one disk writable
ik4ln3-writeblock block sdX     # re-block it
ik4ln3-writeblock off | on      # disarm / arm globally
ik4ln3-mounter                  # the GUI equivalent
```

## Honest limitations (read before relying on it in a case)

Software write-blocking is a **safety net, not a hardware write blocker**:

- `blockdev --setro` and the `ro` mount flag instruct the filesystem
  drivers but do **not** stop every possible kernel write; a driver that
  lacks the checks may still issue writes.
- The **SG_IO** interface passes arbitrary SCSI commands straight through
  the read-only flag. Never run an SG_IO-using utility against a connected
  evidence device.
- For **court-defensible** acquisition, use a hardware write blocker and
  verify the image with cryptographic hashes before and after.

This tool prevents accidental writes and enforces a read-only default; it
does not by itself make an acquisition legally defensible.
