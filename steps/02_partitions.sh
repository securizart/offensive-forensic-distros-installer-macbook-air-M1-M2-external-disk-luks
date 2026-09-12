#!/bin/bash
# steps/02_partitions.sh
# Partitions the external disk FOR THE ACTIVE OPERATING SYSTEM
# ($TARGET_OS). This is a "per OS" step: if the disk already has
# partitions from another system (e.g. Kali) and you now activate
# Parrot, this script automatically computes the next free partition
# numbers, so it doesn't touch what's already there.
STEP_ID="02"
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
if [ -z "$TARGET_OS" ]; then
    log_error "No active operating system. Pick one first from the menu ('Operating systems' option)."
    echo "No active operating system. Pick one first from the menu."
    exit 1
fi
TARGET_DISK="$(state_get TARGET_DISK)"
if [ -z "$TARGET_DISK" ] || [ ! -b "$TARGET_DISK" ]; then
    log_error "TARGET_DISK is not set or invalid (run step 00 first)."
    echo "TARGET_DISK is not set or invalid. Run step 00 first."
    exit 1
fi

# Blocking check: the currently booted system must be the correct source
# base for $TARGET_OS (e.g. Debian/Asahi for Kali/Parrot, Ubuntu/Asahi for
# Ubuntu). If it doesn't match, stop here before partitioning anything.
verify_source_base "$TARGET_OS"

echo "$(t step02_title "$(t "os_${TARGET_OS}_name")")"
echo "$(t step02_intro "$TARGET_DISK" "$(t "os_${TARGET_OS}_name")")"
echo

# --- compute free partition numbers for this OS ---------------------------
PART_EFI="$(os_state_get "$TARGET_OS" PART_EFI)"
PART_BOOT="$(os_state_get "$TARGET_OS" PART_BOOT)"
PART_ROOT="$(os_state_get "$TARGET_OS" PART_ROOT)"

if [ -z "$PART_EFI" ]; then
    MAXPART="$(sgdisk -p "$TARGET_DISK" 2>/dev/null | awk '/^[[:space:]]*[0-9]+/{print $1}' | sort -n | tail -n1 || true)"
    MAXPART="${MAXPART:-0}"
    PART_EFI=$((MAXPART+1))
    PART_BOOT=$((MAXPART+2))
    PART_ROOT=$((MAXPART+3))
    os_state_set "$TARGET_OS" PART_EFI "$PART_EFI"
    os_state_set "$TARGET_OS" PART_BOOT "$PART_BOOT"
    os_state_set "$TARGET_OS" PART_ROOT "$PART_ROOT"
    log_info "Partitions computed for $TARGET_OS on $TARGET_DISK: EFI=$PART_EFI BOOT=$PART_BOOT ROOT=$PART_ROOT (disk already had up to partition $MAXPART)"
else
    log_info "Reusing previously computed partitions for $TARGET_OS: EFI=$PART_EFI BOOT=$PART_BOOT ROOT=$PART_ROOT"
fi
echo "$(t step02_partitions_planned "$PART_EFI" "$PART_BOOT" "$PART_ROOT")"

confirm_destructive "${TARGET_DISK} (partitions ${PART_EFI}, ${PART_BOOT}, ${PART_ROOT})"

EFI_LABEL="$(os_efi_label "$TARGET_OS")"
BOOT_LABEL="$(os_boot_label "$TARGET_OS")"
ROOT_LABEL="$(os_root_label "$TARGET_OS")"

echo "$(t step02_partitioning "$TARGET_DISK")"
run_cmd "sgdisk new efi" sgdisk --new=${PART_EFI}:0:+512M "$TARGET_DISK"
run_cmd "sgdisk new boot" sgdisk --new=${PART_BOOT}:0:+2G "$TARGET_DISK"
run_cmd "sgdisk new root" sgdisk --new=${PART_ROOT}:0:+87G "$TARGET_DISK"
run_cmd "sgdisk typecode" sgdisk --typecode=${PART_EFI}:ef00 --typecode=${PART_BOOT}:8301 --typecode=${PART_ROOT}:8301 "$TARGET_DISK"
run_cmd "sgdisk change-name" sgdisk --change-name=${PART_EFI}:${EFI_LABEL} --change-name=${PART_BOOT}:${BOOT_LABEL} --change-name=${PART_ROOT}:${ROOT_LABEL} "$TARGET_DISK"
run_cmd "sgdisk hybrid" sgdisk --hybrid ${PART_EFI}:${PART_BOOT}:${PART_ROOT} "$TARGET_DISK"

os_list_add "$TARGET_OS"
mark_os_step_done "$TARGET_OS" "$STEP_ID"
echo
echo "$(t step02_done_reboot)"
echo "$(t generic_rebooting)"
sleep 5
reboot
