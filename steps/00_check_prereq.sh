#!/bin/bash
# steps/00_check_prereq.sh
STEP_ID="00"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/state.sh
source "${BASE_DIR}/lib/state.sh"
# shellcheck source=../lib/os_catalog.sh
source "${BASE_DIR}/lib/os_catalog.sh"
# shellcheck source=../lib/i18n.sh
source "${BASE_DIR}/lib/i18n.sh"
[ -z "${IAC_LANG:-}" ] && IAC_LANG="$(i18n_detect_default_lang)"
i18n_load "$IAC_LANG"
# shellcheck source=../lib/common.sh
source "${BASE_DIR}/lib/common.sh"
CURRENT_STEP_ID="$STEP_ID"
init_step_log "$STEP_ID"
require_root

echo "$(t step00_title)"
echo "$(t step00_intro)"
echo

# --- architecture --------------------------------------------------------
echo "$(t step00_checking_arch)"
ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
    log_error "$(t step00_arch_fail "$ARCH")"
    echo "$(t step00_arch_fail "$ARCH")"
    exit 1
fi
log_info "Architecture OK: $ARCH"

# --- existing Asahi/Debian base -------------------------------------------
echo "$(t step00_checking_asahi)"
if ! dpkg -l 2>/dev/null | grep -qE '^ii\s+asahi-'; then
    if ! confirm_yes_no "$(t step00_asahi_not_found_warn)

$(t step00_confirm_continue_anyway)"; then
        log_warn "$(t log_aborted_by_user "$STEP_ID")"
        echo "$(t aborted_by_user)"
        exit 1
    fi
else
    log_info "asahi-* packages detected."
fi

# --- target disk selection -----------------------------------------------
ROOT_SRC_DISK=""
if command -v findmnt >/dev/null 2>&1; then
    ROOT_SRC_DEV="$(findmnt -no SOURCE / 2>/dev/null || true)"
    # /dev/mapper/xxx-root or /dev/nvme0n1p2 -> try to resolve the physical disk
    ROOT_SRC_DISK="$(lsblk -no PKNAME "$ROOT_SRC_DEV" 2>/dev/null | head -n1 || true)"
fi

# Build the list of candidate disks (excluding the current root disk,
# which is assumed to be the internal NVMe with macOS/Debian).
DISK_MENU_ARGS=()
while IFS= read -r line; do
    name="$(awk '{print $1}' <<<"$line")"
    [ "$name" = "$ROOT_SRC_DISK" ] && continue
    [ -z "$name" ] && continue
    rest="$(cut -d' ' -f2- <<<"$line")"
    DISK_MENU_ARGS+=("/dev/$name" "$rest")
done < <(lsblk -d -n -o NAME,SIZE,MODEL,TRAN)

TARGET_DISK=""
if [ "${#DISK_MENU_ARGS[@]}" -gt 0 ]; then
    TARGET_DISK="$(ui_menu "$(t step00_title)" "$(t step00_lsblk_hint)" "${DISK_MENU_ARGS[@]}")"
fi

while true; do
    if [ -z "$TARGET_DISK" ]; then
        TARGET_DISK="$(ui_inputbox "$(t step00_title)" "$(t step00_ask_target_disk)")"
    fi
    if [ ! -b "$TARGET_DISK" ]; then
        ui_msgbox "$(t step00_title)" "$(t step00_target_disk_invalid "$TARGET_DISK")"
        TARGET_DISK=""
        continue
    fi
    TARGET_BASENAME="$(basename "$TARGET_DISK")"
    if [ -n "$ROOT_SRC_DISK" ] && [ "$TARGET_BASENAME" = "$ROOT_SRC_DISK" ]; then
        ui_msgbox "$(t step00_title)" "$(t step00_target_disk_is_internal_warn "$TARGET_DISK")"
        TARGET_DISK=""
        continue
    fi
    break
done

state_set TARGET_DISK "$TARGET_DISK"
log_info "$(t step00_target_disk_confirmed "$TARGET_DISK")"
echo "$(t step00_target_disk_confirmed "$TARGET_DISK")"

# --- booted base, saved for the "Operating systems" menu to filter on ---
BOOTED_BASE="$(detect_booted_base)"
if [ -n "$BOOTED_BASE" ]; then
    state_set BOOTED_BASE "$BOOTED_BASE"
    log_info "Booted base detected: $BOOTED_BASE"
else
    log_warn "Could not resolve the booted base from /etc/os-release; the 'Operating systems' menu will show every catalogued OS without filtering."
    state_set BOOTED_BASE ""
fi

echo
echo "$(t step00_done)"
mark_step_done "$STEP_ID"
