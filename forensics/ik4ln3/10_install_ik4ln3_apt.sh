#!/bin/bash
# forensics/ik4ln3/10_install_ik4ln3_apt.sh
#
# Installs the arm64-available subset of the iK4lN3 forensic toolset onto
# an already-booted, already-cloned Ubuntu 24.04 (noble) / Asahi system,
# straight from the Ubuntu archive. Reads its package lists from the
# files next to it:
#     packages-apt.txt      one package per line (arm64-confirmed)
#     packages-renamed.txt  "<old> <new>" pairs, installs <new>
#     packages-skip.txt     documentation only (not read here)
#
# This script does NOT touch GRUB or the kernel: see guard.sh, sourced
# below, which holds the Asahi kernel + GRUB stack and shims
# update-grub/grub-install to no-ops for the whole transaction.
#
# Called by steps/09_package_installation.sh (ik4ln3 branch). Safe to
# re-run: apt-get install is idempotent and failures in one group don't
# abort the rest.

set -u -o pipefail

IK4lN3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# BASE_DIR and lib/common.sh (log_*, run_cmd, MASTER_LOG) are exported by
# the caller (step 09). Fall back gracefully if run standalone for tests.
: "${BASE_DIR:=$(cd "${IK4lN3_DIR}/../.." && pwd)}"
: "${MASTER_LOG:=/tmp/ik4ln3-standalone.log}"
if ! declare -F log_info >/dev/null 2>&1; then
    # Minimal shims so the script is testable on its own.
    log_info()  { printf '[INFO] %s\n' "$*"; }
    log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
    log_error() { printf '[ERROR] %s\n' "$*" >&2; }
    log_ok()    { printf '[OK] %s\n' "$*"; }
    run_cmd()   { local d="$1"; shift; log_info "run: $*"; "$@"; }
fi

# shellcheck source=forensics/ik4ln3/guard.sh
source "${IK4lN3_DIR}/guard.sh"

# --- sanity: we must be on Ubuntu/Asahi arm64 ------------------------------
if [ "$(dpkg --print-architecture)" != "arm64" ]; then
    log_error "This script only runs on arm64. Aborting."
    exit 1
fi
if ! grep -q '^ID=ubuntu' /etc/os-release 2>/dev/null; then
    log_warn "This doesn't look like Ubuntu (/etc/os-release). The iK4lN3 toolset targets Ubuntu 24.04/Asahi. Continuing, but double-check you booted the right base."
fi

# --- read the package lists ------------------------------------------------
# Strip comments/blanks; the renamed file yields its 2nd column.
mapfile -t APT_PKGS < <(sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
                          "${IK4lN3_DIR}/packages-apt.txt" | grep -v '^$')
mapfile -t RENAMED  < <(sed -E 's/#.*//' "${IK4lN3_DIR}/packages-renamed.txt" \
                          | awk 'NF>=2{print $2}')

# Merge, de-dup, and run the forbidden-glob filter (defence in depth: if
# a kernel/grub name ever ends up in a list by mistake, it's dropped).
declare -A seen=()
CANDIDATES=()
for p in "${APT_PKGS[@]}" "${RENAMED[@]}"; do
    [ -n "${seen[$p]:-}" ] && continue
    seen[$p]=1
    CANDIDATES+=("$p")
done
mapfile -t CANDIDATES < <(printf '%s\n' "${CANDIDATES[@]}" | ik4ln3_filter_forbidden)

log_info "iK4lN3 apt install: ${#CANDIDATES[@]} candidate packages after filtering."

# --- put the guards up (holds + grub shims), auto-released on EXIT ---------
ik4ln3_guard_setup

# --- make sure 'universe' is enabled (most tools live there) ---------------
# add-apt-repository is idempotent; it does NOT touch grub/kernel.
if ! grep -Rqs 'universe' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    log_info "Enabling the 'universe' component (most iK4lN3 tools live there)."
    run_cmd "enable universe" add-apt-repository -y universe || \
        log_warn "Could not enable 'universe' automatically; some packages may be unavailable."
fi
run_cmd "apt update" apt-get update

# --- install in one guarded transaction ------------------------------------
# We try the whole set first (fastest, resolves deps together). If apt
# can't satisfy the full set, fall back to installing package-by-package
# so one unavailable/renamed tool doesn't sink the rest.
if ! ik4ln3_apt_safe "iK4lN3 forensic toolset (bulk)" "${CANDIDATES[@]}"; then
    log_warn "Bulk install failed or was blocked by the guard; retrying package-by-package."
    ok=0; fail=0; skipped=0
    for p in "${CANDIDATES[@]}"; do
        # skip anything not actually present in the archive for arm64
        if ! apt-cache show "$p" >/dev/null 2>&1; then
            log_warn "  not in archive for this release/arch: $p (skipped)"
            skipped=$((skipped+1)); continue
        fi
        if ik4ln3_apt_safe "install $p" "$p"; then
            ok=$((ok+1))
        else
            log_warn "  failed: $p (left for manual review)"
            fail=$((fail+1))
        fi
    done
    log_info "iK4lN3 per-package result: $ok installed, $fail failed, $skipped not-in-archive."
fi

# --- final apt sanity check (did anything leave a broken state?) -----------
if apt-get check >>"$MASTER_LOG" 2>&1; then
    log_ok "apt-get check reports a consistent package state after the iK4lN3 install."
else
    log_warn "apt-get check reports problems. Review $MASTER_LOG. Do NOT run 'apt --fix-broken install' blindly here — verify it won't touch the kernel/grub first (the holds should prevent it, but check)."
fi

# guard teardown (unhold + un-shim) happens automatically via the EXIT trap.
log_ok "iK4lN3 apt stage finished. See packages-skip.txt for what was intentionally left out and why."
