#!/bin/bash
# steps/06_grub_finalize.sh
# Based on the original "finalize grub" script. Runs INSIDE the chroot
# opened by step 05 (path: /base_inst_kali_installer/steps/06_...).
STEP_ID="06"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/lib/state.sh"
source "${BASE_DIR}/lib/i18n.sh"
[ -z "${IAC_LANG:-}" ] && IAC_LANG="$(i18n_detect_default_lang)"
i18n_load "$IAC_LANG"
source "${BASE_DIR}/lib/common.sh"
CURRENT_STEP_ID="$STEP_ID"
init_step_log "$STEP_ID"
require_root

TARGET_OS="$(state_get ACTIVE_OS)"

echo "$(t step06_title "$(t "os_${TARGET_OS}_name")")"
echo "$(t step06_intro)"
echo

echo "$(t step06_update_initramfs)"
run_cmd "update-initramfs" update-initramfs -c -k all

echo "$(t step06_grub_install)"
echo 'grub-efi-arm64 grub2/update_nvram boolean false' | debconf-set-selections
echo 'grub-efi-arm64 grub2/force_efi_extra_removable boolean true' | debconf-set-selections
run_cmd "dpkg-reconfigure grub-efi-arm64" dpkg-reconfigure -fnoninteractive grub-efi-arm64
run_cmd "grub-install removable" grub-install --removable /boot/efi

if [ -f /etc/default/grub.iac ]; then
    run_cmd "restore grub" cp /etc/default/grub.iac /etc/default/grub
fi
run_cmd "update-grub" update-grub
run_cmd "update-initramfs" update-initramfs -c -k all

mark_os_step_done "$TARGET_OS" "$STEP_ID"
echo
echo "$(t step06_done)"
