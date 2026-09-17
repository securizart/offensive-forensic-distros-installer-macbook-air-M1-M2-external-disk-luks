#!/bin/bash
# lib/os_catalog.sh
# Catalogue of "offensive"/target operating systems this installer knows
# how to clone (and, in some cases, convert) onto the external disk from
# a base already installed on the internal disk.
#
# Adding a new operating system:
#   1) add its id to SUPPORTED_OS
#   2) add OS_LABEL_CODE[id] (max. 11 characters total for the resulting
#      EFI label "EFI-<code>", the FAT filesystem's limit)
#   3) add OS_SOURCE_BASE[id]: which base needs to be booted on the
#      internal disk to clone toward this OS (see below)
#   4) add the os_<id>_name / os_<id>_desc texts in i18n/strings.en.sh
#   5) add the corresponding branch in steps/08_repositories.sh and
#      steps/09_package_installation.sh (repos/conversion if applicable,
#      metapackages)
#
# No need to touch install.sh or the rest of steps/*: those are generic
# and use $TARGET_OS to derive partition/VG/mapper names.

SUPPORTED_OS=(kali parrot sift remnux)

declare -A OS_LABEL_CODE=(
    [kali]="KALI"
    [parrot]="PARROT"
    [sift]="SIFT"
    [remnux]="REMNUX"
)

# --- expected source base per target OS ------------------------------------
# Kali and Parrot are obtained by CONVERTING an already-cloned Debian/Asahi
# base (adding their own repos on top, see steps/08 and 09). sift and
# remnux are different: they're cloned AS-IS from a genuine, separate
# Ubuntu/Asahi install on the internal disk (no plain "ubuntu" target —
# this installer only cares about Ubuntu as a forensics base, not as a
# general-purpose desktop clone) — there's no meaningful conversion path:
# Parrot and Kali are officially Debian-based distributions, not
# Ubuntu-based, so "converting from Ubuntu" isn't supported and isn't
# considered here.
#
# sift and remnux are separate CLONES of the same Ubuntu base, each with
# their own partitions/VG (since every os_* helper below derives names
# from the id: vgsift, vgremnux) — not sub-options of a single install.
# This lets you keep an Ubuntu+SIFT and an Ubuntu+REMnux as two
# independently bootable systems on the same external disk, instead of
# forcing them to share one volume group. See docs/OPERATING_SYSTEMS.md.
declare -A OS_SOURCE_BASE=(
    [kali]="debian"
    [parrot]="debian"
    [sift]="ubuntu"
    [remnux]="ubuntu"
)

# Maps the booted system's /etc/os-release ID= field to our internal
# "source base" id. Extend this if a new target OS is added with a
# source base other than debian/ubuntu.
declare -A OS_RELEASE_ID_TO_BASE=(
    [debian]="debian"
    [ubuntu]="ubuntu"
)

# os_partition_label PREFIX OS -> short label valid for the corresponding
# filesystem (FAT: max. 11 characters).
os_efi_label()  { echo "EFI-${OS_LABEL_CODE[$1]}"; }
os_boot_label() { echo "boot_${1}"; }
os_root_label() { echo "rootfs_${1}"; }
os_vg_name()    { echo "vg${1}"; }
os_crypt_name() { echo "${1}_root_crypt"; }
os_mountpoint() { echo "/part/dest_${1}"; }

# os_source_base OS -> id of the expected source base (debian|ubuntu)
os_source_base() { echo "${OS_SOURCE_BASE[$1]:-}"; }

# os_targets_for_base BASE -> ids from SUPPORTED_OS whose OS_SOURCE_BASE
# matches BASE, one per line. Used to filter the "Operating systems" menu
# down to what's actually installable from the currently booted system,
# instead of listing every catalogued OS unconditionally.
os_targets_for_base() {
    local base="$1" id
    for id in "${SUPPORTED_OS[@]}"; do
        [ "${OS_SOURCE_BASE[$id]:-}" = "$base" ] && echo "$id"
    done
}

# detect_booted_base -> "debian"|"ubuntu"|"" (resolved via
# OS_RELEASE_ID_TO_BASE from /etc/os-release's ID=). Empty if
# /etc/os-release can't be read or the ID isn't recognized.
detect_booted_base() {
    [ -r /etc/os-release ] || { echo ""; return; }
    local actual_id
    actual_id="$(set +u; . /etc/os-release; echo "${ID:-}")"
    echo "${OS_RELEASE_ID_TO_BASE[$actual_id]:-}"
}

# verify_source_base OS
# Checks that the system CURRENTLY BOOTED on the internal disk is the
# expected source base for cloning toward $OS. This is intentionally a
# BLOCKING check: if it doesn't match, it stops cold with a clear message
# instead of continuing and cloning the wrong system onto partitions that
# are already destructive. See docs/ARCHITECTURE.md for the full
# reasoning.
#
# Requires lib/common.sh (log_*, t) and lib/i18n.sh to already be loaded.
verify_source_base() {
    local target_os="$1"
    local expected_base actual_id actual_base

    expected_base="$(os_source_base "$target_os")"
    if [ -z "$expected_base" ]; then
        log_warn "No source base defined for '$target_os' in OS_SOURCE_BASE; skipping the check."
        return 0
    fi

    if [ ! -r /etc/os-release ]; then
        log_error "Cannot read /etc/os-release to verify the booted source base."
        echo "$(t source_base_cannot_detect)"
        exit 1
    fi

    # Sourced in an isolated subshell (local set +u) so as not to leak
    # /etc/os-release variables into the calling script, and to avoid
    # breaking under `set -u` if the file doesn't define some key.
    actual_id="$(set +u; . /etc/os-release; echo "${ID:-}")"
    actual_base="${OS_RELEASE_ID_TO_BASE[$actual_id]:-}"

    if [ "$actual_base" != "$expected_base" ]; then
        log_error "Wrong source base for '$target_os': expected '$expected_base', detected ID='${actual_id:-empty}' (resolved base: '${actual_base:-none}')."
        echo
        echo "$(t source_base_mismatch \
            "$(t "os_${target_os}_name")" \
            "$(t "source_base_${expected_base}_name")" \
            "${actual_id:-unknown}")"
        exit 1
    fi

    log_info "Source base verified for '$target_os': $actual_base (ID=$actual_id) — OK."
}
