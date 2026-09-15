#!/bin/bash
# steps/09_package_installation.sh
# Installs the chosen operating system's ($TARGET_OS) metapackages.
STEP_ID="09"
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

echo "$(t step09_title "$(t "os_${TARGET_OS}_name")")"
echo "$(t step09_intro "$(t "os_${TARGET_OS}_name")")"
echo

# --- WiFi interface: re-detect + pin to a stable name ----------------------
# Step 08 ends with a reboot, and this adapter's kernel-assigned name has
# been observed to CHANGE between boots on this hardware even without any
# OS change (wld0 one boot, wlp1s0f0 the next, for the SAME physical MAC) —
# so whatever step 08 detected can already be stale by the time this step
# runs. Re-detect fresh, drop any interfaces.d stanza left over from a
# different name, and pin this adapter's MAC to a fixed name via udev so
# future boots stop drifting.
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
        WIFI_MAC="$(cat "/sys/class/net/${WIFI_IFACE}/address" 2>/dev/null || true)"
        IFACES_D="/etc/network/interfaces.d"
        mkdir -p "$IFACES_D"

        # Drop any other interfaces.d file that points at this same
        # wpa_supplicant.conf but under a DIFFERENT interface name — a
        # leftover from a previous boot's naming, now orphaned.
        for f in "$IFACES_D"/*; do
            [ -f "$f" ] || continue
            [ "$(basename "$f")" = "$WIFI_IFACE" ] && continue
            if grep -qi "wpa-conf ${WPA_CONF}" "$f" 2>/dev/null; then
                rm -f "$f"
            fi
        done

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
        log_info "$(t step09_iface_redetected "$WIFI_IFACE")"
        echo "$(t step09_iface_redetected "$WIFI_IFACE")"

        # Pin this MAC to a fixed name (wlan0) so it stops drifting on
        # future boots. Takes effect from the NEXT boot onward — we don't
        # attempt a live rename here, that's riskier mid-setup than it's
        # worth.
        if [ -n "$WIFI_MAC" ] && [ "$WIFI_IFACE" != "wlan0" ]; then
            mkdir -p /etc/udev/rules.d
            echo "SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"${WIFI_MAC}\", NAME=\"wlan0\"" \
                > /etc/udev/rules.d/70-persistent-wifi.rules
            log_info "$(t step09_iface_pinned "$WIFI_MAC")"
            echo "$(t step09_iface_pinned "$WIFI_MAC")"
        fi
    fi
fi

case "$TARGET_OS" in
    kali)
        echo "$(t step09_installing "kali-linux-default, kali-desktop-gnome, kali-linux-large")"
        run_cmd "kali-linux-default" apt-get install -y kali-linux-default -t kali-rolling
        run_cmd "kali-desktop-gnome" apt-get install -y kali-desktop-gnome -t kali-rolling
        run_cmd "kali-linux-large" apt-get install -y kali-linux-large -t kali-rolling
        # kali-linux-arm intentionally NOT installed: it's Kali's
        # metapackage for their ARM SBC images (Raspberry Pi, Rockchip,
        # Allwinner boards) — it depends on SBC-specific
        # firmware/tools (rkflashtool, sunxi-tools, dphys-swapfile,
        # firmware-realtek, etc.) that don't apply to — and in several
        # cases aren't even installable on — a MacBook Air M1/M2.
        ;;
    parrot)
        # NOTE (2026-09-15, v1.3.0): parrot-core and parrot-tools-full
        # alone never pull in a desktop environment -- Parrot ships that
        # separately as "parrot-interface" (which depends on one of
        # parrot-desktop-kde/-mate/-xfce/... as apt alternatives).
        # Confirmed with Parrot's own release notes: since Parrot OS 7.0
        # "echo" the default DE is KDE Plasma 6 (it was MATE up to
        # 6.x), so pin that alternative explicitly instead of leaving it
        # to apt's dependency resolution. Also "lts" -> "echo", see
        # steps/08_repositories.sh for the matching sources.list/pin
        # change and the reasoning.
        echo "$(t step09_installing "parrot-core, parrot-desktop-kde, parrot-interface, parrot-tools-full")"
        run_cmd "parrot-core" apt-get install -y parrot-core -t echo
        run_cmd "parrot-desktop-kde" apt-get install -y parrot-desktop-kde -t echo
        run_cmd "parrot-interface" apt-get install -y parrot-interface -t echo
        run_cmd "parrot-tools-full" apt-get install -y parrot-tools-full -t echo
        ;;
    ubuntu)
        # 1) Desktop environment, idempotently: the Ubuntu Asahi image
        #    usually already ships with a desktop, but if the clone came
        #    from a server/minimal base, we complete it here.
        if dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii'; then
            log_info "ubuntu-desktop is already installed, skipping."
            echo "$(t step09_ubuntu_desktop_already)"
        else
            echo "$(t step09_installing "ubuntu-desktop")"
            run_cmd "apt update" apt update
            run_cmd "ubuntu-desktop" apt-get install -y ubuntu-desktop
        fi

        # 2) SIFT Workstation (SANS), optional: official arm64 support
        #    confirmed on Ubuntu 22.04/24.04 by the project itself
        #    (teamdfir/sift-saltstack), with a known caveat: some
        #    packages are amd64-only and are automatically skipped on
        #    arm64.
        echo
        if confirm_yes_no "$(t step09_ubuntu_ask_sift)"; then
            echo "$(t step09_ubuntu_sift_notice)"
            install_cast_arm64 || {
                log_error "Could not install 'cast'. Skipping SIFT installation."
                echo "$(t step09_ubuntu_cast_install_failed)"
            }
            if command -v cast >/dev/null 2>&1; then
                echo "$(t step09_ubuntu_installing_sift)"
                run_cmd "cast install sift" cast install teamdfir/sift-saltstack
                echo "$(t step09_ubuntu_sift_done)"
            fi
        else
            log_info "SIFT installation skipped by the user."
            echo "$(t step09_ubuntu_sift_skipped)"
        fi

        # 3) REMnux, optional: vendored from the forensics satellite
        #    project (forensics/remnux/), still flagged there as "in
        #    doubt" for full arm64 support (~88% of remnux.addon states
        #    succeed; a handful of known-broken binaries get cleaned up
        #    and, where possible, replaced with native alternatives).
        echo
        if confirm_yes_no "$(t step09_ubuntu_ask_remnux)"; then
            echo "$(t step09_ubuntu_remnux_notice)"
            install_remnux_arm64 || echo "$(t step09_ubuntu_remnux_failed)"
            echo "$(t step09_ubuntu_remnux_done)"
        else
            log_info "REMnux installation skipped by the user."
            echo "$(t step09_ubuntu_remnux_skipped)"
        fi
        ;;
    *)
        log_error "Unknown operating system: $TARGET_OS"
        exit 1
        ;;
esac

mark_os_step_done "$TARGET_OS" "$STEP_ID"
echo
echo "$(t step09_all_done "$(t "os_${TARGET_OS}_name")")"
echo "$(t step09_done_reboot)"
echo "$(t generic_rebooting)"
sleep 5
reboot
