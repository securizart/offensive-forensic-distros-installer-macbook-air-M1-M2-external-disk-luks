#!/bin/bash
# steps/03_formatting.sh
STEP_ID="03"
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

if [ -z "$TARGET_OS" ] || [ -z "$PART_ROOT" ] || [ ! -b "${TARGET_DISK}${PART_EFI}" ]; then
    log_error "Missing OS/disk/partition data (run steps 00 and 02 for this OS first)."
    echo "Missing OS/disk/partition data. Run steps 00 and 02 first."
    exit 1
fi

verify_source_base "$TARGET_OS"

VG="$(os_vg_name "$TARGET_OS")"
CRYPTNAME="$(os_crypt_name "$TARGET_OS")"
ROOT_LABEL="$(os_root_label "$TARGET_OS")"
BOOT_LABEL="$(os_boot_label "$TARGET_OS")"
EFI_LABEL="$(os_efi_label "$TARGET_OS")"

echo "$(t step03_title "$(t "os_${TARGET_OS}_name")")"
echo "$(t step03_intro)"
echo

confirm_destructive "${TARGET_DISK}${PART_ROOT} (LUKS, OS: $(t "os_${TARGET_OS}_name"))"

# This wipes and recreates the LUKS/LVM layout: any recorded progress
# for steps 04-09 refers to data that's about to be destroyed. Reset it
# so the menu doesn't keep showing them "done" from a previous attempt
# — which previously let the flow jump straight to 07b/08/09 without
# 04-07 ever having touched the fresh clone.
for LATER_STEP in 04 05 06 07 07b 08 09; do
    os_reset_step "$TARGET_OS" "$LATER_STEP"
done

echo "$(t step03_checking_mounts)"
# These partitions are about to be formatted (and, in step 04, cloned
# into) — if any of them is currently mounted, mkfs/luksFormat fails
# with "device is mounted/busy". Common causes: a previous run got
# partway through, or the desktop's automount service (udisks2/gvfs)
# mounted a partition it recognized on this external disk.
for PART_DEV in "${TARGET_DISK}${PART_EFI}" "${TARGET_DISK}${PART_BOOT}" "${TARGET_DISK}${PART_ROOT}"; do
    MOUNT_POINT="$(findmnt -no TARGET "$PART_DEV" 2>/dev/null || true)"
    if [ -n "$MOUNT_POINT" ]; then
        log_warn "$PART_DEV is mounted at $MOUNT_POINT; unmounting before formatting."
        echo "$(t step03_unmounting "$PART_DEV" "$MOUNT_POINT")"
        umount "$PART_DEV" || {
            log_error "Could not unmount $PART_DEV (mounted at $MOUNT_POINT)."
            echo "$(t step03_unmount_failed "$PART_DEV")"
            exit 1
        }
    fi
done

# A previous partial run may have left this OS's LUKS mapping open
# (with its LVs active, possibly mounted, on top of it). Tear that
# down cleanly so luksFormat doesn't fail with "device is busy".
if [ -e "/dev/mapper/${CRYPTNAME}" ]; then
    log_warn "LUKS mapping '${CRYPTNAME}' is already open (leftover from a previous run); closing it before reformatting."
    echo "$(t step03_closing_leftover_luks "$CRYPTNAME")"
    for LV_PATH in "/dev/mapper/${VG}-swap" "/dev/mapper/${VG}-root"; do
        [ -e "$LV_PATH" ] || continue
        LV_MOUNT="$(findmnt -no TARGET "$LV_PATH" 2>/dev/null || true)"
        if [ -n "$LV_MOUNT" ]; then
            log_warn "Unmounting leftover $LV_PATH from $LV_MOUNT"
            umount "$LV_PATH" || true
        fi
    done
    vgchange -an "$VG" 2>/dev/null || true
    cryptsetup close "${CRYPTNAME}" || {
        log_error "Could not close leftover LUKS mapping '${CRYPTNAME}'. Close it manually and retry."
        echo "$(t step03_luks_close_failed "$CRYPTNAME")"
        exit 1
    }
fi

echo "$(t step03_luks_format)"
run_cmd "luksFormat" cryptsetup luksFormat --type=luks1 "${TARGET_DISK}${PART_ROOT}"
echo "$(t step03_luks_open)"
run_cmd "luksOpen" cryptsetup open "${TARGET_DISK}${PART_ROOT}" "$CRYPTNAME"
echo "$(t generic_waiting_device_settle)"
sleep 5

echo "$(t step03_mkfs)"
run_cmd "mkfs.vfat EFI" mkfs.vfat -F 16 -n "$EFI_LABEL" "${TARGET_DISK}${PART_EFI}"
run_cmd "mkfs.ext4 boot" mkfs.ext4 -L "$BOOT_LABEL" "${TARGET_DISK}${PART_BOOT}"

echo "$(t step03_lvm_create "$VG")"
run_cmd "pvcreate" pvcreate "/dev/mapper/${CRYPTNAME}"
run_cmd "vgcreate" vgcreate "$VG" "/dev/mapper/${CRYPTNAME}"
run_cmd "lvcreate swap" lvcreate -L 32G -n swap "$VG"
run_cmd "lvcreate root" lvcreate -l 99%FREE -n root "$VG"
run_cmd "mkswap" mkswap "/dev/mapper/${VG}-swap"
run_cmd "mkfs.ext4 root" mkfs.ext4 -L "$ROOT_LABEL" "/dev/mapper/${VG}-root"

mark_os_step_done "$TARGET_OS" "$STEP_ID"
echo
echo "$(t step03_done_reboot)"
echo "$(t generic_rebooting)"
sleep 5
reboot
