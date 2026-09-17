#!/bin/bash
# steps/07_grub_merge.sh
# Based on the original "finalize filesystem" script. Runs OUTSIDE the
# chroot (after leaving it with `exit`), with the active OS's disk still
# mounted.
#
# NOTE on several operating systems on the same disk: this target's
# native menu entries get baked into their own persistent
# /etc/grub.d/46_iac_merged_<target> script (see below), not spliced
# into grub.cfg as one-time text. That means every OS already
# processed for this host keeps showing up automatically on every
# future update-grub — a kernel update, or another target's own step
# 07/07b regenerating grub.cfg — without needing this target's disk
# mounted or step 07 re-run for it. (An earlier version of this step
# spliced text directly into grub.cfg instead; that copy silently
# disappeared the next time anything else ran update-grub on this
# host, since it was never captured in /etc/grub.d/ at all.)
STEP_ID="07"
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

# The external disk is still mounted at $MNT at this point: take the
# chance to leave the already-updated state there before the user
# reboots and boots into the newly cloned install.
sync_state_to_mount "$MNT"

mark_os_step_done "$TARGET_OS" "$STEP_ID"
echo
echo "$(t step07_done)"
