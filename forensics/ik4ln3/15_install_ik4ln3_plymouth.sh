#!/bin/bash
# forensics/ik4ln3/15_install_ik4ln3_plymouth.sh
#
# Installs the iK4lN3 Plymouth boot splash (logo + orange paw-print trace +
# styled LUKS password prompt) and makes it the default, then rebuilds the
# initramfs so the theme is used at the encrypted-disk unlock stage too.
#
# IMPORTANT / honest caveats:
#  - This rebuilds the initramfs (update-initramfs -u). It does NOT touch
#    the kernel or GRUB, but it is a boot-affecting step: snapshot first,
#    and never run it in the same pass as a kernel change.
#  - The graphical splash only shows if the kernel cmdline carries
#    "splash quiet". We do NOT edit GRUB here (that's owned by the GRUB
#    steps); if the cmdline lacks "splash", boot stays in text mode.
#  - On Apple Silicon / Asahi, Plymouth often can't paint during the very
#    early initramfs LUKS stage (the agx GPU/framebuffer isn't up yet), so
#    the disk-unlock prompt may appear as plain text even with this theme
#    installed. That's expected; the theme is written to degrade to a
#    legible text prompt. The later boot stage usually shows the splash.

set -u -o pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/plymouth" && pwd)"
if ! declare -F log_info >/dev/null 2>&1; then
    log_info(){ printf '[INFO] %s\n' "$*"; }
    log_warn(){ printf '\342\232\240 %s\n' "$*" >&2; }
    log_error(){ printf '\342\234\226 %s\n' "$*" >&2; }
    log_ok(){ printf '[OK] %s\n' "$*"; }
fi
[ "$(id -u)" -eq 0 ] || { log_error "Run as root (sudo)."; exit 1; }

# plymouth present?
if ! command -v plymouth-set-default-theme >/dev/null 2>&1; then
    log_info "Installing plymouth..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        plymouth plymouth-themes >/dev/null 2>&1 || \
        log_warn "Could not install plymouth; boot splash may not apply."
fi

# 1) place the theme
install -d /usr/share/plymouth/themes/ik4ln3
install -m 0644 "${SRC}/ik4ln3/ik4ln3.plymouth" /usr/share/plymouth/themes/ik4ln3/
install -m 0644 "${SRC}/ik4ln3/ik4ln3.script"   /usr/share/plymouth/themes/ik4ln3/
install -m 0644 "${SRC}/ik4ln3/background.png"  /usr/share/plymouth/themes/ik4ln3/
install -m 0644 "${SRC}/ik4ln3/logo.png"        /usr/share/plymouth/themes/ik4ln3/
install -m 0644 "${SRC}/ik4ln3/paw.png"         /usr/share/plymouth/themes/ik4ln3/
log_ok "Theme installed under /usr/share/plymouth/themes/ik4ln3."

# 2) make it the default
if plymouth-set-default-theme ik4ln3 2>/dev/null; then
    log_ok "iK4lN3 set as the default Plymouth theme."
else
    log_warn "plymouth-set-default-theme failed; setting the alternative directly."
    update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
        default.plymouth /usr/share/plymouth/themes/ik4ln3/ik4ln3.plymouth 200 2>/dev/null || true
    update-alternatives --set default.plymouth \
        /usr/share/plymouth/themes/ik4ln3/ik4ln3.plymouth 2>/dev/null || true
fi

# 3) rebuild the initramfs so the theme is present at the LUKS stage
log_info "Rebuilding the initramfs (needed for the theme at the disk-unlock prompt)..."
if update-initramfs -u 2>&1 | sed 's/^/  /'; then
    log_ok "initramfs rebuilt."
else
    log_warn "update-initramfs reported problems; review before rebooting."
fi

echo
log_ok "iK4lN3 boot splash installed."
echo "  Reboot to see it. If the LUKS prompt appears as text on your"
echo "  Apple Silicon hardware, that's the expected early-boot limitation;"
echo "  the theme still shows on the later boot stage."
echo
echo "  NOTE: the graphical splash needs 'splash quiet' on the kernel"
echo "  cmdline. This script does NOT edit GRUB. If boot stays in text"
echo "  mode, add 'splash quiet' via your GRUB config and re-run the GRUB"
echo "  steps — never mix that with a kernel change."
