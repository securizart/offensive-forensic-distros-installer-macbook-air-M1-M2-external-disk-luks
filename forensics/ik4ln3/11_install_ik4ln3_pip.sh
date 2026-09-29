#!/bin/bash
# forensics/ik4ln3/11_install_ik4ln3_pip.sh
#
# Installs the handful of iK4lN3 tools that are NOT packaged for noble but
# ARE available (and build) on arm64 via pip. Everything goes into an
# ISOLATED venv under /opt/ik4ln3-venv so we never touch the system Python
# that the Asahi base and apt depend on (PEP 668 / externally-managed).
#
# Reads packages-pip.txt (one requirement per line). Optional stage:
# called by steps/09 only if the user opts in. No kernel/GRUB interaction
# at all, but we still source guard.sh so a stray build-dep pulled by
# 'apt build-dep' style helpers can't drag in a kernel (we don't call
# build-dep here, but the forbidden-glob check stays as a backstop).

set -u -o pipefail

IK4lN3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MASTER_LOG:=/tmp/ik4ln3-standalone.log}"
VENV="/opt/ik4ln3-venv"

if ! declare -F log_info >/dev/null 2>&1; then
    log_info()  { printf '[INFO] %s\n' "$*"; }
    log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
    log_error() { printf '[ERROR] %s\n' "$*" >&2; }
    log_ok()    { printf '[OK] %s\n' "$*"; }
    run_cmd()   { local d="$1"; shift; log_info "run: $*"; "$@"; }
fi
# shellcheck source=forensics/ik4ln3/guard.sh
source "${IK4lN3_DIR}/guard.sh"

# pytsk3 and the libyal python bindings need build tooling + a few -dev
# headers. These are all arm64 'any' in noble and are NOT kernel/grub, so
# they're safe — but we run them through ik4ln3_apt_safe to keep the same
# guarantees (holds active, no autoremove, forbidden-glob check).
BUILD_DEPS=(python3-venv python3-pip python3-dev build-essential pkg-config
            libtsk-dev libewf-dev libbde-dev libvshadow-dev)

ik4ln3_guard_setup   # holds + shims, released on EXIT

log_info "Installing build prerequisites for the pip stage."
ik4ln3_apt_safe "iK4lN3 pip build deps" "${BUILD_DEPS[@]}" || \
    log_warn "Some build deps failed; pip builds may not complete."

# Create the isolated venv (idempotent).
if [ ! -x "${VENV}/bin/pip" ]; then
    run_cmd "create ik4ln3 venv" python3 -m venv "$VENV"
fi
run_cmd "upgrade pip in venv" "${VENV}/bin/pip" install --upgrade pip wheel setuptools

# Read requirements (drop the inline "; note:" annotations we allow in
# the file for readability).
mapfile -t REQS < <(sed -E 's/#.*//; s/;[[:space:]]*note:.*//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
                      "${IK4lN3_DIR}/packages-pip.txt" | grep -v '^$')

ok=0; fail=0
for req in "${REQS[@]}"; do
    if "${VENV}/bin/pip" install "$req" >>"$MASTER_LOG" 2>&1; then
        log_ok "  pip installed: $req"
        ok=$((ok+1))
    else
        log_warn "  pip failed: $req (arm64 build may be unavailable — check $MASTER_LOG)"
        fail=$((fail+1))
    fi
done

# Expose the venv's console scripts on PATH without polluting the system
# Python: symlink them into /usr/local/bin.
if [ -d "${VENV}/bin" ]; then
    for bin in "${VENV}"/bin/*; do
        name="$(basename "$bin")"
        case "$name" in
            python*|pip*|activate*|wheel|easy_install*) continue ;;
        esac
        ln -sf "$bin" "/usr/local/bin/${name}" 2>/dev/null || true
    done
fi

log_info "iK4lN3 pip stage: $ok installed, $fail failed. Tools live in ${VENV}, linked into /usr/local/bin."
