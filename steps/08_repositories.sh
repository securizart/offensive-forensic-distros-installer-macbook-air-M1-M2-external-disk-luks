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

case "$TARGET_OS" in
    kali)
        echo "$(t step08_adding_keys)"
        run_cmd "kali key" bash -c 'wget -q -O - https://archive.kali.org/archive-key.asc | apt-key add -'
        if [ -f /base_inst_kali/preparation/kali-archive-keyring_2025.1_all.deb ]; then
            run_cmd "kali keyring" dpkg -i /base_inst_kali/preparation/kali-archive-keyring_2025.1_all.deb
        else
            log_warn "The Kali keyring .deb doesn't exist in /base_inst_kali/preparation/, download it manually if the package fails."
        fi

        echo "$(t step08_adding_repos)"
        echo 'deb https://http.kali.org/kali kali-rolling main non-free contrib' > /etc/apt/sources.list.d/kali.list
        {
            echo 'Package: *'
            echo 'Pin: release a=kali-rolling'
            echo 'Pin-Priority: 50'
        } > /etc/apt/preferences.d/kali.pref

        run_cmd "apt update" apt update
        apt upgrade --fix-missing -y || true
        apt install -f -y || true
        apt --fix-broken install -y || true
        run_cmd "dist-upgrade kali" apt dist-upgrade -y -t kali-rolling
        ;;

    parrot)
        echo "$(t step08_adding_keys)"
        mkdir -p /etc/apt/keyrings
        run_cmd "parrot key" bash -c 'wget -q -O - https://deb.parrot.sh/parrot/misc/parrotsec.gpg | gpg --dearmor -o /etc/apt/keyrings/parrot.gpg'

        echo "$(t step08_adding_repos)"
        cat > /etc/apt/sources.list.d/parrot.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/parrot.gpg] https://deb.parrot.sh/parrot lts main contrib non-free
deb [signed-by=/etc/apt/keyrings/parrot.gpg] https://deb.parrot.sh/parrot lts-updates main contrib non-free
deb [signed-by=/etc/apt/keyrings/parrot.gpg] https://deb.parrot.sh/parrot lts-security main contrib non-free
EOF
        {
            echo 'Package: *'
            echo 'Pin: release a=lts'
            echo 'Pin-Priority: 50'
        } > /etc/apt/preferences.d/parrot.pref

        run_cmd "apt update" apt update
        apt upgrade --fix-missing -y || true
        apt install -f -y || true
        apt --fix-broken install -y || true
        run_cmd "dist-upgrade parrot" apt dist-upgrade -y -t lts
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

mark_os_step_done "$TARGET_OS" "$STEP_ID"
echo
echo "$(t step08_done_reboot)"
echo "$(t generic_rebooting)"
sleep 5
reboot
