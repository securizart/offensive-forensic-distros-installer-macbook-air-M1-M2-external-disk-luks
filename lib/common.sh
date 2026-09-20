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

# resolve_physical_disk DEVICE -> the top-level physical disk's kernel
# name (e.g. "nvme0n1", "sda") that DEVICE ultimately sits on, walking
# up lsblk's PKNAME chain as many times as needed. A single PKNAME
# lookup only returns the IMMEDIATE parent, which for a root filesystem
# on LVM is the underlying PV/crypt device, not the physical disk — one
# hop is enough for a plain partition, but not for LVM-on-LUKS (or
# LVM alone), where there are two or three layers to climb. Returns
# empty if DEVICE can't be resolved at all.
resolve_physical_disk() {
    local dev="$1" name parent
    name="$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n1 || true)"
    [ -z "$name" ] && { echo ""; return; }
    while true; do
        parent="$(lsblk -no PKNAME "/dev/${name}" 2>/dev/null | head -n1 || true)"
        [ -z "$parent" ] && break
        name="$parent"
    done
    echo "$name"
}

# grub_set_var NAME VALUE -> sets NAME=VALUE in /etc/default/grub,
# replacing any existing line for NAME in place — commented or not,
# with or without leading whitespace before the '#' — or appending a
# new line if there's no such line at all. Debian/Ubuntu ship several
# of these settings (GRUB_DISABLE_OS_PROBER, GRUB_RECORDFAIL_TIMEOUT...)
# commented out by default; a plain `grep -q '^NAME='` doesn't match
# that, so a naive "append if not found" ends up adding a second,
# active line after the harmless-looking commented one instead of
# replacing it in place — confusing to read, and easy to miss that
# it's actually the later line taking effect. This targets whichever
# form is already there.
grub_set_var() {
    local name="$1" value="$2"
    if grep -qE "^[[:space:]]*#?[[:space:]]*${name}=" /etc/default/grub 2>/dev/null; then
        sed -i -E "s/^[[:space:]]*#?[[:space:]]*${name}=.*/${name}=${value}/" /etc/default/grub
    else
        echo "${name}=${value}" >> /etc/default/grub
    fi
}

# hold_graphics_kernel_packages -> apt-marks on hold every currently-
# installed package matching the kernel / GPU-userspace family that's
# tightly version-coupled on Ubuntu/Asahi (kernel image/headers/modules,
# ubuntu-asahi itself, Mesa, the display manager/compositor, Xorg/
# Wayland — see docs/TROUBLESHOOTING.md), and prints the space-separated
# list so the caller can pass it to unhold_packages afterward.
#
# Deliberately NARROWER than holding every installed package: an
# earlier version of this helper did exactly that, and it blocked
# SIFT's own SaltStack provisioning from resolving its OWN package
# dependencies ("E: Unable to correct problems, you have held broken
# packages" — 140/846 states failed on real hardware, starting with
# sift.packages.g++). Third-party provisioning can still freely upgrade
# any OTHER shared library it needs (libc, libstdc++, python, ...);
# only the pieces that actually caused the graphical session to break
# are protected here.
hold_graphics_kernel_packages() {
    local pkgs
    pkgs="$(dpkg --get-selections 2>/dev/null \
        | awk '$2 == "install" {print $1}' \
        | grep -E '^(linux-(image|headers|modules)|ubuntu-asahi|.*mesa.*|gnome-shell.*|gdm3|xserver-xorg.*|xwayland.*|mutter.*|libdrm.*|libgbm.*|libwayland.*)$' \
        || true)"
    if [ -n "$pkgs" ]; then
        apt-mark hold $pkgs >/dev/null 2>&1
    fi
    echo "$pkgs"
}

# unhold_packages PKG_LIST (space/newline separated, as returned by
# hold_graphics_kernel_packages)
unhold_packages() {
    local pkgs="$1"
    if [ -n "$pkgs" ]; then
        apt-mark unhold $pkgs >/dev/null 2>&1
    fi
}

# ensure_apt_repos_sane
# Idempotent repo sanity check, meant to run at the START of any step
# that installs third-party packages (steps/09) — including on a
# RETRY after a previous failed attempt, when the damage described
# below may already be present.
#
# Confirmed failure mode: WineHQ (installed as part of REMnux/SIFT's
# own package set) registers the i386 architecture system-wide
# (`dpkg --add-architecture i386`). This base's own repos
# (ports.ubuntu.com, used because this is arm64) never serve i386
# packages at all — once i386 is registered, EVERY subsequent
# `apt update`/`apt install`, system-wide, tries to fetch i386 indices
# from ports.ubuntu.com and gets a 404, which apt treats as a hard
# error ("Some index files failed to download"). This breaks the very
# same step's own later `apt install` calls if it's retried, and any
# unrelated `apt` use afterward.
#
# Fix: restrict ports.ubuntu.com's own entries to arch=arm64
# (Architectures: arm64 in the deb822 sources file, or [arch=arm64] in
# the legacy sources.list), and add a working i386 mirror
# (archive.ubuntu.com/security.ubuntu.com, which DOES serve i386) for
# whenever i386 actually is needed. Safe to run whether i386 has been
# registered yet or not, and whether this has already been applied.
ensure_apt_repos_sane() {
    local ubuntu_sources="/etc/apt/sources.list.d/ubuntu.sources"
    local legacy_sources="/etc/apt/sources.list"
    local i386_mirror="/etc/apt/sources.list.d/i386-archive.list"
    local changed=0

    if [ -f "$ubuntu_sources" ] && grep -q "ports\.ubuntu\.com" "$ubuntu_sources" \
       && ! grep -q "^Architectures: arm64" "$ubuntu_sources"; then
        log_info "Restricting ports.ubuntu.com to arm64 in ${ubuntu_sources} (prevents i386 404s once i386 gets registered by third-party packages like WineHQ)."
        sed -i '/^Signed-By: \/usr\/share\/keyrings\/ubuntu-archive-keyring.gpg$/a Architectures: arm64' "$ubuntu_sources"
        changed=1
    fi

    if [ -f "$legacy_sources" ] && grep -qE "^deb http://ports\.ubuntu\.com/ubuntu-ports" "$legacy_sources"; then
        log_info "Restricting ports.ubuntu.com to arm64 in ${legacy_sources}."
        sed -i -E 's#^deb (http://ports\.ubuntu\.com/ubuntu-ports)#deb [arch=arm64] \1#' "$legacy_sources"
        changed=1
    fi

    if [ ! -f "$i386_mirror" ]; then
        log_info "Adding an i386-capable mirror (archive.ubuntu.com/security.ubuntu.com) for whenever third-party packages (e.g. WineHQ) register the i386 architecture — ports.ubuntu.com never serves it."
        cat > "$i386_mirror" << 'I386_MIRROR_EOF'
deb [arch=i386] http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb [arch=i386] http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb [arch=i386] http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
I386_MIRROR_EOF
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        run_cmd "apt update (repo sanity check)" apt update
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
# install_remnux_arm64
# Installs REMnux on Ubuntu/Asahi (arm64), targeting the dedicated
# "remnux" system user (created in steps/09's remnux) branch) rather
# than root.
#
# Uses forensics/remnux/remnux-installer.sh, a single consolidated
# script (fuses the old install.sh + cleanup.sh + verify.sh +
# install-extra-tools.sh) validated end-to-end on the forensics
# satellite project. Key findings that shape this function:
#
#   - `cast install remnux/salt-states` does NOT just clone the repo:
#     it applies the full `remnux.dedicated` state itself (desktop/
#     GNOME theme included), taking ~20-30 min on its own. Calling
#     remnux-installer.sh's own --base phase afterwards (a separate
#     `state.apply remnux.addon`) is redundant, so it's not used here.
#   - remnux-installer.sh assumes it runs AS the target desktop user:
#     it reads $HOME throughout, and critically writes the --menu
#     phase's .desktop launchers to $HOME/.local/share/applications.
#     Running it as root (this function's caller runs the whole step
#     as root) would silently put all of that under /root instead of
#     /home/remnux — invisible to the "remnux" user's GNOME session,
#     and the reason desktop shortcuts never appeared before. Every
#     REMnux-specific command below runs via `sudo -u remnux -i --`.
#
# Returns 0 if the sequence ran (individual tool failures inside
# remnux-installer.sh are expected — see its own success framing), 1 if
# a hard prerequisite (git, cast, the vendored script, or the "remnux"
# user itself) is missing.
install_remnux_arm64() {
    local remnux_dir="${BASE_DIR}/forensics/remnux"
    local installer="${remnux_dir}/remnux-installer.sh"

    if [ ! -f "$installer" ]; then
        log_error "forensics/remnux/remnux-installer.sh not found under ${BASE_DIR}. REMnux install skipped."
        return 1
    fi
    if ! id remnux >/dev/null 2>&1; then
        log_error "System user 'remnux' does not exist yet. REMnux install skipped."
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

    chmod +x "$installer" 2>/dev/null || true

    # This function stays as root throughout (never drops to the remnux
    # uid — see the HOME/USER/SUDO_USER override below instead), so any
    # directory under /home/remnux left owned by 'remnux' from a
    # previous run (e.g. remnux-installer.sh's --extra phase cloning
    # tools via git) trips git's "dubious ownership" safety check on a
    # re-run: the real process uid (root) doesn't match the directory
    # owner. Trust everything under /home/remnux explicitly so re-runs
    # don't get benign-but-noisy git warnings.
    mkdir -p /home/remnux
    git config -f /home/remnux/.gitconfig --add safe.directory '*' 2>/dev/null || true
    chown remnux:remnux /home/remnux/.gitconfig 2>/dev/null || true

    log_info "Running 'cast install remnux/salt-states' with HOME=/home/remnux (applies the full dedicated state — this is the ~20-30 min step, not a plain git clone)..."
    # SUDO_USER=remnux is the critical one here, not USER/LOGNAME: cast's
    # own .cast.yml declares `remnux_user_template: "{{ .User }}"`, and
    # cast resolves that .User via $SUDO_USER (whoever originally ran
    # 'sudo' at the top of this whole install), NOT via $USER/$LOGNAME.
    # Left unset/inherited, $SUDO_USER stays whatever it was when the
    # user first launched install.sh (e.g. 'iac') several steps back,
    # and every per-user file this pillar drives (desktop theme,
    # autostart entries, .desktop shortcuts) silently lands in THAT
    # user's home instead of /home/remnux — confirmed directly from a
    # real saltstack.log run, where every remnux-gnome-config-* state
    # wrote to /home/iac/.config/... with user: iac.
    run_cmd "cast install remnux/salt-states" \
        env HOME=/home/remnux USER=remnux LOGNAME=remnux SUDO_USER=remnux cast install remnux/salt-states

    log_info "Running remnux-installer.sh --cleanup --verify --extra --partial --menu with HOME=/home/remnux (no --base: cast install already applied the dedicated state above)..."
    run_cmd "remnux-installer.sh" \
        env HOME=/home/remnux USER=remnux LOGNAME=remnux SUDO_USER=remnux bash "$installer" --cleanup --verify --extra --partial --menu
    local rc=$?
    chown -R remnux:remnux /home/remnux 2>/dev/null || true

    # REMnux's own remnux.config.display state (Ubuntu 24.04/"noble"
    # only) appends MUTTER_DEBUG_FORCE_KMS_MODE=simple to
    # /etc/environment as a VMware/GNOME display accommodation. On real
    # Apple Silicon hardware (Asahi's GPU driver, not VMware's), that
    # same forced KMS mode is what breaks the hardware cursor plane
    # under Wayland, leaving the mouse pointer completely invisible
    # system-wide (confirmed: happens in every session, iac and remnux
    # alike, only after REMnux installs — never on plain Ubuntu or
    # SIFT, which don't carry this state at all). Strip just that one
    # line; NO_AT_BRIDGE=1 (the other line REMnux adds) is harmless and
    # left in place.
    if grep -q '^MUTTER_DEBUG_FORCE_KMS_MODE=' /etc/environment 2>/dev/null; then
        log_info "Removing REMnux's MUTTER_DEBUG_FORCE_KMS_MODE=simple from /etc/environment (VMware-only accommodation that breaks the hardware cursor on real Asahi/Apple Silicon GPUs)."
        sed -i '/^MUTTER_DEBUG_FORCE_KMS_MODE=/d' /etc/environment
    fi

    if [ "$rc" -eq 0 ]; then
        log_ok "REMnux install (remnux-installer.sh) completed with no outstanding issues from --verify."
    else
        log_warn "remnux-installer.sh reported outstanding issues (exit $rc) — check ${STEP_LOG} for detail. This can be expected (e.g. cutter has no confirmed fix, or inspircd downgrade was skipped without a TTY to confirm it)."
    fi
    return 0
}
