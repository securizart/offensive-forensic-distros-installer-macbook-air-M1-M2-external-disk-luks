#!/bin/bash
# lib/common.sh
# Common core: logging, error handling, confirmation helpers.
# Must ALWAYS be loaded after lib/i18n.sh (uses t()) and lib/state.sh.

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Base paths
# ---------------------------------------------------------------------------
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${BASE_DIR}/logs"
MASTER_LOG="${LOG_DIR}/install.log"
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# UI (whiptail with a text fallback). Bootstrapped here: if whiptail is
# missing, it's detected right now (see lib/ui.sh) before the rest of the
# step needs to ask the user anything.
# ---------------------------------------------------------------------------
# shellcheck source=ui.sh
source "${BASE_DIR}/lib/ui.sh"
ui_ensure_whiptail

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# _ts: human-readable timestamp
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# log_line LEVEL "message"  -> writes to the master log
log_line() {
    local level="$1"; shift
    printf '[%s] [%s] %s\n' "$(_ts)" "$level" "$*" >> "$MASTER_LOG"
}

log_info()  { log_line "INFO"  "$*"; }
log_warn()  { log_line "WARN"  "$*"; echo "⚠ $*" >&2; }
log_error() { log_line "ERROR" "$*"; echo "✖ $*" >&2; }
log_ok()    { log_line "OK"    "$*"; }

# init_step_log STEP_ID -> creates/assigns the step's individual log and
# redirects all output (stdout+stderr) to it too, without losing terminal
# interactivity (uses tee).
STEP_LOG=""
init_step_log() {
    local step_id="$1"
    local stamp
    stamp="$(date '+%Y%m%d_%H%M%S')"
    STEP_LOG="${LOG_DIR}/step_${step_id}_${stamp}.log"
    : > "$STEP_LOG"
    # Duplicate the step's whole output to its individual log, while
    # keeping the console visible to the user.
    exec > >(tee -a "$STEP_LOG") 2> >(tee -a "$STEP_LOG" >&2)
    log_info "$(t log_step_start "$step_id" "$STEP_LOG")"
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------
CURRENT_STEP_ID="${CURRENT_STEP_ID:-unknown}"

on_error() {
    local exit_code=$?
    local line_no=$1
    log_error "$(t log_step_failed "$CURRENT_STEP_ID" "$line_no" "$exit_code")"
    mark_step_failed "$CURRENT_STEP_ID" 2>/dev/null || true
    echo
    echo "$(t step_failed_console "$CURRENT_STEP_ID")"
    echo "$(t log_saved_at "$STEP_LOG")"
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# run_cmd "description" cmd arg1 arg2...
# Runs a command, logs it (command + result) and propagates the failure
# through `set -e`/trap ERR.
run_cmd() {
    local desc="$1"; shift
    log_info "$(t log_running "$desc" "$*")"
    "$@"
    local rc=$?
    if [ $rc -eq 0 ]; then
        log_ok "$(t log_ok_cmd "$desc")"
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# Basic checks
# ---------------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "$(t err_root_required)" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# User interaction
# ---------------------------------------------------------------------------
# confirm "i18n_question_key" [args...]
# Returns 0 if the user confirms, 1 otherwise. In whiptail mode it shows a
# yes/no dialog; in text mode it doesn't accept a mistyped single-character
# 'y/n' (see ui_yesno).
confirm_yes_no() {
    ui_yesno "$(t confirm_title)" "$1"
}

# confirm_destructive DISK_OR_TARGET
# For irreversible steps (partitioning, formatting, luksFormat...). Forces
# the user to type the confirmation word literally, both in whiptail mode
# (inputbox) and in text mode.
confirm_destructive() {
    local target="$1"
    local word resp
    word="$(t confirm_word)"
    log_warn "$(t warn_destructive "$target")"
    resp="$(ui_inputbox "$(t confirm_title)" "$(t warn_destructive "$target")
$(t type_to_confirm "$word")" "")"
    if [ "$resp" != "$word" ]; then
        log_warn "$(t log_aborted_by_user "$CURRENT_STEP_ID")"
        ui_msgbox "$(t confirm_title)" "$(t aborted_by_user)"
        exit 1
    fi
}

pause_enter() {
    read -r -p "$(t press_enter_continue)" _
}

# ---------------------------------------------------------------------------
# One-off installers for external utilities
# ---------------------------------------------------------------------------

# install_cast_arm64
# Downloads and installs the latest version of "cast" (ekristen/cast, the
# SaltStack-based SIFT/REMnux installer) for arm64.
#
# Resolves the version WITHOUT hardcoding it and WITHOUT using the GitHub
# API (which has an hourly rate limit that's easy to exhaust): it follows
# the redirect from .../releases/latest, whose final URL already contains
# the latest version's tag (e.g. .../releases/tag/v1.0.32). Verified by
# hand: it's the same pattern the REMnux project itself uses to resolve
# its own cast binary.
#
# Returns 0 if "cast" ends up installed and available on PATH, 1 on
# failure (without aborting the calling script thanks to `set -e`: it
# must be invoked as `install_cast_arm64 || ...`).
install_cast_arm64() {
    local ver url tmp
    ver="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        https://github.com/ekristen/cast/releases/latest 2>/dev/null \
        | sed 's#.*/tag/##' || true)"
    if [ -z "$ver" ]; then
        log_error "Could not resolve the latest version of cast (ekristen/cast)."
        return 1
    fi
    url="https://github.com/ekristen/cast/releases/download/${ver}/cast-${ver}-linux-arm64.deb"
    tmp="$(mktemp --suffix=.deb)"
    log_info "Downloading cast ${ver} (arm64) from $url"
    if ! curl -fsSL -o "$tmp" "$url"; then
        log_error "Failed to download $url"
        rm -f "$tmp"
        return 1
    fi
    if ! dpkg -i "$tmp" >>"$MASTER_LOG" 2>&1; then
        apt-get install -f -y >>"$MASTER_LOG" 2>&1 || true
    fi
    rm -f "$tmp"
    if command -v cast >/dev/null 2>&1; then
        log_ok "cast ${ver} installed successfully."
        return 0
    else
        log_error "cast was not available on PATH after the install attempt."
        return 1
    fi
}

# install_remnux_arm64
# Installs REMnux on Ubuntu/Asahi (arm64) by orchestrating the scripts
# vendored under forensics/remnux/, which come as-is from the
# `forensic-distros-silicon-external-disk` satellite project (that
# project owns the actual REMnux logic and its validation on a real VM;
# this function only wires it into the main installer's flow — update
# forensics/remnux/ from there when a new version is approved).
#
# Known, documented limitation (see forensics/remnux/FINDINGS.md there):
# a full `remnux.addon` run succeeds on ~88% of states (~889/1009);
# cleanup.sh removes the binaries Salt marks as installed but that are
# actually broken x86-64 ELFs on arm64, and verify.sh installs the
# confirmed native alternatives for 4 of them automatically
# (docker-compose, redress, yara-x, detect-it-easy). Not all REMnux
# tools end up available; this is expected, not a failure of this
# function.
#
# Returns 0 if the whole install+cleanup+verify sequence ran (even if
# verify.sh reports individual issues, which it logs on its own), 1 if a
# hard prerequisite (git, cast, or the vendored scripts) is missing.
install_remnux_arm64() {
    local remnux_dir="${BASE_DIR}/forensics/remnux"
    if [ ! -f "${remnux_dir}/install.sh" ]; then
        log_error "forensics/remnux/install.sh not found under ${BASE_DIR}. REMnux install skipped."
        return 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        log_info "Installing git (required by 'cast install' to clone the Salt states repo)."
        apt-get install -y git >>"$MASTER_LOG" 2>&1 || {
            log_error "Could not install git. REMnux install skipped."
            return 1
        }
    fi

    if ! command -v cast >/dev/null 2>&1; then
        install_cast_arm64 || {
            log_error "Could not install 'cast'. REMnux install skipped."
            return 1
        }
    fi

    log_info "Cloning/updating remnux/salt-states via cast..."
    run_cmd "cast install remnux/salt-states" cast install remnux/salt-states

    chmod +x "${remnux_dir}"/*.sh 2>/dev/null || true

    log_info "Running forensics/remnux/install.sh (full remnux.addon run, ~20 min, ~88% success expected)..."
    run_cmd "remnux install.sh" bash "${remnux_dir}/install.sh"

    log_info "Running forensics/remnux/cleanup.sh (removing broken x86-64 binaries)..."
    run_cmd "remnux cleanup.sh" bash "${remnux_dir}/cleanup.sh"

    log_info "Running forensics/remnux/verify.sh (confirming the result and installing native arm64 alternatives)..."
    bash "${remnux_dir}/verify.sh"
    local verify_rc=$?
    if [ "$verify_rc" -eq 0 ]; then
        log_ok "REMnux install+cleanup+verify completed with no outstanding issues."
    else
        log_warn "REMnux verify.sh reported outstanding issues (exit $verify_rc) — check ${STEP_LOG} for detail. This can be expected (e.g. cutter has no confirmed native alternative yet)."
    fi
    return 0
}
