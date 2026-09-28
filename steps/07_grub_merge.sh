#!/bin/bash
# steps/07_grub_merge.sh
# Based on the original "finalize filesystem" script. Runs OUTSIDE the
# chroot (after leaving it with `exit`), with the active OS's disk still
# mounted.
#
# v1.5.1: this step now covers what used to be split across 07 and the
# separate, optional 07b — merged here because 07b being optional meant
# it depended on someone remembering to run it, from both sides, for
# every pair. Four phases, all automatic:
#   1. Host <- target (unchanged from v1.5.0): this target's native
#      menu entries get persisted into the CURRENTLY BOOTED host's own
#      grub.d.
#   2. Target: gets a SELF-DISCOVERING grub.d script that, every time
#      ITS OWN grub-mkconfig runs (now, and again on every future
#      kernel update inside it), scans this same external disk for
#      sibling boot_<os> partitions (kali/parrot/sift/remnux) and
#      chainloads whichever it finds — reading only their unencrypted
#      /boot, never their LUKS root. This is what lets Kali see Parrot
#      even though Kali's own LUKS root can't be written to from
#      outside a Kali session.
#   3. Host <-> sibling internal base (was 07b, now automatic, no
#      confirmation prompt needed since it's non-destructive and always
#      backs up first).
#   4. Target: also gets static entries for BOTH internal bases
#      (Debian/Asahi and Ubuntu/Asahi), discovered the same way phase 3
#      does — this is the "Kali doesn't currently point back at
#      Debian/Asahi at all" gap phase 1 alone never closed.
#
# NOTE on several operating systems on the same disk: this target's
# native menu entries get baked into their own persistent
# /etc/grub.d/46_iac_merged_<target> script (see below), not spliced
# into grub.cfg as one-time text. That means every OS already
# processed for this host keeps showing up automatically on every
# future update-grub — a kernel update, or another target's own step 07
# regenerating grub.cfg — without needing this target's disk mounted or
# step 07 re-run for it. (An earlier version of this step spliced text
# directly into grub.cfg instead; that copy silently disappeared the
# next time anything else ran update-grub on this host, since it was
# never captured in /etc/grub.d/ at all.)
STEP_ID="07"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/bootstrap.sh
source "${BASE_DIR}/lib/bootstrap.sh"
step_bootstrap "$STEP_ID"

TARGET_OS="$(state_get ACTIVE_OS)"
MNT="$(os_mountpoint "$TARGET_OS")"

echo "$(t step07_title "$(t "os_${TARGET_OS}_name")")"
echo "$(t step07_intro)"
echo

if [ ! -f "${MNT}/boot/grub/grub.cfg" ]; then
    log_error "${MNT}/boot/grub/grub.cfg does not exist. Is ${MNT} still mounted? Repeat step 05/06."
    exit 1
fi

if [ -f /base_inst_kali/preparation/grub ]; then
    run_cmd "copy host grub" cp /base_inst_kali/preparation/grub /etc/default/grub
fi
if [ -f /base_inst_kali/preparation/modules.txt ]; then
    run_cmd "copy host modules" cp /base_inst_kali/preparation/modules.txt /etc/initramfs-tools/modules
fi

# Ubuntu ships /etc/default/grub with GRUB_TIMEOUT_STYLE=hidden and
# GRUB_TIMEOUT=0 by default (and preparation/grub, if used, may carry
# the same). With those, the menu never shows at all — defeating the
# whole point of merging in an extra boot entry, since there'd be no
# way to actually pick it. Force it visible with a real timeout,
# overriding whatever was just copied in above.
grub_set_var GRUB_TIMEOUT_STYLE menu
grub_set_var GRUB_TIMEOUT 10
# GRUB_DEFAULT=saved (common on Ubuntu) means an earlier MANUAL pick
# from the menu (e.g. testing that a merged external entry boots) gets
# remembered and reused automatically on every later boot — including
# steps 02/03's own unattended reboots, silently landing back on the
# external clone instead of this host on the next run. Force position
# 0 (whatever menuentry appears first — this host's own native kernel,
# always listed ahead of anything merged in below) so the automatic
# reboots during this installer's own steps can't drift onto a
# previously-selected entry.
grub_set_var GRUB_DEFAULT 0
run_cmd "clear saved GRUB default" grub-editenv /boot/grub/grubenv unset saved_entry
# Ubuntu's own /etc/grub.d/00_header additionally checks GRUB's
# "recordfail" environment variable at boot: on a successful previous
# boot (the normal case), it forces timeout=0 at runtime regardless of
# GRUB_TIMEOUT above, and only honors a real timeout once a failure has
# been recorded. GRUB_RECORDFAIL_TIMEOUT is the variable 00_header
# checks for that case — without it, the menu never actually waits.
grub_set_var GRUB_RECORDFAIL_TIMEOUT 10
# Debian/Ubuntu ship with GRUB_DISABLE_OS_PROBER=true by default (a
# safety default, since os-prober mounts other partitions to inspect
# them) — usually commented out rather than removed, which is why
# grub_set_var (not a plain grep/sed for an uncommented line) matters
# here specifically: a naive check would miss the commented default and
# append a redundant active line after it instead of replacing it.
#
# Deliberately kept DISABLED (true), not enabled: os-prober guesses
# boot parameters (root=, cryptdevice=, initrd path...) by inspecting
# the other partition directly, rather than loading that OS's own
# grub.cfg — confirmed on real hardware that its guessed entry for a
# LUKS-rooted sibling base doesn't pick up that base's real parameters
# and fails to boot. Step 07b's own 45_iac_cross_<base> script already
# covers this properly (via `configfile`, loading the sibling's live
# grub.cfg as-is), so os-prober's entry would just be a second, less
# reliable path to the same thing.
grub_set_var GRUB_DISABLE_OS_PROBER true
log_info "Forced GRUB_TIMEOUT_STYLE=menu, GRUB_TIMEOUT=10 and GRUB_RECORDFAIL_TIMEOUT=10 in /etc/default/grub so the boot menu is actually visible and waits. GRUB_DISABLE_OS_PROBER kept true: step 07b's own cross-link entry is the reliable way to reach the sibling base."
echo "$(t step07_grub_menu_visible)"

# GRUB's own text prompts (including the LUKS passphrase asked by
# `cryptomount` for the merged entry below) do NOT inherit the OS's
# keyboard layout — GRUB defaults to a raw US-like scancode mapping
# unless a keymap is explicitly compiled and loaded. Do this once per
# host, based on the host's own /etc/default/keyboard, so typing a
# passphrase with non-US characters/positions actually works as typed.
#
# Apply the user's own preparation/keyboard file here too (if present):
# Ubuntu/Asahi's own install can default XKBLAYOUT to "us" regardless
# of the host's real layout, and step 01 deliberately skips copying
# this file on Ubuntu/Asahi (see its own note), so this may be the
# first point in the whole flow where it actually gets applied.
if [ -f /base_inst_kali/preparation/keyboard ]; then
    run_cmd "copy host keyboard (for GRUB keymap)" cp /base_inst_kali/preparation/keyboard /etc/default/keyboard
else
    log_warn "/base_inst_kali/preparation/keyboard does not exist; using whatever XKBLAYOUT is already in /etc/default/keyboard (create that file with the right XKBLAYOUT if the GRUB keymap ends up wrong)."
fi

GRUB_KEYMAP_SCRIPT="/etc/grub.d/05_iac_keymap"
XKBLAYOUT="$(grep -oP '^XKBLAYOUT="\K[^"]+' /etc/default/keyboard 2>/dev/null || true)"
if [ -n "$XKBLAYOUT" ]; then
    mkdir -p /boot/grub/layouts
    if grub-kbdcomp -o "/boot/grub/layouts/${XKBLAYOUT}.gkb" "$XKBLAYOUT" >/dev/null 2>&1; then
        cat > "$GRUB_KEYMAP_SCRIPT" <<EOF
#!/bin/sh
# Auto-generated by this installer (step 07) so GRUB's own text
# prompts (including the LUKS passphrase) use the host's real
# keyboard layout ('${XKBLAYOUT}') instead of defaulting to US.
# Regenerated on every run of step 07 — do not edit by hand.
cat <<INNEREOF
insmod keylayouts
keymap /boot/grub/layouts/${XKBLAYOUT}.gkb
INNEREOF
EOF
        chmod +x "$GRUB_KEYMAP_SCRIPT"
        log_info "GRUB keymap script installed for layout '${XKBLAYOUT}'."
        echo "$(t step07_keymap_installed "$XKBLAYOUT")"
    else
        log_warn "grub-kbdcomp failed for layout '${XKBLAYOUT}'; GRUB prompts (including the LUKS passphrase) will stay on the default US layout."
    fi
else
    log_warn "Could not resolve XKBLAYOUT from /etc/default/keyboard; skipping GRUB keymap setup. GRUB prompts (including the LUKS passphrase) will stay on the default US layout."
fi

run_cmd "update-initramfs host" update-initramfs -c -k all

echo "$(t step07_merging)"
# On real hardware this grub.cfg can end up with more than one
# BEGIN/END /etc/grub.d/10_linux marker pair (e.g. one full block plus
# a second, near-empty one from a re-run of grub-mkconfig during step
# 06). awk then returns multiple line numbers, which broke the
# arithmetic below outright.
#
# Use the FIRST complete pair only (first BEGIN, its own matching
# first END) — NOT first-BEGIN-to-last-END. Spanning across separate
# marker pairs previously spliced in whatever sits between them into
# the host's grub.cfg, which isn't necessarily valid GRUB script on
# its own and produced a parse error (GRUB drops to the `grub>`
# command prompt instead of showing the menu at all). The first pair
# is always a complete, self-contained unit exactly as grub-mkconfig
# generated it, so it's always safe to extract on its own.
A1_ALL="$(awk '/BEGIN \/etc\/grub.d\/10_linux/{ print NR }' "${MNT}/boot/grub/grub.cfg")"
B1_ALL="$(awk '/END \/etc\/grub.d\/10_linux/{ print NR }' "${MNT}/boot/grub/grub.cfg")"
a1="$(printf '%s\n' "$A1_ALL" | head -n1)"
b1="$(printf '%s\n' "$B1_ALL" | head -n1)"

if [ -z "$a1" ] || [ -z "$b1" ]; then
    log_error "Could not locate the expected markers in ${MNT}/boot/grub/grub.cfg. Review manually before continuing."
    exit 1
fi

if [ "$(printf '%s\n' "$A1_ALL" | wc -l)" -gt 1 ] || [ "$(printf '%s\n' "$B1_ALL" | wc -l)" -gt 1 ]; then
    log_warn "Found more than one BEGIN/END /etc/grub.d/10_linux marker pair in ${MNT}/boot/grub/grub.cfg (BEGIN at: $(printf '%s ' $A1_ALL)| END at: $(printf '%s ' $B1_ALL)); using only the first pair (lines ${a1}-${b1}) — the rest is ignored, since it isn't guaranteed to be valid GRUB script on its own."
fi

a2=$((a1+1))
b2=$((b1-1))
log_info "Markers ($TARGET_OS): a1=$a1 b1=$b1 a2=$a2 b2=$b2"

# Persist this target's native menu entries as their own grub.d
# script, INSTEAD of one-time splicing them into the current
# grub.cfg (the previous approach): grub.cfg gets fully regenerated
# by grub-mkconfig on every update-grub, from whatever's in
# /etc/grub.d/ at that moment — a one-time splice is not there, so it
# silently disappeared the next time ANYTHING ran update-grub on this
# host (a kernel update, or step 07b's own update-grub when cross-
# linking a *different* target). Baking this target's entries into
# their own script here means they keep showing up automatically on
# every future update-grub, for any target already processed, without
# needing that target's disk mounted or step 07 re-run for it.
MERGED_CONTENT="$(sed -n "${a2},${b2}p" "${MNT}/boot/grub/grub.cfg")"
PERSIST_SCRIPT="/etc/grub.d/46_iac_merged_${TARGET_OS}"
{
    echo '#!/bin/bash'
    echo "# Auto-generated by offensive-forensic-distros-installer-macbook-air-M1-M2-external-disk-luks"
    echo "# (step 07) for target '${TARGET_OS}'. Do not edit by hand: it will be"
    echo "# overwritten if step 07 runs again for this target. Bakes in the"
    echo "# native GRUB entries this target's own grub-mkconfig produced, so"
    echo "# they survive future update-grub runs on this host without needing"
    echo "# this target's disk mounted."
    echo 'set -e'
    echo "cat <<'IAC_MERGED_EOF'"
    printf '%s\n' "$MERGED_CONTENT"
    echo 'IAC_MERGED_EOF'
} > "$PERSIST_SCRIPT"
chmod +x "$PERSIST_SCRIPT"
log_info "Persistent GRUB entry script written: $PERSIST_SCRIPT"
echo "$(t step07_persist_script_written "$PERSIST_SCRIPT")"

BACKUP="/boot/grub/grub.orig.$(date '+%Y%m%d_%H%M%S')"
run_cmd "backup grub.cfg" cp /boot/grub/grub.cfg "$BACKUP"
echo "$(t step07_backup_orig "$BACKUP")"
run_cmd "update-grub host" update-grub

# --- Phase 2: self-discovering sibling script, written INTO the target ---
# Written to $MNT (the target's own root, writable right now) rather
# than /etc/grub.d/ (that would be the HOST's own, already handled by
# phase 1 above). Reads only /boot partitions — never any sibling's
# LUKS root — so it works regardless of which siblings exist yet, or
# are added later.
echo "$(t step07_disk_siblings_script "${MNT}/etc/grub.d/47_iac_disk_siblings")"
DISK_SIBLINGS_SCRIPT="${MNT}/etc/grub.d/47_iac_disk_siblings"
cat > "$DISK_SIBLINGS_SCRIPT" <<'DISK_SIBLINGS_EOF'
#!/bin/bash
# Auto-generated by offensive-forensic-distros-installer-macbook-air-M1-M2-external-disk-luks
# (step 07) for target '@@TARGET_OS@@'. Do not edit by hand: it will be
# overwritten if step 07 runs again for this target.
#
# Runs at grub-mkconfig time — now, and again on every future kernel
# update inside this OS — and dynamically discovers which OTHER
# offensive-distro targets are currently present on THIS SAME external
# disk (by their well-known boot_<os> partition label), chainloading
# into whichever it finds. Self-healing: a sibling installed AFTER this
# one still shows up here, the next time this OS's own grub-mkconfig
# runs (or immediately, via the "Sync GRUB now" menu option). Reads
# only each sibling's own /boot partition, which is never encrypted
# (unlike its root) — no LUKS passphrase needed for any target but this
# one.
set -e
for sibling_id in kali parrot sift remnux; do
    [ "$sibling_id" = "@@TARGET_OS@@" ] && continue
    dev="$(blkid -L "boot_${sibling_id}" 2>/dev/null || true)"
    [ -z "$dev" ] && continue
    uuid="$(blkid -s UUID -o value "$dev" 2>/dev/null || true)"
    [ -z "$uuid" ] && continue
    echo "menuentry '${sibling_id}' {"
    echo "    insmod part_gpt"
    echo "    insmod ext2"
    echo "    search --no-floppy --fs-uuid --set=root ${uuid}"
    echo "    configfile /grub/grub.cfg"
    echo "}"
done
DISK_SIBLINGS_EOF
sed -i "s/@@TARGET_OS@@/${TARGET_OS}/g" "$DISK_SIBLINGS_SCRIPT"
chmod +x "$DISK_SIBLINGS_SCRIPT"
log_info "Self-discovering sibling script written: $DISK_SIBLINGS_SCRIPT"

# Apply it right away: any sibling target already provisioned on this
# disk shows up immediately, instead of waiting for this target's next
# own grub-mkconfig run.
if chroot "$MNT" update-grub; then
    log_info "Regenerated ${TARGET_OS}'s own grub.cfg with the disk-siblings script applied."
else
    log_warn "chroot update-grub failed for ${TARGET_OS} after writing the disk-siblings script; it will still apply on this target's own next boot/kernel update."
fi

# --- Phase 3: host <-> sibling internal base (was the separate,
# optional step 07b) ------------------------------------------------------
# Non-fatal throughout: unlike phases 1-2 above (which are this step's
# core job), this bridges two INTERNAL bases that may simply not both
# exist yet (e.g. only Debian/Asahi installed so far) — a warning and
# skip is correct here, not aborting the whole step.
echo "$(t step07b_title_generic)"
BOOTED_BASE="$(state_get BOOTED_BASE)"
[ -z "$BOOTED_BASE" ] && BOOTED_BASE="$(detect_booted_base)"

SIBLING_PART=""
SIBLING_BOOT_PART=""
SIBLING_OWN_BOOT_UUID=""
HOST_BOOT_UUID=""

if [ -z "$BOOTED_BASE" ]; then
    log_warn "Could not resolve the currently booted base; skipping the internal-base cross-link (phases 3-4)."
else
    SIBLING_BASE=""
    case "$BOOTED_BASE" in
        debian) SIBLING_BASE="ubuntu" ;;
        ubuntu) SIBLING_BASE="debian" ;;
        *) log_warn "Unknown booted base '$BOOTED_BASE'; skipping the internal-base cross-link." ;;
    esac

    if [ -n "$SIBLING_BASE" ]; then
        ROOT_SRC_DEV="$(findmnt -no SOURCE / 2>/dev/null || true)"
        INTERNAL_DISK_NAME="$(resolve_physical_disk "$ROOT_SRC_DEV")"
        TARGET_DISK_FOR_CHECK="$(state_get TARGET_DISK)"
        if [ -z "$INTERNAL_DISK_NAME" ]; then
            log_warn "Could not resolve the internal disk from the current root device ($ROOT_SRC_DEV); skipping the internal-base cross-link."
        elif [ -n "$TARGET_DISK_FOR_CHECK" ] && [ "/dev/${INTERNAL_DISK_NAME}" = "$TARGET_DISK_FOR_CHECK" ]; then
            log_warn "This system appears to be booted from the external clone itself, not the internal host; skipping the internal-base cross-link."
        else
            INTERNAL_DISK="/dev/${INTERNAL_DISK_NAME}"
            log_info "Internal disk: $INTERNAL_DISK"

            # Scan its partitions for the sibling base's root (and, if
            # separate, its own /boot) — same technique as before:
            # identify each candidate by its own /etc/os-release.
            while IFS= read -r part; do
                [ -z "$part" ] && continue
                fstype="$(lsblk -no FSTYPE "/dev/${part}" 2>/dev/null || true)"
                case "$fstype" in ext4|ext3|ext2) ;; *) continue ;; esac
                [ "/dev/${part}" = "$ROOT_SRC_DEV" ] && continue

                TMP_MNT="$(mktemp -d)"
                if mount -o ro "/dev/${part}" "$TMP_MNT" 2>/dev/null; then
                    if [ -r "${TMP_MNT}/etc/os-release" ]; then
                        probed_id="$(set +u; . "${TMP_MNT}/etc/os-release"; echo "${ID:-}")"
                        set +u
                        probed_base="${OS_RELEASE_ID_TO_BASE[$probed_id]:-}"
                        set -u
                        if [ "$probed_base" = "$SIBLING_BASE" ]; then
                            if [ -f "${TMP_MNT}/boot/grub/grub.cfg" ]; then
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
                log_warn "Could not find a $SIBLING_BASE root partition with its own grub.cfg on $INTERNAL_DISK yet (probably not installed). Skipping the internal-base cross-link for now — it'll work once it exists."
            else
                log_info "Sibling base ($SIBLING_BASE) found at $SIBLING_PART${SIBLING_BOOT_PART:+, with a separate /boot at $SIBLING_BOOT_PART}"

                HOST_BOOT_UUID="$(findmnt -no UUID -T /boot/grub/grub.cfg 2>/dev/null || true)"
                if [ -z "$HOST_BOOT_UUID" ]; then
                    log_warn "Could not resolve this host's own grub.cfg filesystem UUID; skipping the internal-base cross-link."
                    SIBLING_PART=""
                else
                    SIBLING_MNT="$(mktemp -d)"
                    run_cmd "mount sibling rw" mount "$SIBLING_PART" "$SIBLING_MNT"
                    [ -n "$SIBLING_BOOT_PART" ] && run_cmd "mount sibling boot rw" mount "$SIBLING_BOOT_PART" "${SIBLING_MNT}/boot"

                    SIBLING_OWN_BOOT_UUID="$(blkid -s UUID -o value "${SIBLING_BOOT_PART:-$SIBLING_PART}" 2>/dev/null || true)"

                    GRUBD_NAME="45_iac_cross_${BOOTED_BASE}"
                    GRUBD_PATH="${SIBLING_MNT}/etc/grub.d/${GRUBD_NAME}"
                    if [ -f "$GRUBD_PATH" ]; then
                        log_info "$(t step07b_already_present "$GRUBD_NAME")"
                    else
                        cat > "$GRUBD_PATH" <<EOF
#!/bin/bash
# Auto-generated by offensive-forensic-distros-installer-macbook-air-M1-M2-external-disk-luks
# (step 07, phase 3). Do not edit by hand: it will be overwritten if
# this step runs again. Chainloads the live grub.cfg of the
# $(t "source_base_${BOOTED_BASE}_name") install on the internal disk
# (UUID=${HOST_BOOT_UUID}), so this entry always reflects whatever is
# native there, without duplicating any menuentry text.
set -e
echo "menuentry '$(t "source_base_${BOOTED_BASE}_name")' {"
echo "    insmod part_gpt"
echo "    insmod ext2"
echo "    search --no-floppy --fs-uuid --set=root ${HOST_BOOT_UUID}"
echo "    configfile /grub/grub.cfg"
echo "}"
EOF
                        chmod +x "$GRUBD_PATH"
                        log_info "$(t step07b_script_written "$GRUBD_PATH")"
                    fi

                    for fs in proc sys dev; do mount --bind "/$fs" "${SIBLING_MNT}/$fs"; done
                    SIBLING_BACKUP="${SIBLING_MNT}/boot/grub/grub.orig.$(date '+%Y%m%d_%H%M%S')"
                    cp "${SIBLING_MNT}/boot/grub/grub.cfg" "$SIBLING_BACKUP"
                    if ! chroot "$SIBLING_MNT" update-grub; then
                        log_warn "update-grub failed inside the sibling chroot. Its previous grub.cfg is still backed up at $SIBLING_BACKUP."
                    fi
                    for fs in dev sys proc; do umount "${SIBLING_MNT}/$fs" 2>/dev/null || true; done
                    [ -n "$SIBLING_BOOT_PART" ] && umount "${SIBLING_MNT}/boot" 2>/dev/null || true
                    umount "$SIBLING_MNT" 2>/dev/null || true
                    rmdir "$SIBLING_MNT" 2>/dev/null || true
                    echo "$(t step07b_done "$(t "source_base_${SIBLING_BASE}_name")")"
                fi
            fi
        fi
    fi
fi

# --- Phase 4: target learns BOTH internal bases --------------------------
# The reverse of phase 1: without this, Kali's own boot menu never
# offered a way back to Debian/Asahi (or to Ubuntu/Asahi) at all.
# Written into $MNT directly (writable right now); static, not
# self-discovering like phase 2's script — the internal bases' own
# UUIDs are stable, so there's no staleness concern the way there would
# be for externals added later.
if [ -n "$HOST_BOOT_UUID" ]; then
    echo "$(t step07_target_learns_host "$(t "os_${TARGET_OS}_name")")"
    HOST_LINK_SCRIPT="${MNT}/etc/grub.d/48_iac_internal_${BOOTED_BASE}"
    cat > "$HOST_LINK_SCRIPT" <<EOF
#!/bin/bash
# Auto-generated by offensive-forensic-distros-installer-macbook-air-M1-M2-external-disk-luks
# (step 07, phase 4) for target '${TARGET_OS}'. Do not edit by hand.
# Chainloads the $(t "source_base_${BOOTED_BASE}_name") internal base
# (UUID=${HOST_BOOT_UUID}).
set -e
echo "menuentry '$(t "source_base_${BOOTED_BASE}_name")' {"
echo "    insmod part_gpt"
echo "    insmod ext2"
echo "    search --no-floppy --fs-uuid --set=root ${HOST_BOOT_UUID}"
echo "    configfile /grub/grub.cfg"
echo "}"
EOF
    chmod +x "$HOST_LINK_SCRIPT"
fi
if [ -n "$SIBLING_OWN_BOOT_UUID" ]; then
    SIBLING_LINK_SCRIPT="${MNT}/etc/grub.d/48_iac_internal_${SIBLING_BASE}"
    cat > "$SIBLING_LINK_SCRIPT" <<EOF
#!/bin/bash
# Auto-generated by offensive-forensic-distros-installer-macbook-air-M1-M2-external-disk-luks
# (step 07, phase 4) for target '${TARGET_OS}'. Do not edit by hand.
# Chainloads the $(t "source_base_${SIBLING_BASE}_name") internal base
# (UUID=${SIBLING_OWN_BOOT_UUID}).
set -e
echo "menuentry '$(t "source_base_${SIBLING_BASE}_name")' {"
echo "    insmod part_gpt"
echo "    insmod ext2"
echo "    search --no-floppy --fs-uuid --set=root ${SIBLING_OWN_BOOT_UUID}"
echo "    configfile /grub/grub.cfg"
echo "}"
EOF
    chmod +x "$SIBLING_LINK_SCRIPT"
fi
if [ -n "$HOST_BOOT_UUID" ] || [ -n "$SIBLING_OWN_BOOT_UUID" ]; then
    chroot "$MNT" update-grub || log_warn "chroot update-grub failed for ${TARGET_OS} after writing the internal-base links; it will still apply on this target's own next boot/kernel update."
fi

# The external disk is still mounted at $MNT at this point: take the
# chance to leave the already-updated state there before the user
# reboots and boots into the newly cloned install.
sync_state_to_mount "$MNT"

mark_os_step_done "$TARGET_OS" "$STEP_ID"
echo
echo "$(t step07_done "$(t "os_${TARGET_OS}_name")" "$(t "os_${TARGET_OS}_name")")"
echo "$(t generic_rebooting)"
sleep 5
reboot
