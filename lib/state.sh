#!/bin/bash
# lib/state.sh
# Persistent installer state: which step is done, chosen language,
# confirmed target disk, etc. Lives on disk to survive the multiple
# `reboot`s the process makes.
#
# Format: a KEY=value line file (shell-safe, no spaces in the key).

STATE_DIR="/var/lib/base_inst_kali"
STATE_FILE="${STATE_DIR}/state.conf"

state_init() {
    mkdir -p "$STATE_DIR"
    [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
}

# state_get KEY -> value, or "" if it doesn't exist.
# Note: not finding the key is a normal case (that step hasn't been
# reached yet), so this function always returns 0 even without a match;
# otherwise, with `set -e` active in common.sh, querying a key that isn't
# defined yet would abort the calling script.
state_get() {
    local key="$1"
    state_init
    grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- || true
}

# state_set KEY value
state_set() {
    local key="$1" val="$2"
    state_init
    local tmp
    tmp="$(mktemp)"
    grep -vE "^${key}=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    echo "${key}=${val}" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

# --- step-progress helpers ---------------------------------------------

# mark_step_done STEP_ID
mark_step_done() {
    state_set "STEP_${1}_STATUS" "done"
    state_set "STEP_${1}_TS" "$(date '+%Y-%m-%d %H:%M:%S')"
    state_set "LAST_STEP_OK" "$1"
}

# mark_step_failed STEP_ID
mark_step_failed() {
    state_set "STEP_${1}_STATUS" "failed"
    state_set "STEP_${1}_TS" "$(date '+%Y-%m-%d %H:%M:%S')"
}

# step_status STEP_ID -> done|failed|pending
step_status() {
    local v
    v="$(state_get "STEP_${1}_STATUS")"
    echo "${v:-pending}"
}

# --- "per operating system" helpers -------------------------------------
# The external disk can host SEVERAL operating systems (Kali, Parrot,
# ...), each with its own partitions/state. These functions namespace the
# keys with the OS id (e.g. "kali", "parrot") so one system's progress
# never overwrites another's.

# os_state_get OS KEY
os_state_get() { state_get "OS_${1}_${2}"; }
# os_state_set OS KEY value
os_state_set() { state_set "OS_${1}_${2}" "$3"; }

# mark_os_step_done OS STEP_ID
mark_os_step_done() {
    state_set "OS_${1}_STEP_${2}_STATUS" "done"
    state_set "OS_${1}_STEP_${2}_TS" "$(date '+%Y-%m-%d %H:%M:%S')"
}
# mark_os_step_failed OS STEP_ID
mark_os_step_failed() {
    state_set "OS_${1}_STEP_${2}_STATUS" "failed"
    state_set "OS_${1}_STEP_${2}_TS" "$(date '+%Y-%m-%d %H:%M:%S')"
}
# os_step_status OS STEP_ID -> done|failed|pending
os_step_status() {
    local v
    v="$(state_get "OS_${1}_STEP_${2}_STATUS")"
    echo "${v:-pending}"
}

# os_reset_step OS STEP_ID -> clears a step's recorded status/timestamp
# back to "pending" for a given OS. Used when an earlier destructive
# step (e.g. reformatting in step 03) re-runs: later steps that
# operated on the data being replaced shouldn't stay marked "done" from
# a previous attempt, or the menu lets you jump straight to 07b/08/09
# without 05-07 ever having touched the fresh clone.
os_reset_step() {
    state_set "OS_${1}_STEP_${2}_STATUS" ""
    state_set "OS_${1}_STEP_${2}_TS" ""
}

# os_list_add OS -> adds OS to the list of OSes with an install started
# (idempotent; ',' separated).
os_list_add() {
    local os="$1" current
    current="$(state_get OS_LIST)"
    case ",${current}," in
        *",${os},"*) return 0 ;;
    esac
    if [ -z "$current" ]; then
        state_set OS_LIST "$os"
    else
        state_set OS_LIST "${current},${os}"
    fi
}
# os_list_get -> comma-separated list of OSes with an install started
os_list_get() { state_get OS_LIST; }

# --- stable target-disk resolution ---------------------------------------
# The kernel can assign a different /dev/sdX letter to the same physical
# external disk between reboots (common on a Mac with several USB/
# Thunderbolt devices attached, since enumeration order at boot isn't
# guaranteed). get_target_disk() re-resolves the CURRENT /dev/sdX from a
# stable identifier (TARGET_DISK_ID: a /dev/disk/by-id/ symlink, falling
# back to the GPT table's own PTUUID) instead of trusting the plain
# TARGET_DISK value, and self-heals it in state.conf if the disk moved.
#
# Usage: TARGET_DISK="$(get_target_disk)" || { log_error "..."; exit 1; }
get_target_disk() {
    local disk_id disk cached ptuuid
    disk_id="$(state_get TARGET_DISK_ID)"

    if [ -n "$disk_id" ]; then
        case "$disk_id" in
            PTUUID:*)
                ptuuid="${disk_id#PTUUID:}"
                disk="$(blkid -o device -t "PTUUID=${ptuuid}" 2>/dev/null | head -n1 || true)"
                ;;
            *)
                if [ -e "$disk_id" ]; then
                    disk="$(readlink -f "$disk_id" 2>/dev/null || true)"
                fi
                ;;
        esac

        if [ -n "$disk" ] && [ -b "$disk" ]; then
            cached="$(state_get TARGET_DISK)"
            if [ "$cached" != "$disk" ]; then
                state_set TARGET_DISK "$disk"
                log_warn "Target disk re-identified via stable id '$disk_id': now $disk (state.conf had $cached). The kernel likely reassigned /dev/sdX letters after the last reboot." 2>/dev/null || true
            fi
            echo "$disk"
            return 0
        fi

        log_error "Stable disk identifier '$disk_id' no longer resolves to a block device (disk unplugged, or its by-id path/PTUUID changed)." 2>/dev/null || true
        return 1
    fi

    # Backward compatibility: state.conf from before this fix.
    disk="$(state_get TARGET_DISK)"
    if [ -n "$disk" ] && [ -b "$disk" ]; then
        log_warn "TARGET_DISK_ID not set (state.conf predates this fix). Using raw TARGET_DISK='$disk' with no stability guarantee across reboots." 2>/dev/null || true
        echo "$disk"
        return 0
    fi

    return 1
}

# sync_state_to_mount /part/dest
# Copies the current state (of the system the installer is running on)
# to the external disk's filesystem mounted at $1, so that when booting
# from that disk the installer remembers which steps were already done
# during cloning/chroot. It's "best effort": if the destination doesn't
# exist or isn't writable, it warns but doesn't abort the calling step.
sync_state_to_mount() {
    local mnt="$1"
    if [ -d "$mnt" ]; then
        mkdir -p "${mnt}${STATE_DIR}" 2>/dev/null || return 0
        cp -f "$STATE_FILE" "${mnt}${STATE_DIR}/state.conf" 2>/dev/null || true
    fi
}
