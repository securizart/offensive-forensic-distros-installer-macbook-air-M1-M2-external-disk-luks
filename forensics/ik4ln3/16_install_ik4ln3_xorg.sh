#!/bin/bash
# forensics/ik4ln3/16_install_ik4ln3_xorg.sh
# Installs the Xorg "no glamor" fix so the MATE (Xorg) session starts on
# Apple Silicon instead of crashing (glamor -> llvmpipe -> GLX segfault).
# Software rendering; fine for a forensic desktop. Harmless on non-Asahi.
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/xorg" && pwd)"
if ! declare -F log_info >/dev/null 2>&1; then
    log_info(){ printf '[INFO] %s\n' "$*"; }; log_ok(){ printf '[OK] %s\n' "$*"; }
    log_error(){ printf '[ERROR] %s\n' "$*" >&2; }
fi
[ "$(id -u)" -eq 0 ] || { log_error "Run as root."; exit 1; }
install -d /usr/share/X11/xorg.conf.d
install -m 0644 "${SRC}/20-ik4ln3-noglamor.conf" /usr/share/X11/xorg.conf.d/20-ik4ln3-noglamor.conf
log_ok "Xorg no-glamor fix installed (MATE/Xorg will start on Apple Silicon). Reboot or restart the display manager to apply."
