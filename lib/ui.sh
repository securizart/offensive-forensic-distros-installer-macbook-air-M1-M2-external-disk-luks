#!/bin/bash
# lib/ui.sh
# UI layer: uses whiptail if available (and there's a real tty), and
# otherwise falls back automatically to plain-text read/echo prompts.
#
# IMPORTANT — dependency order: whiptail is NOT guaranteed to be present
# on the minimal Debian/Asahi base. Step 00 (and this menu itself) run
# BEFORE step 01 installs the rest of the packages, so this does a
# minimal "bootstrap": if whiptail is missing, it just detects that (it
# doesn't try to install anything on the spot) and falls back to text
# mode without breaking the installer.
#
# Must be loaded after lib/i18n.sh (uses t()).

UI_MODE=""
UI_H=20
UI_W=70

ui_detect_mode() {
    [ -n "$UI_MODE" ] && return
    if command -v whiptail >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ]; then
        UI_MODE="whiptail"
    else
        UI_MODE="text"
    fi
}

# ui_ensure_whiptail: detects whether whiptail is available RIGHT NOW and
# sets UI_MODE accordingly. It no longer tries to install it on the fly:
# in the first steps (00, 01) it doesn't exist on the system yet, so text
# mode is used naturally there; as soon as step 01 installs the
# "whiptail" package along with the rest of the base packages, the
# following steps detect it on their own and switch to dialogs.
ui_ensure_whiptail() {
    ui_detect_mode
    if [ "$UI_MODE" = "whiptail" ]; then
        log_info "whiptail available, using graphical terminal menus." 2>/dev/null || true
    else
        log_info "whiptail not available yet, using plain text mode." 2>/dev/null || true
    fi
}

# ui_msgbox "title" "text"
ui_msgbox() {
    local title="$1" text="$2"
    ui_detect_mode
    if [ "$UI_MODE" = "whiptail" ]; then
        whiptail --title "$title" --msgbox "$text" "$UI_H" "$UI_W"
    else
        echo "== $title =="
        echo "$text"
        pause_enter
    fi
}

# ui_yesno "title" "text" -> 0 = yes, 1 = no
ui_yesno() {
    local title="$1" text="$2"
    ui_detect_mode
    if [ "$UI_MODE" = "whiptail" ]; then
        whiptail --title "$title" --yesno "$text" "$UI_H" "$UI_W"
        return $?
    else
        local resp
        read -r -p "$text $(t prompt_yes_no) " resp
        case "$resp" in
            [Yy][Ee][Ss]|[Yy]) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

# ui_inputbox "title" "text" ["default_value"] -> prints the value to stdout
ui_inputbox() {
    local title="$1" text="$2" default="${3:-}"
    ui_detect_mode
    if [ "$UI_MODE" = "whiptail" ]; then
        whiptail --title "$title" --inputbox "$text" "$UI_H" "$UI_W" "$default" 3>&1 1>&2 2>&3
    else
        local val
        read -r -p "$text " val
        echo "${val:-$default}"
    fi
}

# ui_passwordbox "title" "text" -> prints the value to stdout (no echo on screen)
ui_passwordbox() {
    local title="$1" text="$2"
    ui_detect_mode
    if [ "$UI_MODE" = "whiptail" ]; then
        whiptail --title "$title" --passwordbox "$text" "$UI_H" "$UI_W" 3>&1 1>&2 2>&3
    else
        local val
        read -r -s -p "$text " val
        echo >&2
        echo "$val"
    fi
}

# ui_menu "title" "text" tag1 item1 tag2 item2 ... -> prints the chosen tag
ui_menu() {
    local title="$1" text="$2"; shift 2
    ui_detect_mode
    if [ "$UI_MODE" = "whiptail" ]; then
        local n=$(( ($#/2) + 2 ))
        [ "$n" -gt 20 ] && n=20
        whiptail --title "$title" --menu "$text" "$UI_H" "$UI_W" "$n" "$@" 3>&1 1>&2 2>&3
    else
        echo "== $title ==" >&2
        echo "$text" >&2
        local i=1 tag item tags=()
        while [ "$#" -gt 0 ]; do
            tag="$1"; item="$2"; shift 2
            tags+=("$tag")
            printf '  %d) %-8s %s\n' "$i" "$tag" "$item" >&2
            i=$((i+1))
        done
        local choice
        read -r -p "$(t menu_prompt)" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#tags[@]}" ]; then
            echo "${tags[$((choice-1))]}"
        else
            echo ""
        fi
    fi
}
