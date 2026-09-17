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

# The LUKS passphrase prompt actually seen at boot comes from the
# initramfs's own cryptsetup hook (crypttab-driven, since /boot itself
# isn't encrypted — GRUB just loads the kernel/initrd normally and
# never needs to decrypt anything itself). That hook's keymap is baked
# in at build time from THIS chroot's own /etc/default/keyboard, which
# at this point is whatever got cloned from the host (possibly "us" on
# Ubuntu/Asahi, see docs/TROUBLESHOOTING.md). Apply the real layout
# here, before the first update-initramfs below, if a preparation file
# is available (it gets cloned in with the rest of "/" in step 04, so
# the same absolute path resolves correctly inside this chroot too).
if [ -f /base_inst_kali/preparation/keyboard ]; then
    run_cmd "copy keyboard (chroot)" cp /base_inst_kali/preparation/keyboard /etc/default/keyboard
    dpkg-reconfigure keyboard-configuration >/dev/null 2>&1 || log_warn "dpkg-reconfigure keyboard-configuration failed inside the chroot; the initramfs keymap may still reflect the previous layout."
    command -v setupcon >/dev/null 2>&1 && setupcon 2>/dev/null
else
    log_warn "/base_inst_kali/preparation/keyboard does not exist in the chroot; the cloned system's own /etc/default/keyboard will be used as-is for the initramfs keymap."
fi

# System-wide locale (LANG/language) — distinct from the keyboard
# layout above: getting the keymap right doesn't change what language
# GNOME itself displays. Applied here from preparation/locale if
# present (same file already used on Debian in step 01; on
# Ubuntu/Asahi it never ran there, see that step's own note). Also
# installs the matching language-pack-gnome-<code> so the desktop UI
# itself is translated, not just LC_* categories.
if [ -f /base_inst_kali/preparation/locale ]; then
    run_cmd "copy locale (chroot)" cp /base_inst_kali/preparation/locale /etc/default/locale
    DESIRED_LANG="$(grep -oP '^LANG=\K"?[^"[:space:]]+' /etc/default/locale 2>/dev/null | tr -d '"' || true)"
    if [ -n "$DESIRED_LANG" ]; then
        run_cmd "locale-gen" locale-gen "$DESIRED_LANG"
        run_cmd "update-locale" update-locale "LANG=${DESIRED_LANG}"
        LANG_PACK_CODE="${DESIRED_LANG%%_*}"
        if dpkg -l "language-pack-gnome-${LANG_PACK_CODE}" 2>/dev/null | grep -q '^ii'; then
            log_info "language-pack-gnome-${LANG_PACK_CODE} already installed, skipping."
        else
            run_cmd "language pack" apt-get install -y "language-pack-gnome-${LANG_PACK_CODE}" || log_warn "Could not install language-pack-gnome-${LANG_PACK_CODE}; the GNOME UI may stay partly in English even with LANG=${DESIRED_LANG}."
        fi
    else
        log_warn "Could not find a LANG= line in preparation/locale; skipping locale-gen/update-locale."
    fi
else
    log_warn "/base_inst_kali/preparation/locale does not exist in the chroot; the cloned system's own /etc/default/locale will be used as-is."
fi

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
