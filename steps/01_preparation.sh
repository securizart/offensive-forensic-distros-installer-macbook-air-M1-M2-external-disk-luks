#!/bin/bash
# steps/01_preparation.sh
# Based on the original base-preparation script. Now without the network
# part (see 01a).
STEP_ID="01"
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

echo "$(t step01_title)"
echo "$(t step01_intro)"
echo

# Ubuntu/Asahi already has its own root password and login from its own
# install; only Debian/Asahi (the base Kali/Parrot convert from) needs
# this installer to set them. Resolved the same way step 00 does
# (BOOTED_BASE in state, falling back to a live detection).
BOOTED_BASE="$(state_get BOOTED_BASE)"
[ -z "$BOOTED_BASE" ] && BOOTED_BASE="$(detect_booted_base)"

if [ "$BOOTED_BASE" = "ubuntu" ]; then
    log_info "Booted base is Ubuntu/Asahi: skipping the root password reset (this base already has its own)."
    echo "$(t step01_ubuntu_skip_root_pass)"
else
    echo "$(t step01_change_root_pass)"
    passwd
fi

echo
echo "$(t step01_installing_packages)"
run_cmd "apt update" apt update
if [ "$BOOTED_BASE" = "ubuntu" ]; then
    # Ubuntu/Asahi already manages its own kernel/firmware updates via its
    # own channel (the ubuntu-asahi metapackage, mesa/gnome snaps, m1n1).
    # A blanket `apt upgrade -y` here forces a full-system dist-upgrade
    # (hundreds of packages) that isn't needed for this installer's
    # purposes, and can pull in a kernel package hit by an active,
    # confirmed Ubuntu bug (Launchpad #2148348): 7.0.x kernel maintainer
    # scripts call `run-parts` with two hook directories at once, which
    # fails with "run-parts: missing operand" on noble's run-parts and
    # leaves dpkg in a half-configured state. See
    # docs/TROUBLESHOOTING.md for the symptom and how to recover if it
    # already happened. We only install what we actually need here;
    # any broader system upgrade is left to the user, on their own
    # schedule, outside this installer.
    log_info "Booted base is Ubuntu/Asahi: skipping the blanket 'apt upgrade -y' (see docs/TROUBLESHOOTING.md)."
    echo "$(t step01_ubuntu_skip_upgrade)"
else
    run_cmd "apt upgrade" apt upgrade -y
fi
run_cmd "apt install base packages" apt install -y \
    initramfs-tools pciutils wpasupplicant tcpdump vim tmux vlan ntpdate \
    parted curl wget grub-efi-arm64 mtr-tiny dbus ca-certificates sudo \
    openssh-client mtools gdisk cryptsetup cryptsetup-initramfs lvm2 \
    os-prober rsync dosfstools gnupg1 gnupg2 locales keyboard-configuration \
    console-data whiptail
run_cmd "apt update" apt update
if [ "$BOOTED_BASE" != "ubuntu" ]; then
    run_cmd "apt upgrade" apt upgrade -y
fi

echo
echo "$(t step01_locale_keyboard)"
if [ -f /base_inst_kali/preparation/keyboard ]; then
    run_cmd "copy keyboard" cp /base_inst_kali/preparation/keyboard /etc/default/keyboard
    KB_XKBLAYOUT="$(grep -oP '^XKBLAYOUT=\K"?[^"[:space:]]+' /etc/default/keyboard 2>/dev/null | tr -d '"' || true)"
else
    log_warn "/base_inst_kali/preparation/keyboard does not exist, skipping the copy."
    KB_XKBLAYOUT=""
fi
if [ -f /base_inst_kali/preparation/locale ]; then
    run_cmd "copy locale" cp /base_inst_kali/preparation/locale /etc/default/locale
    KB_LANG="$(grep -oP '^LANG=\K"?[^"[:space:]]+' /etc/default/locale 2>/dev/null | tr -d '"' || true)"
else
    log_warn "/base_inst_kali/preparation/locale does not exist, skipping the copy."
    KB_LANG=""
fi

# Ask directly instead of relying on `dpkg-reconfigure`'s own
# interactive dialog: debconf's Dialog frontend checks whether stdout
# is a real terminal, and init_step_log's `exec > >(tee ...)` (for
# per-step logging) means it isn't — debconf then silently falls back
# to noninteractive and just keeps whatever was already set (Ubuntu/
# Asahi's own "us" default), without ever actually asking. whiptail
# itself is unaffected (it talks to /dev/tty directly), so we ask here
# with it and write the files ourselves. Whatever gets set here is
# what step 04 clones as-is, and what step 07's GRUB keymap and step
# 06's initramfs keymap are derived from later — so this is also what
# ends up being used for the LUKS passphrase prompt at boot.
[ -z "$KB_XKBLAYOUT" ] && KB_XKBLAYOUT="us"
[ -z "$KB_LANG" ] && KB_LANG="en_US.UTF-8"
KB_XKBLAYOUT="$(ui_inputbox "$(t step01_kb_layout_title)" "$(t step01_kb_layout_prompt)" "$KB_XKBLAYOUT")"
KB_LANG="$(ui_inputbox "$(t step01_kb_locale_title)" "$(t step01_kb_locale_prompt)" "$KB_LANG")"

cat > /etc/default/keyboard <<KBEOF
XKBMODEL="pc105"
XKBLAYOUT="${KB_XKBLAYOUT}"
XKBVARIANT=""
XKBOPTIONS=""
KBEOF
echo "LANG=${KB_LANG}" > /etc/default/locale

run_cmd "locale-gen" locale-gen "$KB_LANG"
run_cmd "update-locale" update-locale "LANG=${KB_LANG}"
run_cmd "dpkg-reconfigure keyboard-configuration (noninteractive)" dpkg-reconfigure -f noninteractive keyboard-configuration
command -v setupcon >/dev/null 2>&1 && setupcon
echo "$(t step01_kb_locale_done "$KB_XKBLAYOUT" "$KB_LANG")"
run_cmd "update-initramfs" update-initramfs -c -k all

echo
if [ "$BOOTED_BASE" = "ubuntu" ]; then
    log_info "Booted base is Ubuntu/Asahi: skipping 'iac' user creation and password prompt (this base already has its own login)."
    echo "$(t step01_ubuntu_skip_iac)"
else
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
fi

echo
echo "$(t step01_done)"
mark_step_done "$STEP_ID"
