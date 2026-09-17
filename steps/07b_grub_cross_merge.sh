#!/bin/bash
# steps/07b_grub_cross_merge.sh
# Optional step, run right after 07 while still on the host. Makes the
# *sibling* internal base (Debian<->Ubuntu) aware of this host's boot
# menu by dropping a small custom /etc/grub.d/ script on its filesystem
# that chainloads this host's own grub.cfg via `configfile`. The
# sibling's entry then always reflects whatever is currently native on
# this host (future OS merges, kernel updates) without duplicating any
# menuentry text — no re-sync needed after future update-grub runs on
# either side. See docs/ARCHITECTURE.md for the full reasoning.
#
# Marked as a NO_GATE_STEPS entry in install.sh: it never blocks
# progression to step 08, and can be (re-)run at any point after 07.
STEP_ID="07b"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/lib/state.sh"
source "${BASE_DIR}/lib/os_catalog.sh"
source "${BASE_DIR}/lib/i18n.sh"
[ -z "${IAC_LANG:-}" ] && IAC_LANG="$(i18n_detect_default_lang)"
i18n_load "$IAC_LANG"
source "${BASE_DIR}/lib/common.sh"
CURRENT_STEP_ID="$STEP_ID"
init_step_log "$STEP_ID"
require_root

TARGET_OS="$(state_get ACTIVE_OS)"
BOOTED_BASE="$(state_get BOOTED_BASE)"
[ -z "$BOOTED_BASE" ] && BOOTED_BASE="$(detect_booted_base)"

if [ -z "$BOOTED_BASE" ]; then
    log_error "Could not resolve the currently booted base. Run step 00 again."
    echo "$(t step07b_cannot_detect_booted_base)"
    exit 1
fi

SIBLING_BASE=""
case "$BOOTED_BASE" in
    debian) SIBLING_BASE="ubuntu" ;;
    ubuntu) SIBLING_BASE="debian" ;;
    *) log_error "Unknown booted base '$BOOTED_BASE'."; exit 1 ;;
esac

echo "$(t step07b_title "$(t "source_base_${BOOTED_BASE}_name")" "$(t "source_base_${SIBLING_BASE}_name")")"
echo "$(t step07b_intro)"
echo

if ! confirm_yes_no "$(t step07b_confirm "$(t "source_base_${SIBLING_BASE}_name")")"; then
    log_info "$(t log_aborted_by_user "$STEP_ID")"
    echo "$(t aborted_by_user)"
    exit 0
fi

# --- locate the internal disk (same one the current root lives on) -----
ROOT_SRC_DEV="$(findmnt -no SOURCE / 2>/dev/null || true)"
INTERNAL_DISK_NAME="$(resolve_physical_disk "$ROOT_SRC_DEV")"
if [ -z "$INTERNAL_DISK_NAME" ]; then
    log_error "Could not resolve the internal disk from the current root device ($ROOT_SRC_DEV)."
    echo "$(t step07b_cannot_resolve_internal_disk)"
    exit 1
fi
INTERNAL_DISK="/dev/${INTERNAL_DISK_NAME}"
log_info "Internal disk: $INTERNAL_DISK"

# Sanity check: if this resolves to the external TARGET_DISK, we're
# currently booted from the external clone itself, not the internal
# host — this step's whole premise (bridge the *internal* sibling
# base's GRUB into this one) doesn't apply from there.
TARGET_DISK_FOR_CHECK="$(state_get TARGET_DISK)"
if [ -n "$TARGET_DISK_FOR_CHECK" ] && [ "$INTERNAL_DISK" = "$TARGET_DISK_FOR_CHECK" ]; then
    log_error "Resolved 'internal' disk ($INTERNAL_DISK) is the same as the external TARGET_DISK. This system appears to be booted from the external clone itself, not the internal host."
    echo "$(t step07b_booted_from_external "$INTERNAL_DISK")"
    exit 1
fi

# --- scan its partitions for the sibling base's root filesystem ---------
# The sibling's grub.cfg may live directly on its root partition, or on
# a SEPARATE /boot partition (the same layout this installer's own
# targets use, and the same layout Ubuntu/Asahi's own install uses:
# root and boot as two different partitions). Once a candidate root is
# identified by its /etc/os-release, its own /etc/fstab tells us where
# /boot actually is if it's separate.
SIBLING_PART=""
SIBLING_BOOT_PART=""
while IFS= read -r part; do
    [ -z "$part" ] && continue
    fstype="$(lsblk -no FSTYPE "/dev/${part}" 2>/dev/null || true)"
    case "$fstype" in
        ext4|ext3|ext2) ;;
        *) continue ;;
    esac
    [ "/dev/${part}" = "$ROOT_SRC_DEV" ] && continue

    TMP_MNT="$(mktemp -d)"
    if mount -o ro "/dev/${part}" "$TMP_MNT" 2>/dev/null; then
        if [ -r "${TMP_MNT}/etc/os-release" ]; then
            probed_id="$(set +u; . "${TMP_MNT}/etc/os-release"; echo "${ID:-}")"
            probed_base="${OS_RELEASE_ID_TO_BASE[$probed_id]:-}"
            if [ "$probed_base" = "$SIBLING_BASE" ]; then
                if [ -f "${TMP_MNT}/boot/grub/grub.cfg" ]; then
                    # grub.cfg lives right here: /boot isn't separate.
                    SIBLING_PART="/dev/${part}"
                elif [ -r "${TMP_MNT}/etc/fstab" ]; then
                    BOOT_UUID="$(awk '$2 == "/boot" {print $1}' "${TMP_MNT}/etc/fstab" 2>/dev/null | sed -n 's/^UUID=//p' | head -n1)"
                    if [ -n "$BOOT_UUID" ]; then
                        BOOT_DEV="$(blkid -U "$BOOT_UUID" 2>/dev/null || true)"
                        if [ -n "$BOOT_DEV" ]; then
                            BOOT_TMP_MNT="$(mktemp -d)"
                            if mount -o ro "$BOOT_DEV" "$BOOT_TMP_MNT" 2>/dev/null; then
                                if [ -f "${BOOT_TMP_MNT}/grub/grub.cfg" ]; then
                                    SIBLING_PART="/dev/${part}"
                                    SIBLING_BOOT_PART="$BOOT_DEV"
                                fi
                                umount "$BOOT_TMP_MNT"
                            fi
                            rmdir "$BOOT_TMP_MNT"
                        fi
                    fi
                fi
            fi
        fi
        umount "$TMP_MNT"
    fi
    rmdir "$TMP_MNT"
    [ -n "$SIBLING_PART" ] && break
done < <(lsblk -lno NAME "$INTERNAL_DISK" | tail -n +2)

if [ -z "$SIBLING_PART" ]; then
    log_error "Could not find a $SIBLING_BASE root partition with its own grub.cfg (directly or via a separate /boot) on $INTERNAL_DISK."
    echo "$(t step07b_sibling_not_found "$(t "source_base_${SIBLING_BASE}_name")")"
    exit 1
fi
if [ -n "$SIBLING_BOOT_PART" ]; then
    log_info "Sibling base ($SIBLING_BASE) found at $SIBLING_PART, with a separate /boot at $SIBLING_BOOT_PART"
else
    log_info "Sibling base ($SIBLING_BASE) found at $SIBLING_PART"
fi

# --- resolve this host's own boot/grub.cfg filesystem UUID --------------
HOST_BOOT_UUID="$(findmnt -no UUID -T /boot/grub/grub.cfg 2>/dev/null || true)"
if [ -z "$HOST_BOOT_UUID" ]; then
    log_error "Could not resolve the UUID of the filesystem holding this host's own /boot/grub/grub.cfg."
    exit 1
fi
log_info "Host's own grub.cfg filesystem UUID: $HOST_BOOT_UUID"

# --- mount the sibling read-write and drop the chainload script ---------
SIBLING_MNT="$(mktemp -d)"
run_cmd "mount sibling rw" mount "$SIBLING_PART" "$SIBLING_MNT"
if [ -n "$SIBLING_BOOT_PART" ]; then
    run_cmd "mount sibling boot rw" mount "$SIBLING_BOOT_PART" "${SIBLING_MNT}/boot"
fi

GRUBD_NAME="45_iac_cross_${BOOTED_BASE}"
GRUBD_PATH="${SIBLING_MNT}/etc/grub.d/${GRUBD_NAME}"

if [ -f "$GRUBD_PATH" ]; then
    log_info "$(t step07b_already_present "$GRUBD_NAME")"
    echo "$(t step07b_already_present "$GRUBD_NAME")"
else
    cat > "$GRUBD_PATH" <<EOF
#!/bin/bash
# Auto-generated by offensive-forensic-distros-installer-macbook-air-M1-M2-external-disk-luks
# (steps/07b_grub_cross_merge.sh). Do not edit by hand: it will be
# overwritten if the step runs again. Chainloads the live grub.cfg of
# the $(t "source_base_${BOOTED_BASE}_name") install on the internal
# disk (UUID=${HOST_BOOT_UUID}), so this entry always reflects whatever
# is native there, without duplicating any menuentry text.
set -e
echo "menuentry '$(t "source_base_${BOOTED_BASE}_name")' {"
echo "    insmod part_gpt"
echo "    insmod ext2"
echo "    search --no-floppy --fs-uuid --set=root ${HOST_BOOT_UUID}"
echo "    configfile /boot/grub/grub.cfg"
echo "}"
EOF
    chmod +x "$GRUBD_PATH"
    log_info "$(t step07b_script_written "$GRUBD_PATH")"
    echo "$(t step07b_script_written "$GRUBD_NAME")"
fi

# --- apply it immediately: chroot into the sibling and regenerate -------
echo "$(t step07b_regenerating "$(t "source_base_${SIBLING_BASE}_name")")"
for fs in proc sys dev; do
    mount --bind "/$fs" "${SIBLING_MNT}/$fs"
done
SIBLING_BACKUP="${SIBLING_MNT}/boot/grub/grub.orig.$(date '+%Y%m%d_%H%M%S')"
cp "${SIBLING_MNT}/boot/grub/grub.cfg" "$SIBLING_BACKUP"
echo "$(t step07b_sibling_backup "$SIBLING_BACKUP")"

if ! chroot "$SIBLING_MNT" update-grub; then
    log_error "update-grub failed inside the sibling chroot. Its previous grub.cfg is still backed up at $SIBLING_BACKUP."
    for fs in dev sys proc; do umount "${SIBLING_MNT}/$fs" 2>/dev/null || true; done
    [ -n "$SIBLING_BOOT_PART" ] && umount "${SIBLING_MNT}/boot" 2>/dev/null
    umount "$SIBLING_MNT" 2>/dev/null || true
    rmdir "$SIBLING_MNT" 2>/dev/null || true
    exit 1
fi

for fs in dev sys proc; do umount "${SIBLING_MNT}/$fs"; done
[ -n "$SIBLING_BOOT_PART" ] && umount "${SIBLING_MNT}/boot"
umount "$SIBLING_MNT"
rmdir "$SIBLING_MNT"

mark_os_step_done "$TARGET_OS" "$STEP_ID"
echo
echo "$(t step07b_done "$(t "source_base_${SIBLING_BASE}_name")")"
