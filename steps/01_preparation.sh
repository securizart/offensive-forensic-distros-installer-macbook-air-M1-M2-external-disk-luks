#!/bin/bash
# steps/01_preparation.sh
# Based on the original base-preparation script. Now without the network
# part (see 01a).
STEP_ID="01"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/lib/state.sh"
source "${BASE_DIR}/lib/i18n.sh"
[ -z "${IAC_LANG:-}" ] && IAC_LANG="$(i18n_detect_default_lang)"
i18n_load "$IAC_LANG"
source "${BASE_DIR}/lib/common.sh"
CURRENT_STEP_ID="$STEP_ID"
init_step_log "$STEP_ID"
require_root

echo "$(t step01_title)"
echo "$(t step01_intro)"
echo

echo "$(t step01_change_root_pass)"
passwd

echo
echo "$(t step01_installing_packages)"
run_cmd "apt update" apt update
run_cmd "apt upgrade" apt upgrade -y
run_cmd "apt install base packages" apt install -y \
    initramfs-tools pciutils wpasupplicant tcpdump vim tmux vlan ntpdate \
    parted curl wget grub-efi-arm64 mtr-tiny dbus ca-certificates sudo \
    openssh-client mtools gdisk cryptsetup cryptsetup-initramfs lvm2 \
    os-prober rsync dosfstools gnupg1 gnupg2 locales keyboard-configuration \
    console-data whiptail
run_cmd "apt update" apt update
run_cmd "apt upgrade" apt upgrade -y

echo
echo "$(t step01_locale_keyboard)"
if [ -f /base_inst_kali/preparation/keyboard ]; then
    run_cmd "copy keyboard" cp /base_inst_kali/preparation/keyboard /etc/default/keyboard
else
    log_warn "/base_inst_kali/preparation/keyboard does not exist, skipping the copy."
fi
if [ -f /base_inst_kali/preparation/locale ]; then
    run_cmd "copy locale" cp /base_inst_kali/preparation/locale /etc/default/locale
else
    log_warn "/base_inst_kali/preparation/locale does not exist, skipping the copy."
fi
dpkg-reconfigure locales
dpkg-reconfigure keyboard-configuration
dpkg-reconfigure console-data
command -v setupcon >/dev/null 2>&1 && setupcon
run_cmd "update-initramfs" update-initramfs -c -k all

echo
echo "$(t step01_create_user)"
if id iac >/dev/null 2>&1; then
    log_warn "User 'iac' already exists, skipping creation."
else
    run_cmd "useradd iac" useradd -m -c 'Ignacio Arduengo Cuesta' -s /bin/bash iac
fi
echo "$(t step01_ask_user_password)"
passwd iac

if [ -f /base_inst_kali/preparation/sudoers ]; then
    run_cmd "copy sudoers" cp /base_inst_kali/preparation/sudoers /etc/sudoers
    echo "$(t step01_sudoers_copied)"
else
    log_warn "/base_inst_kali/preparation/sudoers does not exist, skipping (review 'iac' user's sudo permissions manually)."
fi

echo
echo "$(t step01_done)"
mark_step_done "$STEP_ID"
