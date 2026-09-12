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

echo "$(t step03_luks_format)"
run_cmd "luksFormat" cryptsetup luksFormat --type=luks1 "${TARGET_DISK}${PART_ROOT}"
echo "$(t step03_luks_open)"
run_cmd "luksOpen" cryptsetup open "${TARGET_DISK}${PART_ROOT}" "$CRYPTNAME"

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
