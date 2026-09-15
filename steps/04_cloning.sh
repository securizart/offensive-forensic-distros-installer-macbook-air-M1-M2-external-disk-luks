#!/bin/bash
# steps/04_cloning.sh
STEP_ID="04"
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
PART_EFI="$(os_state_get "$TARGET_OS" PART_EFI)"
PART_BOOT="$(os_state_get "$TARGET_OS" PART_BOOT)"
PART_ROOT="$(os_state_get "$TARGET_OS" PART_ROOT)"
VG="$(os_vg_name "$TARGET_OS")"
CRYPTNAME="$(os_crypt_name "$TARGET_OS")"
MNT="$(os_mountpoint "$TARGET_OS")"

if [ -z "$TARGET_OS" ] || [ -z "$PART_ROOT" ]; then
    log_error "Missing OS/disk/partition data (run steps 00, 02 and 03 first)."
    exit 1
fi

# The single most important check in the whole flow: this step literally
# copies "/" onto the external disk. Verify here, right before touching
# anything, that what's booted really is the correct base.
verify_source_base "$TARGET_OS"

echo "$(t step04_title "$(t "os_${TARGET_OS}_name")")"
echo "$(t step04_intro)"
echo

[ -e "/dev/mapper/${CRYPTNAME}" ] || run_cmd "luksOpen" cryptsetup open "${TARGET_DISK}${PART_ROOT}" "$CRYPTNAME"

mkdir -p /part "$MNT"

echo "$(t step04_rsync_boot)"
run_cmd "mount boot" mount "${TARGET_DISK}${PART_BOOT}" "$MNT"
run_cmd "rsync boot" rsync -axHAWXS --numeric-ids --info=progress2 /boot/ "$MNT"
rm -Rf "${MNT}/boot/efi/"*
run_cmd "umount" umount "$MNT"

echo "$(t step04_rsync_efi)"
run_cmd "mount efi" mount "${TARGET_DISK}${PART_EFI}" "$MNT"
run_cmd "rsync efi" rsync -axHAWXS --numeric-ids --info=progress2 /boot/efi/ "$MNT"
run_cmd "umount" umount "$MNT"

echo "$(t step04_rsync_root)"
run_cmd "mount root" mount "/dev/mapper/${VG}-root" "$MNT"
run_cmd "rsync root" rsync -axHAWXS --numeric-ids --info=progress2 / "$MNT" --exclude=/part
rm -Rf "${MNT}/boot/"*
run_cmd "umount" umount "$MNT"

run_cmd "mount root" mount "/dev/mapper/${VG}-root" "$MNT"
run_cmd "mount boot" mount "${TARGET_DISK}${PART_BOOT}" "${MNT}/boot"
run_cmd "mount efi" mount "${TARGET_DISK}${PART_EFI}" "${MNT}/boot/efi"

echo "$(t step04_fstab_crypttab)"
# blkid -o export (KEY=value, unquoted) is the format util-linux itself
# recommends for scripting, and is stable across versions (unlike the
# default quoted "full" text format) — confirmed unchanged on Debian
# Trixie's util-linux too, but this is more robust regardless.
resolve_uuid() {
    blkid -o export "$1" 2>/dev/null | sed -n 's/^UUID=//p'
}
a="$(resolve_uuid "${TARGET_DISK}${PART_EFI}")"
b="$(resolve_uuid "${TARGET_DISK}${PART_BOOT}")"
c="$(resolve_uuid "${TARGET_DISK}${PART_ROOT}")"

if [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ]; then
    log_error "Could not resolve all the UUIDs for ${TARGET_DISK}${PART_EFI}/${PART_BOOT}/${PART_ROOT}."
    exit 1
fi

cat > "${MNT}/etc/fstab" <<EOF
/dev/mapper/${VG}-root	/		ext4 	errors=remount-ro 0       1
UUID=$b /boot	ext4	defaults        0       2
UUID=$a  /boot/efi       vfat    umask=0077      0       1
/dev/mapper/${VG}-swap none            swap    sw              0       0
EOF

echo "${CRYPTNAME} UUID=$c  none luks,discard,x-initrd.attach" > "${MNT}/etc/crypttab"

mark_os_step_done "$TARGET_OS" "$STEP_ID"

# Also save progress on the cloned disk, so the installer remembers it
# when it boots from there later on (see docs) — AFTER marking this
# step done, so the copy already has step 04 recorded (previously
# synced before the mark, so booting from the clone always showed step
# 04 as still pending there).
sync_state_to_mount "$MNT"

echo
echo "$(t step04_done_reboot)"
echo "$(t generic_rebooting)"
sleep 5
reboot
