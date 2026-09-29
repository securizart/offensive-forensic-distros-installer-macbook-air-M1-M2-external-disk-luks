#!/bin/bash
# swap_desktop_mate.sh
#
# Companion helper (NOT a numbered install step): swap the desktop
# environment on an already-installed Ubuntu/Asahi clone from GNOME to
# MATE, WITHOUT moving the kernel or the GPU userspace stack it is
# version-coupled to.
#
# Why this exists / the hazard it guards against
# ----------------------------------------------
# On Ubuntu/Asahi the kernel and the GPU userspace (mesa, the "agx" DRM
# driver, Xorg/Wayland, the compositor) track each other release to
# release (see docs/TROUBLESHOOTING.md, "Graphical session breaks after
# step 09"). Installing a whole new desktop (ubuntu-mate-desktop) can
# pull NEWER versions of that coupled family as dependencies — which is
# the exact thing that has broken the graphical session before (boots to
# console, no display), even with the kernel itself left unchanged.
#
# So this script does NOT trust "it's only a desktop change". It:
#   1. records the running kernel as an invariant to verify at the end;
#   2. holds the kernel+GPU family (reusing hold_graphics_kernel_packages
#      from lib/common.sh) so apt cannot move it;
#   3. DRY-RUNS the MATE install with that family held: if apt cannot
#      satisfy MATE without upgrading a held package, the simulation
#      fails ("held broken packages") — that is the coupling red flag,
#      and the script ABORTS rather than break the display;
#   4. only if the dry-run is clean, installs MATE;
#   5. pauses for you to log into MATE and verify BEFORE anything is
#      removed;
#   6. removes GNOME only on explicit confirmation, with an autoremove
#      dry-run that aborts if it would touch the kernel/GPU/boot family;
#   7. re-checks the kernel invariant.
#
# Works on real Apple Silicon hardware and in a VM with a different
# kernel: the "keep the kernel" invariant is checked against whatever
# kernel is actually running, not a hardcoded Asahi version.
#
# Usage:
#   sudo ./swap_desktop_mate.sh              # full flow (install + remove)
#   sudo ./swap_desktop_mate.sh --install-only
#   sudo ./swap_desktop_mate.sh --remove-only
#   DESKTOP_META=ubuntu-mate-desktop ./swap_desktop_mate.sh   # override target
#
# Idempotent: safe to re-run. Never runs autoremove without a clean
# dry-run and your confirmation.

set -u

# --------------------------------------------------------------------------
# Wire into the repo's helpers when available; otherwise self-shim so the
# script is testable standalone (e.g. in a VM outside the installer tree).
# --------------------------------------------------------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SELF_DIR}/lib/common.sh" ]; then
    # shellcheck source=lib/common.sh
    . "${SELF_DIR}/lib/common.sh"
fi
if ! declare -F log_info >/dev/null 2>&1; then
    log_info()  { printf '[INFO] %s\n' "$*"; }
    log_warn()  { printf '\342\232\240 %s\n' "$*" >&2; }
    log_error() { printf '\342\234\226 %s\n' "$*" >&2; }
    log_ok()    { printf '[OK] %s\n' "$*"; }
    run_cmd()   { local d="$1"; shift; log_info "run: $*"; "$@"; }
fi
if ! declare -F confirm_yes_no >/dev/null 2>&1; then
    confirm_yes_no() { local a; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; }
fi
# hold_graphics_kernel_packages / unhold_packages: reuse the repo's if
# present, else provide the same behaviour so standalone runs are safe.
if ! declare -F hold_graphics_kernel_packages >/dev/null 2>&1; then
    hold_graphics_kernel_packages() {
        local pkgs
        pkgs="$(dpkg --get-selections 2>/dev/null \
            | awk '$2 == "install" {print $1}' \
            | grep -E '^(linux-(image|headers|modules)|ubuntu-asahi|.*mesa.*|gnome-shell.*|gdm3|xserver-xorg.*|xwayland.*|mutter.*|libdrm.*|libgbm.*|libwayland.*)$' \
            || true)"
        [ -n "$pkgs" ] && apt-mark hold $pkgs >/dev/null 2>&1
        echo "$pkgs"
    }
    unhold_packages() {
        local pkgs="$1"
        [ -n "$pkgs" ] && apt-mark unhold $pkgs >/dev/null 2>&1
    }
fi

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
DESKTOP_META="${DESKTOP_META:-ubuntu-mate-desktop}"   # target desktop metapackage
MODE="full"
case "${1:-}" in
    --install-only) MODE="install" ;;
    --remove-only)  MODE="remove" ;;
    "" )            MODE="full" ;;
    * ) log_error "Unknown argument: $1"; exit 2 ;;
esac

# The coupled family we must never let move implicitly. Same shape as
# hold_graphics_kernel_packages' regex, used here to SCAN a dry-run.
FAMILY_RE='^(linux-(image|headers|modules)|ubuntu-asahi|.*mesa.*|libgl|libglx|libegl|libgles|gnome-shell|gdm3|xserver-xorg|xwayland|mutter|libdrm|libgbm|libwayland)'

# The broader ABORT set for the GNOME-removal autoremove: the coupled
# family PLUS the boot/kernel-upgrade machinery. If autoremove wants to
# remove or purge ANY of these, we stop.
#
# NOTE: xwayland and mutter are deliberately NOT here. They are GNOME's
# Wayland compositor / X-on-Wayland compat layer; MATE runs on Xorg and
# does not use them, so autoremove purging them after GNOME leaves is
# correct, not dangerous. The real coupled stack we protect is the GL/
# KMS drivers (mesa, libdrm, libgbm) and the X server itself
# (xserver-xorg*), which MATE DOES need — those stay protected.
ABORT_RE='(^| )(linux-(image|headers|modules)-.*|linux-asahi.*|linux-meta-asahi.*|ubuntu-asahi|.*mesa.*|libdrm.*|libgbm.*|xserver-xorg.*|grub-efi-arm64.*|grub-common|u-boot.*|m1n1|initramfs-tools|flash-kernel|asahi-.*|alsa-ucm-conf-asahi)( |$)'

MASTER_LOG="${MASTER_LOG:-/tmp/swap_desktop_mate.log}"
: >"$MASTER_LOG" 2>/dev/null || true

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Run as root (sudo). Aborting."; exit 1
    fi
}

# --------------------------------------------------------------------------
# Kernel invariant
# --------------------------------------------------------------------------
KERNEL_BEFORE=""
record_kernel() {
    KERNEL_BEFORE="$(uname -r)"
    log_info "Kernel to preserve across the swap: ${KERNEL_BEFORE}"
    # Also record the installed kernel-image package version, if any, so
    # we catch a swap that changed the package even if uname is stale
    # until reboot.
    KIMG_PKG_BEFORE="$(dpkg-query -W -f '${Package} ${Version}\n' 'linux-image-*' 2>/dev/null \
                        | grep -F "$(uname -r)" || true)"
    [ -n "$KIMG_PKG_BEFORE" ] && log_info "Kernel image package: ${KIMG_PKG_BEFORE}"
}
assert_kernel_unchanged() {
    local now; now="$(uname -r)"
    if [ "$now" != "$KERNEL_BEFORE" ]; then
        log_error "Running kernel changed from ${KERNEL_BEFORE} to ${now}. This should not have happened — investigate before rebooting."
        return 1
    fi
    local kimg_now
    kimg_now="$(dpkg-query -W -f '${Package} ${Version}\n' 'linux-image-*' 2>/dev/null \
                | grep -F "$KERNEL_BEFORE" || true)"
    if [ -n "$KIMG_PKG_BEFORE" ] && [ "$kimg_now" != "$KIMG_PKG_BEFORE" ]; then
        log_warn "Kernel image PACKAGE changed (${KIMG_PKG_BEFORE} -> ${kimg_now}). uname is unchanged only because you haven't rebooted yet. Investigate."
        return 1
    fi
    log_ok "Kernel invariant holds: still ${KERNEL_BEFORE}."
    return 0
}

# --------------------------------------------------------------------------
# Guard teardown (always release the holds we set)
# --------------------------------------------------------------------------
HELD=""
teardown() { [ -n "$HELD" ] && unhold_packages "$HELD"; HELD=""; }
trap teardown EXIT

# --------------------------------------------------------------------------
# Phase 1 — install MATE under the kernel+GPU hold, gated by a dry-run
# --------------------------------------------------------------------------
phase_install() {
    log_info "=== Phase 1: install ${DESKTOP_META} (kernel/GPU family held) ==="

    run_cmd "apt update" apt-get update

    log_info "Holding the kernel + GPU userspace family so the install can't move it..."
    HELD="$(hold_graphics_kernel_packages)"
    if [ -n "$HELD" ]; then
        log_info "Held: $(echo $HELD | tr '\n' ' ')"
    else
        log_warn "Nothing matched the kernel/GPU family to hold. On a real Asahi clone this is unexpected — check you're on the target system. Continuing (dry-run will still gate the install)."
    fi

    # Dry-run WITH the family held. If MATE can't be satisfied without
    # upgrading a held package, apt fails here — that's the coupling red
    # flag, and we stop instead of breaking the display.
    log_info "Simulating the install with the family held (this is the safety gate)..."
    local sim rc
    sim="$(DEBIAN_FRONTEND=noninteractive apt-get install -s "$DESKTOP_META" 2>&1)"
    rc=$?
    echo "$sim" >>"$MASTER_LOG"

    if [ $rc -ne 0 ] || grep -qiE 'held broken packages|Unable to correct problems|Broken packages' <<<"$sim"; then
        log_error "SAFETY GATE TRIPPED: apt cannot install ${DESKTOP_META} without upgrading a held kernel/GPU package."
        log_error "That means MATE needs a newer GPU userspace than the frozen kernel expects — the classic 'boots to console' break. NOT installing."
        log_error "This desktop swap is not viable without also moving the kernel, which is exactly what we're avoiding. Aborting cleanly (holds released)."
        # Show which held package(s) apt wanted, to document the coupling.
        grep -iE 'but .* is to be installed|held broken|however:|Depends:' <<<"$sim" | sed 's/^/    /' | tee -a "$MASTER_LOG"
        return 1
    fi

    # Secondary sanity: even on success, log any family package apt would
    # newly install/upgrade (should be none for upgrades, since held).
    local touched
    touched="$(awk '/^Inst /{print $2}' <<<"$sim" | grep -E "$FAMILY_RE" || true)"
    if [ -n "$touched" ]; then
        log_warn "Dry-run touches these family packages (review in $MASTER_LOG): $(echo $touched | tr '\n' ' ')"
    fi

    # Count what will actually be installed, for the confirmation prompt.
    local n_new
    n_new="$(awk '/^Inst /{c++} END{print c+0}' <<<"$sim")"
    log_info "Dry-run is clean: ${DESKTOP_META} installs as ${n_new} package operations, none forcing a kernel/GPU upgrade."

    if ! confirm_yes_no "Proceed to actually install ${DESKTOP_META} now?"; then
        log_info "Install declined by operator. Holds released, nothing changed."
        return 1
    fi

    DEBIAN_FRONTEND=noninteractive run_cmd "install ${DESKTOP_META}" \
        apt-get install -y "$DESKTOP_META"

    # Release the holds now that the risky operation is done, so a later
    # legitimate FULL upgrade (kernel included) isn't blocked.
    teardown
    log_ok "MATE installed. Kernel/GPU holds released."

    assert_kernel_unchanged || log_warn "Kernel invariant check flagged something — see above."

    cat <<'EOF'

------------------------------------------------------------------
NEXT: verify MATE before removing anything.
  1. Log out.
  2. At the login screen, use the session selector (gear icon) and
     pick "MATE".
  3. Log in and confirm: panel loads, a terminal opens, network works,
     and video is smooth (no fallback/software rendering).
Only once MATE is fully working should you run the removal phase:
     sudo ./swap_desktop_mate.sh --remove-only
------------------------------------------------------------------
EOF
    return 0
}

# --------------------------------------------------------------------------
# Phase 2 — remove GNOME, guarded
# --------------------------------------------------------------------------
running_session_is_gnome() {
    # Best-effort: refuse to tear down GNOME from within a GNOME session.
    local s="${XDG_CURRENT_DESKTOP:-}${GDMSESSION:-}${DESKTOP_SESSION:-}"
    case "${s,,}" in *gnome*|*ubuntu:gnome*) return 0 ;; esac
    return 1
}

phase_remove() {
    log_info "=== Phase 2: remove GNOME (guarded) ==="

    if running_session_is_gnome; then
        log_error "You appear to be inside a GNOME session (${XDG_CURRENT_DESKTOP:-?}). Removing gnome-shell now would freeze it."
        log_error "Log into MATE, or switch to a text console (Ctrl+Alt+F3), then run:  sudo ./swap_desktop_mate.sh --remove-only"
        return 1
    fi

    # Make sure MATE is actually present before we remove the other DE.
    if ! dpkg -l "$DESKTOP_META" 2>/dev/null | grep -q '^ii'; then
        log_error "${DESKTOP_META} is not installed. Run the install phase first; refusing to remove GNOME with no replacement desktop."
        return 1
    fi

    # Ensure a display manager will remain. If gdm3 is the only DM and we
    # are about to remove GNOME (which may pull gdm3), install lightdm
    # first so we never end up with no DM.
    local have_lightdm have_gdm
    have_lightdm="$(dpkg -l lightdm 2>/dev/null | grep -c '^ii')"
    have_gdm="$(dpkg -l gdm3 2>/dev/null | grep -c '^ii')"
    if [ "$have_lightdm" -eq 0 ]; then
        log_info "No lightdm present; installing it so a display manager survives GNOME removal."
        DEBIAN_FRONTEND=noninteractive run_cmd "install lightdm" apt-get install -y lightdm || \
            log_warn "Could not install lightdm; make sure gdm3 stays if you keep it."
    fi

    # Remove the GNOME metapackage + shell + session, but NOT via
    # autoremove yet. --purge on these named packages only.
    log_info "Removing the GNOME metapackage, shell and session (named packages only)..."
    DEBIAN_FRONTEND=noninteractive run_cmd "remove gnome" \
        apt-get remove -y ubuntu-desktop ubuntu-desktop-minimal gnome-shell gnome-session \
        || log_warn "Some GNOME packages were already absent; continuing."

    # The delicate part: autoremove. DRY-RUN first and abort if it would
    # touch the kernel/GPU/boot family.
    log_info "Dry-running 'apt autoremove --purge' to see what would be removed..."
    local sim
    sim="$(DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -s 2>&1)"
    echo "$sim" >>"$MASTER_LOG"

    local danger
    danger="$(grep -E '^(Remv|Purg) ' <<<"$sim" | grep -E "$ABORT_RE" || true)"
    if [ -n "$danger" ]; then
        log_error "SAFETY GATE TRIPPED: autoremove would touch protected kernel/GPU/boot packages:"
        echo "$danger" | sed 's/^/    /' | tee -a "$MASTER_LOG"
        log_error "NOT running autoremove. Remove leftover GNOME packages by hand instead, one at a time, checking each does not pull the above."
        return 1
    fi

    # Show the operator exactly what will go, and let them confirm.
    local to_remove n
    to_remove="$(grep -E '^(Remv|Purg) ' <<<"$sim" | awk '{print $2}')"
    n="$(printf '%s\n' "$to_remove" | grep -c . || true)"
    log_info "autoremove would remove ${n} packages, none in the protected family. Sample:"
    printf '%s\n' "$to_remove" | head -30 | sed 's/^/    /'

    if ! confirm_yes_no "Run 'apt autoremove --purge' for real now?"; then
        log_info "autoremove declined. GNOME metapackage/shell already removed; orphans left in place (harmless, just disk)."
        return 0
    fi

    DEBIAN_FRONTEND=noninteractive run_cmd "autoremove purge" apt-get autoremove --purge -y

    # Final safety checks before the operator reboots.
    log_info "Post-removal checks..."
    if dpkg -l gdm3 lightdm 2>/dev/null | grep -q '^ii'; then
        log_ok "A display manager is present."
    else
        log_error "NO display manager installed. Install one before rebooting:  sudo apt-get install lightdm"
    fi
    apt-get check >>"$MASTER_LOG" 2>&1 && log_ok "apt state is consistent." \
        || log_warn "apt-get check reports problems — review $MASTER_LOG before rebooting."

    assert_kernel_unchanged || log_warn "Kernel invariant check flagged something — see above."

    log_ok "GNOME removal finished. Reboot and you should land in MATE."
    return 0
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
require_root
record_kernel

case "$MODE" in
    install) phase_install ;;
    remove)  phase_remove ;;
    full)
        phase_install && {
            echo
            log_info "Install phase done. The removal phase is intentionally SEPARATE."
            log_info "Verify MATE (log in and check it fully), THEN run: sudo $0 --remove-only"
        }
        ;;
esac
