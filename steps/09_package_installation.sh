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

case "$TARGET_OS" in
    kali)
        echo "$(t step09_installing "kali-linux-default, kali-desktop-gnome, kali-linux-large, kali-linux-arm")"
        run_cmd "kali-linux-default" apt-get install -y kali-linux-default -t kali-rolling
        run_cmd "kali-desktop-gnome" apt-get install -y kali-desktop-gnome -t kali-rolling
        run_cmd "kali-linux-large" apt-get install -y kali-linux-large -t kali-rolling
        run_cmd "kali-linux-arm" apt-get install -y kali-linux-arm -t kali-rolling
        ;;
    parrot)
        echo "$(t step09_installing "parrot-core, parrot-tools-full")"
        run_cmd "parrot-core" apt-get install -y parrot-core -t lts
        run_cmd "parrot-tools-full" apt-get install -y parrot-tools-full -t lts
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
