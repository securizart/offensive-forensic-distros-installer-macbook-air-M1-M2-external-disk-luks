#!/bin/bash
# steps/10_grub_menu_fix.sh
# Final safety net for the GRUB boot menu, only for targets sourced
# from Ubuntu/Asahi (sift, remnux). Runs on the host, right after step
# 09. Nothing between step 07 and here is SUPPOSED to touch
# /etc/default/grub or GRUB's saved-entry state again, but step 09
# installs a large number of packages (SIFT/REMnux's own provisioning),
# and a kernel-related package trigger firing an automatic
# update-grub/grub-install somewhere in that process is a plausible way
# for the menu-visibility settings from step 07 to end up reverted or
# for a stray saved_entry to reappear. Re-asserting everything once
# more here is cheap and idempotent either way.
STEP_ID="10"
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
SOURCE_BASE="$(os_source_base "$TARGET_OS")"

echo "$(t step10_title "$(t "os_${TARGET_OS}_name")")"

if [ "$SOURCE_BASE" != "ubuntu" ]; then
    log_info "Target '$TARGET_OS' isn't sourced from Ubuntu/Asahi (source base: $SOURCE_BASE); this step only applies to Ubuntu-sourced targets. Skipping."
    echo "$(t step10_skip_non_ubuntu)"
    mark_os_step_done "$TARGET_OS" "$STEP_ID"
    exit 0
fi

echo "$(t step10_intro)"

grub_set_var GRUB_TIMEOUT_STYLE menu
grub_set_var GRUB_TIMEOUT 10
grub_set_var GRUB_RECORDFAIL_TIMEOUT 10
# Kept disabled (true), not enabled: os-prober's guessed entry for a
# LUKS-rooted sibling base doesn't pick up that base's real boot
# parameters and fails to boot — confirmed on real hardware. Step 07b's
# own 45_iac_cross_<base> script is the reliable path there instead.
grub_set_var GRUB_DISABLE_OS_PROBER true
grub_set_var GRUB_DEFAULT 0
run_cmd "clear saved GRUB default (again)" grub-editenv /boot/grub/grubenv unset saved_entry
run_cmd "update-grub host (again)" update-grub

mark_os_step_done "$TARGET_OS" "$STEP_ID"
echo
echo "$(t step10_done)"
