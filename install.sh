#!/bin/bash
# install.sh — Main menu
#
# Single entry point. Survives the process's reboots: if added to root's
# .bashrc (see docs/), it reopens on its own after each reboot and shows
# which step you were on.
#
# The external disk can host SEVERAL operating systems (Kali, Parrot,
# ...). That's why steps are split into two groups:
#   - HOST_STEPS (00, 01, 01a): done ONCE, independent of which OS you'll
#     clone afterwards.
#   - OS_STEPS (02..09): repeated FOR EACH operating system you install
#     on the disk. Their progress is saved separately for each one (see
#     lib/state.sh, the os_* functions).

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state.sh
source "${BASE_DIR}/lib/state.sh"
# shellcheck source=lib/os_catalog.sh
source "${BASE_DIR}/lib/os_catalog.sh"
# shellcheck source=lib/i18n.sh
source "${BASE_DIR}/lib/i18n.sh"

state_init
IAC_LANG="$(i18n_detect_default_lang)"
i18n_load "$IAC_LANG"

# shellcheck source=lib/common.sh
source "${BASE_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Ordered step definitions
# ---------------------------------------------------------------------------
HOST_STEPS=(00 01 01a)
OS_STEPS=(02 03 04 05 06 07 07b 08 09 10)

declare -A STEP_FILE=(
    [00]="steps/00_check_prereq.sh"
    [01]="steps/01_preparation.sh"
    [01a]="steps/01a_network.sh"
    [02]="steps/02_partitions.sh"
    [03]="steps/03_formatting.sh"
    [04]="steps/04_cloning.sh"
    [05]="steps/05_chroot_prep.sh"
    [06]="steps/06_grub_finalize.sh"
    [07]="steps/07_grub_merge.sh"
    [07b]="steps/07b_grub_cross_merge.sh"
    [08]="steps/08_repositories.sh"
    [09]="steps/09_package_installation.sh"
    [10]="steps/10_grub_menu_fix.sh"
)
declare -A STEP_TITLE_KEY=(
    [00]="step00_title" [01]="step01_title" [01a]="step01a_title"
    [02]="step02_title_short" [03]="step03_title_short" [04]="step04_title_short"
    [05]="step05_title_short" [06]="step06_title_short" [07]="step07_title_short"
    [07b]="step07b_title_short"
    [08]="step08_title_short" [09]="step09_title_short"
    [10]="step10_title_short"
)
# OS steps that DON'T require the previous one to be "done" to run
# without a warning (06 runs manually inside the chroot opened by 05, so
# its progress mark never reaches the state the host sees; 07b is
# genuinely optional — it cross-links the sibling internal base's boot
# menu, and skipping it never blocks 08/09).
NO_GATE_STEPS=("06" "07b")

is_no_gate() {
    local id="$1" x
    for x in "${NO_GATE_STEPS[@]}"; do [ "$x" = "$id" ] && return 0; done
    return 1
}

# --- host step status (00/01/01a), global progress --------------------------
compute_host_status_label() {
    local id="$1" idx="$2"
    local st
    st="$(step_status "$id")"
    if [ "$st" = "done" ]; then t menu_status_done; return; fi
    if [ "$st" = "failed" ]; then t menu_status_failed; return; fi
    local i prev_all_done=1
    for ((i=0; i<idx; i++)); do
        [ "$(step_status "${HOST_STEPS[$i]}")" != "done" ] && { prev_all_done=0; break; }
    done
    [ "$prev_all_done" -eq 1 ] && t menu_status_next || t menu_status_locked
}

# --- per-OS step status (02..09), namespaced progress ------------------------
compute_os_status_label() {
    local os="$1" id="$2" idx="$3"
    local st
    st="$(os_step_status "$os" "$id")"
    if [ "$st" = "done" ]; then t menu_status_done; return; fi
    if [ "$st" = "failed" ]; then t menu_status_failed; return; fi
    if is_no_gate "$id"; then t menu_status_pending; return; fi
    local i prev_all_done=1
    for ((i=0; i<idx; i++)); do
        local prev_id="${OS_STEPS[$i]}"
        is_no_gate "$prev_id" && continue
        [ "$(os_step_status "$os" "$prev_id")" != "done" ] && { prev_all_done=0; break; }
    done
    [ "$prev_all_done" -eq 1 ] && t menu_status_next || t menu_status_locked
}

os_progress_summary() {
    # "3/8 steps" for OS $1
    local os="$1" done_count=0 id
    for id in "${OS_STEPS[@]}"; do
        [ "$(os_step_status "$os" "$id")" = "done" ] && done_count=$((done_count+1))
    done
    echo "${done_count}/${#OS_STEPS[@]}"
}

print_header_text() {
    local disk active_os
    disk="$(state_get TARGET_DISK)"
    active_os="$(state_get ACTIVE_OS)"
    local header="$(t menu_title)"
    if [ -n "$disk" ]; then
        header="${header}
$(t menu_current_disk "$disk")"
    else
        header="${header}
$(t menu_current_disk_unset)"
    fi
    if [ -n "$active_os" ]; then
        header="${header}
$(t menu_active_os "$(t "os_${active_os}_name") ($(os_progress_summary "$active_os"))")"
    else
        header="${header}
$(t menu_active_os_unset)"
    fi
    echo "$header"
}

build_menu_args() {
    # Fills the global MENU_ARGS array with tag/item pairs for ui_menu.
    MENU_ARGS=()
    local i id booted_base
    booted_base="$(state_get BOOTED_BASE)"
    for ((i=0; i<${#HOST_STEPS[@]}; i++)); do
        id="${HOST_STEPS[$i]}"
        # 01a (WiFi) always self-skips on Ubuntu/Asahi (see its own
        # note) — no point listing it there, it never does anything.
        [ "$id" = "01a" ] && [ "$booted_base" = "ubuntu" ] && continue
        MENU_ARGS+=("$id" "$(t "${STEP_TITLE_KEY[$id]}") [$(compute_host_status_label "$id" "$i")]")
    done

    MENU_ARGS+=("OS" "$(t menu_option_os)")

    local active_os
    active_os="$(state_get ACTIVE_OS)"
    if [ -n "$active_os" ]; then
        for ((i=0; i<${#OS_STEPS[@]}; i++)); do
            id="${OS_STEPS[$i]}"
            MENU_ARGS+=("$id" "$(t "${STEP_TITLE_KEY[$id]}") [$(compute_os_status_label "$active_os" "$id" "$i")]")
        done
    fi

    MENU_ARGS+=("LOGS" "$(t menu_option_logs)")
    MENU_ARGS+=("EXIT" "$(t menu_option_exit)")
}

manage_os() {
    # Menu to pick/create the "active operating system". Only lists the
    # OSes whose required source base matches what's currently booted
    # (BOOTED_BASE, saved by step 00 via detect_booted_base) — e.g. only
    # Kali/Parrot show up when booted into Debian/Asahi, only Ubuntu when
    # booted into Ubuntu/Asahi. Falls back to listing every catalogued OS
    # if the booted base couldn't be resolved. Each entry shows its
    # progress if it was already started.
    local booted_base candidates
    booted_base="$(state_get BOOTED_BASE)"
    if [ -n "$booted_base" ]; then
        candidates="$(os_targets_for_base "$booted_base")"
    else
        candidates="$(printf '%s\n' "${SUPPORTED_OS[@]}")"
    fi

    local args=() os label
    while IFS= read -r os; do
        [ -z "$os" ] && continue
        label="$(t "os_${os}_name")"
        if [[ ",$(os_list_get)," == *",${os},"* ]]; then
            label="${label} ($(os_progress_summary "$os"))"
        else
            label="${label} — $(t menu_os_not_started)"
        fi
        args+=("$os" "$label")
    done <<< "$candidates"

    if [ "${#args[@]}" -eq 0 ]; then
        ui_msgbox "$(t menu_os_title)" "$(t menu_os_none_for_base)"
        return
    fi

    local choice
    choice="$(ui_menu "$(t menu_os_title)" "$(t menu_os_prompt)" "${args[@]}")"
    case "$choice" in
        "") return ;;
        *)
            state_set ACTIVE_OS "$choice"
            ui_msgbox "$(t menu_os_title)" "$(t menu_os_switched "$(t "os_${choice}_name")")"
            ;;
    esac
}

run_step() {
    local id="$1"
    local file="${BASE_DIR}/${STEP_FILE[$id]}"
    if [ ! -f "$file" ]; then
        echo "[$id] script not found: $file" >&2
        pause_enter
        return
    fi
    CURRENT_STEP_ID="$id" IAC_LANG="$IAC_LANG" bash "$file"
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo
        echo "$(t step_failed_console "$id")"
        pause_enter
    fi
}

main_menu_loop() {
    local choice
    while true; do
        clear
        build_menu_args
        choice="$(ui_menu "$(t menu_title)" "$(print_header_text)" "${MENU_ARGS[@]}")"
        case "$choice" in
            "") echo "$(t menu_exit_bye)"; break ;;
            OS) manage_os ;;
            LOGS) ui_msgbox "$(t menu_title)" "$(t menu_logs_path "$LOG_DIR")" ;;
            EXIT) echo "$(t menu_exit_bye)"; break ;;
            *)
                if [ -z "$(state_get ACTIVE_OS)" ]; then
                    local is_os_step=0 sid
                    for sid in "${OS_STEPS[@]}"; do [ "$sid" = "$choice" ] && is_os_step=1; done
                    if [ "$is_os_step" -eq 1 ]; then
                        ui_msgbox "$(t menu_title)" "$(t menu_os_required_first)"
                        continue
                    fi
                fi
                run_step "$choice"
                ;;
        esac
    done
}

main_menu_loop
