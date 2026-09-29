#!/bin/bash
# writeblock-lib.sh — shared helpers for the iK4lN3 software write-blocker.
#
# Sourced by: writeblock-boot (systemd oneshot), writeblock-udev (udev
# helper), and the ik4ln3-writeblock CLI. Pure helpers, no side effects on
# source.
#
# The single most important job here is compute_protected(): the set of
# whole disks that carry the RUNNING system (root, /boot, EFI, swap, and
# the LUKS/LVM chain beneath them). Those disks must NEVER be marked
# read-only, or the machine deadlocks / won't boot. Everything else is
# treated as evidence and can be write-blocked.

IK4LN3_RUN="/run/ik4ln3"
WB_POLICY="${IK4LN3_RUN}/writeblock.enabled"     # "1" = blocking active, "0" = off
WB_WHITELIST="${IK4LN3_RUN}/protected-disks"     # one whole-disk kernel name per line
WB_ALLOWDIR="${IK4LN3_RUN}/allow"                # flag files: disks manually set RW

# disk_of DEV -> the top-level whole-disk kernel name(s) backing DEV,
# traversing partitions, dm-crypt (LUKS) and LVM down to the physical disk.
# Accepts /dev/sdb1, sdb1, /dev/mapper/x, UUID=..., /dev/nvme0n1p2, etc.
disk_of() {
    local d="$1"
    case "$d" in
        UUID=*|LABEL=*|PARTUUID=*) d="$(blkid -l -o device -t "$d" 2>/dev/null)";;
    esac
    [ -n "$d" ] || return 0
    case "$d" in /dev/*) : ;; *) d="/dev/$d" ;; esac
    # lsblk --inverse walks DOWN to the physical parents; keep TYPE=disk rows.
    lsblk -snpo NAME,TYPE "$d" 2>/dev/null | awk '$2=="disk"{print $1}' \
        | sed 's#^/dev/##' | sort -u
}

# all_disks -> every whole disk currently present (kernel names, no /dev/).
all_disks() {
    lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | sed 's#^/dev/##'
}

# partitions_of DISK -> the disk plus each of its partition kernel names.
partitions_of() {
    local disk="$1"; disk="${disk#/dev/}"
    lsblk -nrpo NAME "/dev/$disk" 2>/dev/null | sed 's#^/dev/##'
}

# compute_protected -> whole disks carrying the running OS. Printed one per
# line. This is the whitelist that is NEVER write-blocked.
compute_protected() {
    {
        # mounts the system genuinely depends on — queried ONE AT A TIME,
        # because `findmnt a b c` returns nothing and fails if any of a/b/c
        # is not a mountpoint (e.g. no separate /boot or /var).
        local t
        for t in / /boot /boot/efi /boot/firmware /usr /var; do
            findmnt -nro SOURCE "$t" 2>/dev/null
        done
        # active swap devices
        awk 'NR>1 && $1 ~ /^\/dev\// {print $1}' /proc/swaps 2>/dev/null
    } 2>/dev/null | sort -u | while read -r src; do
        [ -n "$src" ] || continue
        disk_of "$src"
    done | sort -u
}

# is_protected DISK -> 0 if DISK is on the established whitelist.
is_protected() {
    [ -f "$WB_WHITELIST" ] && grep -qxF "${1#/dev/}" "$WB_WHITELIST"
}

# policy_on -> 0 if global write-blocking is currently active.
policy_on() {
    [ -f "$WB_POLICY" ] && [ "$(cat "$WB_POLICY" 2>/dev/null)" = "1" ]
}

# dev_is_ro DEV -> 0 if the block device is currently read-only. Reads
# /sys/block/<disk>/ro, which is world-readable (blockdev --getro needs
# root), so `status` works for a normal user. Falls back to blockdev.
dev_is_ro() {
    local d="${1#/dev/}"
    local f="/sys/block/${d}/ro"
    if [ -r "$f" ]; then
        [ "$(cat "$f" 2>/dev/null)" = "1" ]
    else
        [ "$(blockdev --getro "/dev/$d" 2>/dev/null)" = "1" ]
    fi
}

# set_ro / set_rw DISK -> mark the whole disk AND all its partitions.
# Marking only a partition is unsafe (the OS may still write via the parent),
# so we always act on the parent disk and every partition together.
set_ro() {
    local disk="${1#/dev/}" p
    # HARD SAFETY, defence in depth: never mark a disk read-only if it
    # currently carries the running system (root/boot/swap chain). Computed
    # LIVE here, so even a stale/empty whitelist or a direct `block <disk>`
    # can never freeze the OS disk.
    if compute_protected | grep -qxF "$disk"; then
        return 0
    fi
    for p in $(partitions_of "$disk"); do blockdev --setro "/dev/$p" 2>/dev/null || true; done
}
set_rw() {
    local p
    for p in $(partitions_of "$1"); do blockdev --setrw "/dev/$p" 2>/dev/null || true; done
}
