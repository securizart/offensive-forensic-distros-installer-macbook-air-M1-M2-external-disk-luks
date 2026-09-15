#!/bin/bash
# steps/07_grub_merge.sh
# Based on the original "finalize filesystem" script. Runs OUTSIDE the
# chroot (after leaving it with `exit`), with the active OS's disk still
# mounted.
#
# NOTE on several operating systems on the same disk: every time this
# step runs for a new OS, "update-grub" regenerates the host's grub.cfg
# from scratch. If you'd already merged another OS's entry before (e.g.
# Kali) and there's now a well-formed copy of that system on disk (with
# its own fstab), os-prober will very likely detect it automatically and
# add it back (as a generic "chainload" entry, not the native one this
# script builds by hand). The OS being processed RIGHT NOW does get the
# full native entry. Check the boot menu after adding a second OS to
# confirm both entries are still there.
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
MNT="$(os_mountpoint "$TARGET_OS")"

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
a1=$(awk '/BEGIN \/etc\/grub.d\/10_linux/{ print NR }' "${MNT}/boot/grub/grub.cfg")
b1=$(awk '/END \/etc\/grub.d\/10_linux/{ print NR }' "${MNT}/boot/grub/grub.cfg")
c1=$(awk '/END \/etc\/grub.d\/30_os-prober/{ print NR }' /boot/grub/grub.cfg)
d1=$(wc -l < /boot/grub/grub.cfg)

if [ -z "$a1" ] || [ -z "$b1" ] || [ -z "$c1" ]; then
    log_error "Could not locate the expected markers in grub.cfg. Review manually before continuing."
    exit 1
fi

a2=$((a1+1))
b2=$((b1-1))
log_info "Markers ($TARGET_OS): a1=$a1 b1=$b1 c1=$c1 d1=$d1 a2=$a2 b2=$b2"

MERGED="$(mktemp)"
sed -n "1,${c1}p" /boot/grub/grub.cfg > "$MERGED"
sed -n "${a2},${b2}p" "${MNT}/boot/grub/grub.cfg" >> "$MERGED"
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
echo "$(t step07_reboot_notice)"
echo "$(t generic_rebooting)"
sleep 5
reboot
