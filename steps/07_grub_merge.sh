#!/bin/bash
# steps/07_grub_merge.sh
# Based on the original "finalize filesystem" script. Runs OUTSIDE the
# chroot (after leaving it with `exit`), with the active OS's disk still
# mounted.
#
# NOTE on several operating systems on the same disk (2026-09-15,
# v1.3.0): every OS's ROOT partition lives inside its own LUKS
# container (os_crypt_name), but its BOOT partition does NOT. Because
# of that, `update-grub`'s os-prober pass can NEVER recover a
# previously-merged OS's entry here -- os-prober needs to mount the
# root filesystem to identify a system, and it can't look inside a
# closed LUKS container. Relying on os-prober for that (as this script
# used to, hoping for a generic chainload entry) meant that every time
# you added a THIRD operating system, the previous one's native entry
# silently disappeared -- switching back to it and re-running this step
# only fixed that one at the expense of the one you'd just added.
#
# Fix: instead of trusting os-prober to rediscover other systems, merge
# the "10_linux" GRUB fragment from EVERY OS in OS_LIST explicitly, not
# just $TARGET_OS. Each OS's (unencrypted) boot partition is mounted
# directly for this -- no LUKS passphrase needed, since grub.cfg lives
# on boot, not on the encrypted root. The currently active OS's boot
# partition is already mounted (from steps 04-06), so only the OTHER,
# previously-installed OSes need a temporary mount.
STEP_ID="07"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/lib/state.sh"
source "${BASE_DIR}/lib/os_catalog.sh"
source "${BASE_DIR}/lib/i18n.sh"
[ -z "${IAC_LANG:-}" ] && IAC_LANG="$(i18n_detect_default_lang)"
i18n_load "$IAC_LANG"
source "${BASE_DIR}/lib/common.sh"
CURRENT_STEP_ID="$STEP_ID"
init_step_log "$STEP_ID"
require_root

TARGET_OS="$(state_get ACTIVE_OS)"
TARGET_DISK="$(state_get TARGET_DISK)"
MNT="$(os_mountpoint "$TARGET_OS")"

# Cosmetic fix (2026-09-15, v1.3.0): step 06 runs inside the chroot,
# where STATE_DIR ("/var/lib/base_inst_kali") resolves to the EXTERNAL
# disk's own filesystem, not the host's -- so its "done" mark never
# reaches the host's state.conf that the menu reads from (this is why
# NO_GATE_STEPS=("06") exists in install.sh: it isn't a real block, just
# a display gap). Propagate it here, with the disk still mounted at
# $MNT from steps 04-06, so the menu stops showing step 6 as pending.
if [ -f "${MNT}/var/lib/base_inst_kali/state.conf" ]; then
    six_status="$(grep -E "^OS_${TARGET_OS}_STEP_06_STATUS=" "${MNT}/var/lib/base_inst_kali/state.conf" 2>/dev/null | tail -n1 | cut -d'=' -f2-)"
    six_ts="$(grep -E "^OS_${TARGET_OS}_STEP_06_TS=" "${MNT}/var/lib/base_inst_kali/state.conf" 2>/dev/null | tail -n1 | cut -d'=' -f2-)"
    if [ "$six_status" = "done" ]; then
        state_set "OS_${TARGET_OS}_STEP_06_STATUS" "done"
        [ -n "$six_ts" ] && state_set "OS_${TARGET_OS}_STEP_06_TS" "$six_ts"
        log_info "Propagated step 06's 'done' mark for '$TARGET_OS' from the chroot's own state.conf to the host's."
    fi
fi

echo "$(t step07_title "$(t "os_${TARGET_OS}_name")")"
echo "$(t step07_intro)"
echo

if [ ! -f "${MNT}/boot/grub/grub.cfg" ]; then
    log_error "${MNT}/boot/grub/grub.cfg does not exist. Is ${MNT} still mounted? Repeat step 05/06."
    exit 1
fi

if [ -f /base_inst_kali/preparation/grub ]; then
    run_cmd "copy host grub" cp /base_inst_kali/preparation/grub /etc/default/grub
fi
if [ -f /base_inst_kali/preparation/modules.txt ]; then
    run_cmd "copy host modules" cp /base_inst_kali/preparation/modules.txt /etc/initramfs-tools/modules
fi
run_cmd "update-initramfs host" update-initramfs -c -k all
run_cmd "update-grub host" update-grub

echo "$(t step07_merging)"
c1=$(awk '/END \/etc\/grub.d\/30_os-prober/{ print NR }' /boot/grub/grub.cfg)
d1=$(wc -l < /boot/grub/grub.cfg)

if [ -z "$c1" ]; then
    log_error "Could not locate the expected 30_os-prober marker in grub.cfg. Review manually before continuing."
    exit 1
fi

MERGED="$(mktemp)"
sed -n "1,${c1}p" /boot/grub/grub.cfg > "$MERGED"

# Merge the 10_linux block from every known OS, current one included --
# see the note at the top of this file for why we no longer rely on
# os-prober for this.
IFS=',' read -ra ALL_OS <<< "$(state_get OS_LIST)"
for os in "${ALL_OS[@]}"; do
    [ -z "$os" ] && continue

    TMPMNT=""
    if [ "$os" = "$TARGET_OS" ]; then
        # Already mounted by steps 04-06, still in place.
        GRUBCFG="${MNT}/boot/grub/grub.cfg"
    else
        obootpart="$(os_state_get "$os" PART_BOOT)"
        if [ -z "$obootpart" ]; then
            log_warn "No PART_BOOT recorded for '$os', skipping its GRUB entry."
            continue
        fi
        TMPMNT="/part/grubmerge_${os}"
        mkdir -p "$TMPMNT"
        if ! mount -o ro "${TARGET_DISK}${obootpart}" "$TMPMNT"; then
            log_warn "Could not mount ${TARGET_DISK}${obootpart} (boot partition for '$os'), skipping its GRUB entry."
            rmdir "$TMPMNT" 2>/dev/null || true
            continue
        fi
        GRUBCFG="${TMPMNT}/grub/grub.cfg"
    fi

    if [ ! -f "$GRUBCFG" ]; then
        log_warn "$GRUBCFG does not exist, skipping '$os' GRUB entry."
    else
        a1=$(awk '/BEGIN \/etc\/grub.d\/10_linux/{ print NR }' "$GRUBCFG")
        b1=$(awk '/END \/etc\/grub.d\/10_linux/{ print NR }' "$GRUBCFG")
        if [ -z "$a1" ] || [ -z "$b1" ]; then
            log_warn "Could not locate the 10_linux markers for '$os' in $GRUBCFG, skipping its GRUB entry."
        else
            a2=$((a1 + 1))
            b2=$((b1 - 1))
            log_info "Merging '$os' GRUB entry (markers a1=$a1 b1=$b1)"
            sed -n "${a2},${b2}p" "$GRUBCFG" >> "$MERGED"
        fi
    fi

    if [ -n "$TMPMNT" ]; then
        umount "$TMPMNT" || log_warn "Could not unmount $TMPMNT cleanly."
        rmdir "$TMPMNT" 2>/dev/null || true
    fi
done

sed -n "$((c1+1)),${d1}p" /boot/grub/grub.cfg >> "$MERGED"

BACKUP="/boot/grub/grub.orig.$(date '+%Y%m%d_%H%M%S')"
run_cmd "backup grub.cfg" cp /boot/grub/grub.cfg "$BACKUP"
echo "$(t step07_backup_orig "$BACKUP")"
mv "$MERGED" /boot/grub/grub.cfg

mark_os_step_done "$TARGET_OS" "$STEP_ID"

# The external disk is still mounted at $MNT at this point: take the
# chance to leave the already-updated state there — AFTER marking this
# step done, so the copy the newly-booted external system reads already
# has step 07 recorded (previously synced before the mark, so it always
# looked pending once booted from there).
sync_state_to_mount "$MNT"

echo
echo "$(t step07_done)"
echo "$(t step07_reboot_notice "$(t "os_${TARGET_OS}_name")")"
echo "$(t generic_rebooting)"
sleep 5
reboot
