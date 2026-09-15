#!/bin/bash
# steps/08_repositories.sh
# Adds the chosen operating system's ($TARGET_OS) repositories on top of
# the cloned Debian/Asahi base. IMPORTANT: this runs already booted
# INSIDE the cloned system (pick that entry from the GRUB menu after the
# reboot in step 07), not on the original Debian/Asahi system.
STEP_ID="08"
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
if [ -z "$TARGET_OS" ]; then
    log_error "Could not determine the active OS (ACTIVE_OS is empty in this system's state)."
    exit 1
fi

echo "$(t step08_title "$(t "os_${TARGET_OS}_name")")"
echo "$(t step08_intro "$(t "os_${TARGET_OS}_name")")"
echo

# The WiFi interface config (wpa_supplicant.conf + interfaces.d stanza)
# was cloned from the host in step 04 with the HOST kernel's interface
# name (e.g. wlan0 on Debian/Asahi). This OS's own kernel can name the
# same physical adapter differently (observed: wld0 on Kali) — re-detect
# it here and (re)write the interfaces.d stanza under the CURRENT name,
# rather than trusting the cloned one. The wpa_supplicant.conf itself is
# interface-agnostic (just SSID/psk), so it doesn't need regenerating.
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
if [ -f "$WPA_CONF" ]; then
    WIFI_IFACE=""
    for ifc in /sys/class/net/*; do
        if [ -d "${ifc}/wireless" ]; then
            WIFI_IFACE="$(basename "$ifc")"
            break
        fi
    done
    if [ -n "$WIFI_IFACE" ]; then
        IFACES_D="/etc/network/interfaces.d"
        mkdir -p "$IFACES_D"
        {
            echo "auto ${WIFI_IFACE}"
            echo "iface ${WIFI_IFACE} inet dhcp"
            echo "    wpa-conf ${WPA_CONF}"
        } > "${IFACES_D}/${WIFI_IFACE}"
        IFACES_MAIN="/etc/network/interfaces"
        if [ -f "$IFACES_MAIN" ] && ! grep -q "^source ${IFACES_D}/\*" "$IFACES_MAIN"; then
            echo "source ${IFACES_D}/*" >> "$IFACES_MAIN"
        fi
        ifup "$WIFI_IFACE" 2>/dev/null || true
        log_info "$(t step08_iface_redetected "$WIFI_IFACE")"
        echo "$(t step08_iface_redetected "$WIFI_IFACE")"
    fi
fi

# This is an external/clonable disk's swap — never try to resume from
# hibernation using it (UUID/device numbering isn't guaranteed stable
# across disks or OS installs, and this project has no hibernate use
# case). Set explicitly rather than leaving it to update-initramfs's
# auto-detection, which just warns and defaults to attempting it anyway.
mkdir -p /etc/initramfs-tools/conf.d
echo 'RESUME=none' > /etc/initramfs-tools/conf.d/resume

case "$TARGET_OS" in
    kali)
        echo "$(t step08_adding_keys)"
        mkdir -p /etc/apt/keyrings
        run_cmd "kali key" bash -c 'wget -q -O - https://archive.kali.org/archive-key.asc | gpg --dearmor -o /etc/apt/keyrings/kali-archive.gpg'
        if [ -f /base_inst_kali/preparation/kali-archive-keyring_2025.1_all.deb ]; then
            run_cmd "kali keyring" dpkg -i /base_inst_kali/preparation/kali-archive-keyring_2025.1_all.deb
        else
            log_warn "The Kali keyring .deb doesn't exist in /base_inst_kali/preparation/, download it manually if the package fails."
        fi

        echo "$(t step08_adding_repos)"
        echo 'deb [signed-by=/etc/apt/keyrings/kali-archive.gpg] https://http.kali.org/kali kali-rolling main non-free contrib' > /etc/apt/sources.list.d/kali.list
        {
            echo 'Package: *'
            echo 'Pin: release a=kali-rolling'
            echo 'Pin-Priority: 50'
        } > /etc/apt/preferences.d/kali.pref

        # This project's boot chain is entirely GRUB-based (steps 05-07
        # hand-build/merge grub.cfg on the host's ESP). Kali's arm64
        # kali-rolling can try to pull in systemd-boot/shim-signed as
        # part of a big dist-upgrade and REMOVE grub-efi-arm64 in the
        # process — categorically forbid that instead of discovering it
        # mid-transaction.
        {
            echo 'Package: systemd-boot systemd-boot-tools systemd-boot-efi-arm64-signed shim-signed shim-signed-common shim-unsigned'
            echo 'Pin: release a=kali-rolling'
            echo 'Pin-Priority: -1'
        } > /etc/apt/preferences.d/no-systemd-boot.pref

        run_cmd "apt update" apt update
        apt upgrade --fix-missing -y || true
        apt install -f -y || true
        # --force-overwrite: Debian trixie -> kali-rolling package splits
        # (e.g. rev moved from util-linux to bsdextrautils) can trip
        # dpkg's "trying to overwrite X, which is also in package Y" file
        # conflict during this big a jump; force-overwrite is the
        # standard, documented way through it.
        # Disabling preferences (not -t): kali.pref pins kali-rolling at
        # priority 50 precisely so apt won't touch it without being
        # asked, but that also blocks --fix-broken from resolving a
        # break that needs kali-rolling versions. -t kali-rolling can
        # itself error ("no es válido para APT::Default-Release") if the
        # release/index state is stale mid-repair, so disable pinning
        # for this one call instead of relying on -t matching.
        apt --fix-broken install -y \
            -o Dpkg::Options::="--force-overwrite" \
            -o Dir::Etc::Preferences=/dev/null \
            -o Dir::Etc::PreferencesParts=/dev/null || true
        run_cmd "dist-upgrade kali" apt dist-upgrade -y -t kali-rolling -o Dpkg::Options::="--force-overwrite"
        ;;

    parrot)
        echo "$(t step08_adding_keys)"
        mkdir -p /etc/apt/keyrings
        run_cmd "parrot key" bash -c 'wget -q -O - https://deb.parrot.sh/parrot/misc/parrotsec.gpg | gpg --dearmor -o /etc/apt/keyrings/parrot.gpg'

        # NOTE (2026-09-15, v1.3.0): Parrot renamed its stable/rolling
        # suite from the old "lts" codename to "echo" (Parrot OS 7.x,
        # aligned with Debian "trixie", which is the base this system
        # was cloned from) -- confirmed via parrotsec.org's own mirrors
        # documentation. The old "lts"/"lts-updates"/"lts-security"
        # suites now 404 on deb.parrot.sh. If Parrot renames the suite
        # again in a future release, update the codename here (and the
        # matching -t flags below, plus steps/09_package_installation.sh)
        # accordingly.
        echo "$(t step08_adding_repos)"
        cat > /etc/apt/sources.list.d/parrot.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/parrot.gpg] https://deb.parrot.sh/parrot echo main contrib non-free non-free-firmware
deb [signed-by=/etc/apt/keyrings/parrot.gpg] https://deb.parrot.sh/parrot echo-backports main contrib non-free non-free-firmware
deb [signed-by=/etc/apt/keyrings/parrot.gpg] https://deb.parrot.sh/direct/parrot echo-security main contrib non-free non-free-firmware
EOF
        {
            echo 'Package: *'
            echo 'Pin: release a=echo'
            echo 'Pin-Priority: 50'
        } > /etc/apt/preferences.d/parrot.pref

        run_cmd "apt update" apt update
        apt upgrade --fix-missing -y || true
        apt install -f -y || true
        apt --fix-broken install -y \
            -o Dpkg::Options::="--force-overwrite" \
            -o Dir::Etc::Preferences=/dev/null \
            -o Dir::Etc::PreferencesParts=/dev/null || true
        run_cmd "dist-upgrade parrot" apt dist-upgrade -y -t echo -o Dpkg::Options::="--force-overwrite"
        echo
        echo "$(t step08_parrot_arm_notice)"
        ;;

    ubuntu)
        # No conversion: the clone already IS genuine Ubuntu. We just keep
        # it up to date after step 04's rsync (which might have copied
        # slightly stale package versions if updates happened between the
        # source boot and this point).
        echo "$(t step08_ubuntu_no_repos)"
        run_cmd "apt update" apt update
        run_cmd "apt full-upgrade ubuntu" apt full-upgrade -y
        ;;

    *)
        log_error "Unknown operating system: $TARGET_OS"
        exit 1
        ;;
esac

if [ -f /base_inst_kali/preparation/interfaces ]; then
    run_cmd "copy interfaces" cp /base_inst_kali/preparation/interfaces /etc/network/interfaces
fi

# Refresh this OS's own grub.cfg now that /etc/os-release reflects the
# real distro (Kali/Parrot base-files replaced Debian's during the
# dist-upgrade above), so the menu title stops saying "Debian GNU/Linux".
# This only fixes the title in THIS disk's own grub.cfg though — the one
# actually shown at power-on is the host's merged copy (step 07), which
# still has the pre-conversion snapshot. Re-run step 07 from the host
# afterward to pick up the corrected title there too.
if [ "$TARGET_OS" != "ubuntu" ]; then
    echo "$(t step08_updating_grub_title)"
    run_cmd "update-grub post-conversion" update-grub
    echo "$(t step08_rerun_07_reminder)"
fi

mark_os_step_done "$TARGET_OS" "$STEP_ID"
echo
echo "$(t step08_done_reboot)"
echo "$(t generic_rebooting)"
sleep 5
reboot
