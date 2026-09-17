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
