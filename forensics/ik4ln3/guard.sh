#!/bin/bash
# forensics/ik4ln3/guard.sh
#
# Safety guards for the iK4lN3 forensic-toolset install on Ubuntu/Asahi
# (arm64). Sourced by 10_install_ik4ln3_apt.sh and 11_install_ik4ln3_pip.sh.
#
# Two failures have bitten this project before and both are guarded here:
#
#   1. GRUB. The Mac's boot chain is m1n1 -> U-Boot -> GRUB, and /boot
#      (EFI + kernel) lives on the internal disk. GRUB is owned entirely
#      by steps 06/07 (finalize + merge) and the step-10 safety net.
#      Any apt transaction that installs/reinstalls/removes a grub-*
#      package, or whose maintainer scripts run `update-grub` /
#      `grub-install`, can rewrite grub.cfg against the wrong disk and
#      leave the Mac unbootable. So: we HOLD every grub package, and we
#      neutralize update-grub/grub-install for the duration of the iK4lN3
#      transaction via a PATH shim (not a permanent dpkg-divert — we undo
#      it in a trap no matter how the script exits).
#
#   2. The Asahi kernel. Asahi ships `linux-asahi` (+ its meta/headers),
#      NOT the stock `linux-image-generic`. If apt is allowed to pull a
#      stock kernel, a kernel metapackage, or to autoremove, it can drag
#      out linux-asahi and break boot. So: we HOLD the asahi kernel
#      stack, refuse to install any stock-kernel / DKMS package, and
#      NEVER pass --autoremove in this branch.
#
# All holds set here are released by ik4ln3_guard_teardown, wired to an
# EXIT trap by ik4ln3_guard_setup, so a crash mid-install can't leave the
# system with packages held.

# Requires lib/common.sh already sourced (log_info/warn/error/ok, run_cmd).

# Packages we refuse to let this branch install (kernel/bootloader/DKMS).
# Matched as globs against every candidate before we hand it to apt.
IK4lN3_FORBIDDEN_GLOBS=(
    'grub-*' 'grub2-*' 'shim*' 'signed-*grub*'
    'linux-image-*' 'linux-headers-*' 'linux-modules-*'
    'linux-generic*' 'linux-image-generic*' 'linux-headers-generic*'
    'linux-lowlatency*' 'linux-virtual*' 'linux-oem*'
    '*-dkms'            # DKMS builds against the running kernel
    'bcmwl-kernel-source' 'broadcom-sta-*'
    'memtest86+' 'syslinux*' 'os-prober'
)

# Packages we pin with `apt-mark hold` so nothing (deps, upgrades,
# maintainer scripts) can touch them during the iK4lN3 transaction. The
# asahi list is resolved dynamically because the exact package name
# varies (linux-asahi, linux-asahi-edge, linux-image-asahi, ...).
_ik4ln3_held=()

# _ik4ln3_asahi_packages -> prints installed kernel/bootloader packages
# that belong to the Asahi stack (or the generic grub packages we always
# want frozen), one per line.
_ik4ln3_asahi_packages() {
    dpkg-query -W -f '${Package}\n' 2>/dev/null | grep -E \
        '^(linux-(image|headers|modules)?-?.*asahi|linux-asahi.*|asahi-.*|grub-efi-arm64.*|grub-common|grub2-common|grub-efi.*|u-boot.*|m1n1.*)$' \
        || true
}

# ik4ln3_guard_hold -> apt-mark hold everything we must freeze; remember
# what WE held (so teardown only unholds those, never something the user
# had already held for their own reasons).
ik4ln3_guard_hold() {
    local pkg already
    already="$(apt-mark showhold 2>/dev/null)"
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        if ! grep -qxF "$pkg" <<<"$already"; then
            if apt-mark hold "$pkg" >>"$MASTER_LOG" 2>&1; then
                _ik4ln3_held+=("$pkg")
            fi
        fi
    done < <(_ik4ln3_asahi_packages)
    if [ "${#_ik4ln3_held[@]}" -gt 0 ]; then
        log_info "iK4lN3 guard: held ${#_ik4ln3_held[@]} kernel/GRUB packages for the duration of the install: ${_ik4ln3_held[*]}"
    else
        log_warn "iK4lN3 guard: no Asahi kernel/GRUB packages found to hold. Are you really booted on Ubuntu/Asahi? Continuing, but check the log."
    fi
}

# ik4ln3_guard_unhold -> release only the holds WE added.
ik4ln3_guard_unhold() {
    local pkg
    for pkg in "${_ik4ln3_held[@]}"; do
        apt-mark unhold "$pkg" >>"$MASTER_LOG" 2>&1 || true
    done
    _ik4ln3_held=()
}

# ik4ln3_guard_shim_dir -> creates a temp dir with no-op update-grub /
# grub-install / grub-mkconfig shims and prepends it to PATH, so any
# maintainer script that calls them during our apt run does nothing but
# log. Returns the dir path (also stored in _IK4lN3_SHIM_DIR).
_IK4lN3_SHIM_DIR=""
ik4ln3_guard_shim_on() {
    _IK4lN3_SHIM_DIR="$(mktemp -d /tmp/ik4ln3-grubshim.XXXXXX)"
    local tool
    for tool in update-grub update-grub2 grub-install grub-mkconfig grub2-install grub2-mkconfig; do
        cat >"${_IK4lN3_SHIM_DIR}/${tool}" <<SHIM
#!/bin/sh
echo "[iK4lN3 guard] blocked '${tool} \$*' during forensic-tools install (GRUB is owned by steps 06/07/10)." >&2
exit 0
SHIM
        chmod +x "${_IK4lN3_SHIM_DIR}/${tool}"
    done
    export PATH="${_IK4lN3_SHIM_DIR}:${PATH}"
    log_info "iK4lN3 guard: GRUB tools shimmed to no-ops via ${_IK4lN3_SHIM_DIR}"
}

ik4ln3_guard_shim_off() {
    if [ -n "$_IK4lN3_SHIM_DIR" ]; then
        PATH="${PATH#"${_IK4lN3_SHIM_DIR}":}"
        rm -rf "$_IK4lN3_SHIM_DIR"
        _IK4lN3_SHIM_DIR=""
    fi
}

# ik4ln3_guard_teardown -> always-safe cleanup (idempotent). Wired to EXIT.
ik4ln3_guard_teardown() {
    ik4ln3_guard_shim_off
    ik4ln3_guard_unhold
}

# ik4ln3_guard_setup -> call once at the top of the install script.
ik4ln3_guard_setup() {
    trap 'ik4ln3_guard_teardown' EXIT
    ik4ln3_guard_hold
    ik4ln3_guard_shim_on
}

# ik4ln3_is_forbidden PKG -> 0 if PKG matches a forbidden glob, else 1.
ik4ln3_is_forbidden() {
    local pkg="$1" g
    for g in "${IK4lN3_FORBIDDEN_GLOBS[@]}"; do
        # shellcheck disable=SC2053
        [[ "$pkg" == $g ]] && return 0
    done
    return 1
}

# ik4ln3_filter_forbidden < list-on-stdin -> prints only the allowed
# packages, logging each one it drops. Last line of defence in case a
# forbidden name sneaks into a package list.
ik4ln3_filter_forbidden() {
    local pkg
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        if ik4ln3_is_forbidden "$pkg"; then
            log_warn "iK4lN3 guard: refusing kernel/GRUB/DKMS package '$pkg' (dropped from the transaction)."
        else
            echo "$pkg"
        fi
    done
}

# ik4ln3_apt_safe DESC PKG... -> apt-get install with every safety flag we
# want in this branch: no autoremove, no recommends drift into kernels,
# non-interactive, and crucially --no-install-recommends is NOT used
# (forensic tools rely on recommends), but we DO forbid the guard globs
# from being pulled as new installs by checking the simulation first.
ik4ln3_apt_safe() {
    local desc="$1"; shift
    local pkgs=("$@")
    [ "${#pkgs[@]}" -gt 0 ] || { log_info "iK4lN3: nothing to install for '$desc'."; return 0; }

    # Dry-run to see what apt WOULD newly install; abort if a forbidden
    # package would be dragged in as a dependency.
    local sim forbidden
    sim="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove -s "${pkgs[@]}" 2>/dev/null \
            | awk '/^Inst /{print $2}')"
    forbidden="$(printf '%s\n' "$sim" | ik4ln3_filter_forbidden >/dev/null 2>&1; \
                 printf '%s\n' "$sim" | while read -r p; do ik4ln3_is_forbidden "$p" && echo "$p"; done)"
    if [ -n "$forbidden" ]; then
        log_error "iK4lN3 guard: '$desc' would pull forbidden kernel/GRUB/DKMS package(s): $(echo $forbidden). Skipping this group — install its tools individually after checking the log."
        return 1
    fi

    # Real install. Note: NO --autoremove anywhere in this branch.
    DEBIAN_FRONTEND=noninteractive run_cmd "$desc" \
        apt-get install -y --no-remove "${pkgs[@]}"
}
