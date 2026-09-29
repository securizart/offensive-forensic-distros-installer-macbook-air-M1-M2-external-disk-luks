#!/bin/bash
# forensics/ik4ln3/13_install_ik4ln3_writeblock.sh
#
# Installs the iK4lN3 forensic software write-blocker onto an Ubuntu/Asahi
# system: connected NON-system disks are held read-only at the block layer
# (blockdev --setro) at boot and on hot-plug, while the disks that carry the
# running OS (root, /boot, EFI, swap, and the LUKS/LVM chain beneath them)
# are detected and left writable. A CLI (ik4ln3-writeblock) and a small GUI
# (ik4ln3-mounter) let the investigator flip a disk writable on the fly.
#
# SAFETY: this touches udev rules, a systemd unit and automount settings.
# It does NOT touch GRUB or the kernel. The boot service refuses to arm if
# it cannot confirm the system disk, so a misdetection leaves everything
# writable rather than freezing the OS. Test in a VM before real hardware.

set -u -o pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/writeblock" && pwd)"
: "${MASTER_LOG:=/tmp/ik4ln3-standalone.log}"
if ! declare -F log_info >/dev/null 2>&1; then
    log_info(){ printf '[INFO] %s\n' "$*"; }
    log_warn(){ printf '\342\232\240 %s\n' "$*" >&2; }
    log_error(){ printf '\342\234\226 %s\n' "$*" >&2; }
    log_ok(){ printf '[OK] %s\n' "$*"; }
fi
[ "$(id -u)" -eq 0 ] || { log_error "Run as root (sudo)."; exit 1; }

# 1) dependencies (GUI + block tools). util-linux (blockdev) is already
#    present; yad powers the Mounter GUI. No kernel/GPU packages involved.
log_info "Installing GUI dependency (yad)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends yad >/dev/null 2>&1 \
    || log_warn "Could not install yad; the CLI still works, GUI falls back to zenity."

# 2) place the files
install -d /usr/lib/ik4ln3 /usr/share/doc/ik4ln3
install -m 0644 "${SRC}/writeblock-lib.sh"      /usr/lib/ik4ln3/writeblock-lib.sh
install -m 0755 "${SRC}/writeblock-udev"        /usr/lib/ik4ln3/writeblock-udev
install -m 0755 "${SRC}/writeblock-boot"        /usr/lib/ik4ln3/writeblock-boot
install -m 0755 "${SRC}/ik4ln3-writeblock"      /usr/local/bin/ik4ln3-writeblock
install -m 0755 "${SRC}/ik4ln3-mounter"         /usr/local/bin/ik4ln3-mounter
install -m 0644 "${SRC}/99-ik4ln3-writeblock.rules" /etc/udev/rules.d/99-ik4ln3-writeblock.rules
install -m 0644 "${SRC}/ik4ln3-writeblock.service"  /etc/systemd/system/ik4ln3-writeblock.service
install -m 0644 "${SRC}/ik4ln3-mounter.desktop"     /usr/share/applications/ik4ln3-mounter.desktop
[ -f "${SRC}/README.md" ] && install -m 0644 "${SRC}/README.md" /usr/share/doc/ik4ln3/writeblock.md
log_ok "Files installed."

# 3) stop the desktop from auto-mounting removable media writable behind our
#    back (defence in depth; the block-level RO is the real guarantee).
if [ -n "${SUDO_USER:-}" ]; then
    u="$SUDO_USER"; uid="$(id -u "$u")"
    sudo -u "$u" env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        gsettings set org.mate.media-handling automount false 2>/dev/null || true
    sudo -u "$u" env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        gsettings set org.mate.media-handling automount-open false 2>/dev/null || true
    log_info "Disabled MATE automount for '$u' (evidence media won't auto-mount writable)."
fi

# 4) reload udev + enable the boot service (also arms it now)
udevadm control --reload-rules 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now ik4ln3-writeblock.service 2>&1 | sed 's/^/  /' || \
    log_warn "Could not enable the service now; it will run on next boot."

echo
# --- Mounter shortcut on the desktop ----------------------------------------
# Put the write-blocker GUI on the desktop (skel for future users + the
# current user), marked trusted so Caja launches it without the warning.
if [ -f /usr/share/applications/ik4ln3-mounter.desktop ]; then
    for base in /etc/skel ${SUDO_USER:+/home/$SUDO_USER}; do
        install -d "${base}/Desktop"
        install -m 0755 /usr/share/applications/ik4ln3-mounter.desktop \
            "${base}/Desktop/ik4ln3-mounter.desktop"
    done
    if [ -n "${SUDO_USER:-}" ]; then
        chown "${SUDO_USER}:${SUDO_USER}" "/home/${SUDO_USER}/Desktop/ik4ln3-mounter.desktop" 2>/dev/null || true
        uid="$(id -u "$SUDO_USER" 2>/dev/null)"
        d="/home/${SUDO_USER}/Desktop/ik4ln3-mounter.desktop"
        sudo -u "$SUDO_USER" env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
            gio set "$d" metadata::caja-trusted-launcher true 2>/dev/null \
            || setfattr -n user.metadata::caja-trusted-launcher -v true "$d" 2>/dev/null || true
    fi
    log_ok "Mounter shortcut placed on the desktop."
fi

log_ok "iK4lN3 write-blocker installed and armed."
ik4ln3-writeblock status 2>/dev/null | sed 's/^/  /'
cat <<'NOTE'

  ---------------------------------------------------------------
  Software write-blocking is a SAFETY NET, not a hardware write
  blocker. blockdev --setro and the 'ro' flag instruct the drivers
  but do not stop every possible kernel write, and the SG_IO
  interface can send SCSI commands straight past the flag. For
  court-defensible acquisition, use a hardware write blocker and
  verify with hashes.

  Controls:
    ik4ln3-writeblock status         # see all disks + state
    ik4ln3-writeblock allow sdX      # make one disk writable
    ik4ln3-writeblock block sdX      # re-block it
    ik4ln3-writeblock off | on       # global disarm / arm
    ik4ln3-mounter                   # GUI (in the Forensic Tools menu)
  ---------------------------------------------------------------
NOTE
