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
    sift)
        # Clone with SIFT Workstation (SANS) baked in: official arm64
        # support confirmed on Ubuntu 22.04/24.04 by the project itself
        # (teamdfir/sift-saltstack), with a known caveat: some packages
        # are amd64-only and are automatically skipped on arm64.
        # Choosing this target already IS the decision to have SIFT
        # here — no separate confirmation prompt (see
        # docs/OPERATING_SYSTEMS.md for the two-independent-targets
        # model).
        if dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii'; then
            log_info "ubuntu-desktop is already installed, skipping."
            echo "$(t step09_ubuntu_desktop_already)"
        else
            echo "$(t step09_installing "ubuntu-desktop")"
            run_cmd "apt update" apt update
            run_cmd "ubuntu-desktop" apt-get install -y ubuntu-desktop
        fi

        echo "$(t step09_ubuntu_sift_notice)"
        install_cast_arm64 || {
            log_error "Could not install 'cast'. Skipping SIFT installation."
            echo "$(t step09_ubuntu_cast_install_failed)"
        }
        if command -v cast >/dev/null 2>&1; then
            # SIFT's own SaltStack states (teamdfir/sift-saltstack) add
            # several apt repositories (gift, sift, openjdk, dotnet,
            # Microsoft) as part of provisioning. On real hardware this
            # ended up upgrading unrelated packages (mesa, gnome-shell)
            # to versions expecting a newer kernel than the one left in
            # place by step 08, breaking the graphical session on
            # reboot — the same class of mismatch documented in
            # docs/TROUBLESHOOTING.md, but triggered from inside SIFT's
            # own provisioning this time, not from a command we run
            # ourselves. Hold just the kernel/GPU-userspace family
            # around it (not everything installed — that blocked
            # SIFT's own dependency resolution on real hardware).
            echo "$(t step09_holding_packages)"
            HELD_PKGS="$(hold_graphics_kernel_packages)"
            echo "$(t step09_ubuntu_installing_sift)"
            # A handful of failed salt states here is expected on arm64
            # (SIFT's own docs mention amd64-only packages get skipped)
            # and cast/salt-call exits non-zero even for a handful of
            # failures out of hundreds of states. Checked in an `if`
            # here so that non-zero doesn't fire the script's global
            # ERR trap and abort the step outright — which previously
            # skipped unhold_packages below, leaving the kernel/GPU
            # hold in place indefinitely even though the bulk of the
            # install had actually succeeded.
            if run_cmd "cast install sift" cast install teamdfir/sift-saltstack; then
                echo "$(t step09_ubuntu_sift_done)"
            else
                log_warn "cast install reported some failed states (see the log above for exactly which). This can happen with SIFT's own arm64 package list without making the install unusable — check the failed package name(s) if something you need seems to be missing."
                echo "$(t step09_ubuntu_sift_partial)"
            fi
            unhold_packages "$HELD_PKGS"
            echo "$(t step09_unholding_packages)"
        fi
        ;;

    remnux)
        # Clone with REMnux baked in: vendored from the forensics
        # satellite project (forensics/remnux/), still flagged there as
        # "in doubt" for full arm64 support (~88% of remnux.addon
        # states succeed; a handful of known-broken binaries get
        # cleaned up and, where possible, replaced with native
        # alternatives). Same "target IS the choice" reasoning as sift
        # above — no confirmation prompt.
        if dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii'; then
            log_info "ubuntu-desktop is already installed, skipping."
            echo "$(t step09_ubuntu_desktop_already)"
        else
            echo "$(t step09_installing "ubuntu-desktop")"
            run_cmd "apt update" apt update
            run_cmd "ubuntu-desktop" apt-get install -y ubuntu-desktop
        fi

        echo "$(t step09_ubuntu_remnux_notice)"

        # REMnux's own upstream convention ships a "remnux"/"malware"
        # demo account; this vendored flow doesn't create one on its
        # own (see forensics/remnux/install.sh), so we do it here.
        echo "$(t step09_ubuntu_remnux_user_notice)"
        if id remnux >/dev/null 2>&1; then
            log_warn "User 'remnux' already exists, skipping creation."
        else
            run_cmd "useradd remnux" useradd -m -c 'REMnux (SANS demo account)' -s /bin/bash -G sudo remnux
        fi
        run_cmd "set remnux password" bash -c "echo 'remnux:malware' | chpasswd"
        log_warn "'remnux' account set with the public demo password 'malware' (see README.md's Risks section)."
        echo "$(t step09_ubuntu_remnux_user_warning)"

        # forensics/remnux/install.sh orchestrates its own SaltStack run
        # (remnux.addon), which — like SIFT's states above — can add
        # repositories and pull in package upgrades as a side effect.
        # Same guard, same reasoning: see docs/TROUBLESHOOTING.md.
        echo "$(t step09_holding_packages)"
        HELD_PKGS="$(hold_graphics_kernel_packages)"
        install_remnux_arm64 || echo "$(t step09_ubuntu_remnux_failed)"
        unhold_packages "$HELD_PKGS"
        echo "$(t step09_unholding_packages)"
        echo "$(t step09_ubuntu_remnux_done)"
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
