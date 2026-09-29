#!/bin/bash
# forensics/ik4ln3/14_install_ik4ln3_branding.sh
#
# iK4lN3 desktop branding for the v2.0.0 bare-metal image:
#   - desktop wallpaper  -> branding/wallpaper-desktop.png
#   - LightDM login image-> branding/wallpaper-lightdm.png
#   - theme              -> Yaru-blue-dark (GTK + window manager)
#   - icons              -> Yaru-blue
#
# Applies live for the invoking desktop user AND sets a system-wide dconf
# default so every account on the appliance gets the same look. Does NOT
# touch GRUB or the kernel.

set -u -o pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/branding" && pwd)"
if ! declare -F log_info >/dev/null 2>&1; then
    log_info(){ printf '[INFO] %s\n' "$*"; }
    log_warn(){ printf '\342\232\240 %s\n' "$*" >&2; }
    log_error(){ printf '\342\234\226 %s\n' "$*" >&2; }
    log_ok(){ printf '[OK] %s\n' "$*"; }
fi
[ "$(id -u)" -eq 0 ] || { log_error "Run as root (sudo)."; exit 1; }

THEME="Yaru-blue-dark"
ICONS="Yaru-blue"
BGDIR="/usr/share/backgrounds/ik4ln3"
DESKTOP_BG="${BGDIR}/wallpaper-desktop.png"
LOGIN_BG="${BGDIR}/wallpaper-lightdm.png"

# 1) make sure the Yaru theme + icons are present (no kernel/GPU deps).
if [ ! -d "/usr/share/themes/${THEME}" ] || [ ! -d "/usr/share/icons/${ICONS}" ]; then
    log_info "Installing Yaru theme + icons..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        yaru-theme-gtk yaru-theme-icon >/dev/null 2>&1 || \
        log_warn "Could not install Yaru packages; will fall back if the theme is missing."
fi
# fall back gracefully if the exact variant isn't there
if [ ! -d "/usr/share/themes/${THEME}" ]; then
    alt="$(ls -d /usr/share/themes/Yaru*dark 2>/dev/null | head -1)"
    if [ -n "$alt" ]; then THEME="$(basename "$alt")"; log_warn "Yaru-blue-dark not found; using ${THEME}."
    else log_warn "No Yaru dark theme found; theme step may not apply. Install yaru-theme-gtk."; fi
fi
[ -d "/usr/share/icons/${ICONS}" ] || ICONS="Yaru"

# 2) install the wallpapers
install -d "$BGDIR"
install -m 0644 "${SRC}/wallpaper-desktop.png" "$DESKTOP_BG"
install -m 0644 "${SRC}/wallpaper-lightdm.png" "$LOGIN_BG"
log_ok "Wallpapers installed under ${BGDIR}."

# 3) LightDM login background + greeter theme. Ubuntu MATE uses
#    slick-greeter; we also write the gtk-greeter config in case that's the
#    active one. Each greeter ignores the other's file.
cat > /etc/lightdm/slick-greeter.conf <<EOF
[Greeter]
background=${LOGIN_BG}
background-color=#0a1428
theme-name=${THEME}
icon-theme-name=${ICONS}
draw-user-backgrounds=false
draw-grid=false
EOF
install -d /etc/lightdm
cat > /etc/lightdm/lightdm-gtk-greeter.conf <<EOF
[greeter]
background=${LOGIN_BG}
theme-name=${THEME}
icon-theme-name=${ICONS}
EOF
log_ok "LightDM login image + greeter theme set."

# 3b) Make LightDM the ACTIVE display manager and MATE the default
# session. ubuntu-mate-desktop installs alongside GNOME, but GNOME's gdm3
# stays the active DM, so our LightDM greeter (image + theme) never shows
# and sessions default to GNOME. We switch without removing GNOME.
if ! dpkg -l lightdm 2>/dev/null | grep -q '^ii'; then
    log_info "Installing lightdm + slick-greeter..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        lightdm slick-greeter >/dev/null 2>&1 || log_warn "Could not install lightdm."
fi
if dpkg -l lightdm 2>/dev/null | grep -q '^ii'; then
    # select lightdm through every mechanism, so it sticks across reconfigures
    echo "set shared/default-x-display-manager lightdm" | debconf-communicate >/dev/null 2>&1 || true
    printf 'lightdm shared/default-x-display-manager select lightdm\ngdm3 shared/default-x-display-manager select lightdm\n' | debconf-set-selections 2>/dev/null || true
    echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
    # point systemd's display-manager.service at lightdm
    ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service 2>/dev/null || true
    log_ok "LightDM set as the active display manager (GNOME/gdm3 left installed but inactive)."

    # Ubuntu MATE ships arctica-greeter as the default greeter, and arctica
    # IGNORES slick-greeter.conf — so the login image/theme above would never
    # show. Force slick-greeter with a high-priority drop-in (99 > arctica's
    # 90), installing it if needed. This is what makes the login image appear.
    if ! dpkg -l slick-greeter 2>/dev/null | grep -q '^ii'; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            slick-greeter >/dev/null 2>&1 || log_warn "Could not install slick-greeter."
    fi
    install -d /etc/lightdm/lightdm.conf.d
    printf '[Seat:*]\ngreeter-session=slick-greeter\n' \
        > /etc/lightdm/lightdm.conf.d/99-ik4ln3-greeter.conf
    log_ok "Forced slick-greeter over arctica-greeter (login image/theme will show)."
else
    log_warn "lightdm not available; leaving the current display manager. The login branding needs lightdm."
fi

# default session -> MATE (detect the exact session .desktop name)
MATE_SESSION=""
for cand in mate ubuntu-mate mate-session; do
    [ -f "/usr/share/xsessions/${cand}.desktop" ] && { MATE_SESSION="$cand"; break; }
done
if [ -n "$MATE_SESSION" ]; then
    # lightdm default for all users (incl. fresh accounts)
    install -d /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/60-ik4ln3-session.conf <<EOF
[Seat:*]
user-session=${MATE_SESSION}
greeter-session=slick-greeter
EOF
    # and for the invoking user, via AccountsService (their remembered session)
    if [ -n "${SUDO_USER:-}" ]; then
        install -d /var/lib/AccountsService/users
        f="/var/lib/AccountsService/users/${SUDO_USER}"
        if [ -f "$f" ]; then
            grep -q '^XSession=' "$f" && sed -i "s/^XSession=.*/XSession=${MATE_SESSION}/" "$f" || printf '\nXSession=%s\n' "$MATE_SESSION" >> "$f"
            grep -q '^Session=' "$f"  && sed -i "s/^Session=.*/Session=${MATE_SESSION}/"  "$f" || printf 'Session=%s\n' "$MATE_SESSION" >> "$f"
        else
            printf '[User]\nSession=%s\nXSession=%s\nSystemAccount=false\n' "$MATE_SESSION" "$MATE_SESSION" > "$f"
        fi
    fi
    log_ok "Default session set to MATE (${MATE_SESSION})."
else
    log_warn "No MATE session found in /usr/share/xsessions; is ubuntu-mate-desktop installed? Default session unchanged."
fi

# 4) system-wide default look (applies to every account, incl. fresh ones)
install -d /etc/dconf/db/local.d /etc/dconf/profile
[ -f /etc/dconf/profile/user ] || printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
grep -q '^system-db:local' /etc/dconf/profile/user || echo 'system-db:local' >> /etc/dconf/profile/user
cat > /etc/dconf/db/local.d/01-ik4ln3-branding <<EOF
[org/mate/desktop/background]
picture-filename='${DESKTOP_BG}'
picture-options='zoom'

[org/mate/background]
picture-filename='${DESKTOP_BG}'
picture-options='zoom'

[org/mate/interface]
gtk-theme='${THEME}'
icon-theme='${ICONS}'

[org/mate/Marco/general]
theme='${THEME}'
EOF
dconf update 2>/dev/null || log_warn "dconf update failed; system default may not apply until next boot."
log_ok "System-wide default theme/wallpaper set (${THEME}, ${ICONS})."

# 5) apply live for the user running sudo, so they see it now
if [ -n "${SUDO_USER:-}" ]; then
    u="$SUDO_USER"; uid="$(id -u "$u")"
    gs() { sudo -u "$u" env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" gsettings "$@" 2>/dev/null; }
    gs set org.mate.interface gtk-theme "$THEME"
    gs set org.mate.interface icon-theme "$ICONS"
    gs set org.mate.Marco.general theme "$THEME"
    gs set org.mate.background picture-filename "$DESKTOP_BG"
    gs set org.mate.background picture-options 'zoom'
    log_ok "Applied live for '$u'."
fi

# 6) make LightDM the active display manager (Ubuntu MATE's greeter, and
#    the one our login image/theme above is written for) instead of gdm3,
#    and set MATE as the default session — without removing GNOME.
if command -v lightdm >/dev/null 2>&1; then
    cur="$(cat /etc/X11/default-display-manager 2>/dev/null)"
    if [ "$cur" != "/usr/sbin/lightdm" ]; then
        log_info "Switching the active display manager to LightDM (was: ${cur:-unset})..."
        echo "set shared/default-x-display-manager lightdm" | debconf-communicate >/dev/null 2>&1 || \
            echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections 2>/dev/null || true
        echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
        systemctl disable gdm3 >/dev/null 2>&1 || true
        systemctl enable lightdm >/dev/null 2>&1 || true
        # make sure systemd's display-manager alias points at lightdm
        ldm_unit="$(systemctl show -p FragmentPath lightdm.service 2>/dev/null | cut -d= -f2)"
        [ -n "$ldm_unit" ] && ln -sf "$ldm_unit" /etc/systemd/system/display-manager.service 2>/dev/null || true
        log_ok "LightDM is now the active display manager (reboot to apply)."
    else
        log_info "LightDM is already the active display manager."
    fi
else
    log_warn "LightDM is not installed; login image/theme won't show under gdm3. Install lightdm + slick-greeter."
fi

# default session = MATE. Detect the session .desktop name in xsessions.
MATE_SESSION=""
for s in mate ubuntu-mate mate-session; do
    [ -f "/usr/share/xsessions/${s}.desktop" ] && { MATE_SESSION="$s"; break; }
done
if [ -n "$MATE_SESSION" ]; then
    # (a) default for any user LightDM doesn't have a record for
    install -d /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/60-ik4ln3.conf <<EOF
[Seat:*]
user-session=${MATE_SESSION}
greeter-session=slick-greeter
EOF
    # (b) the invoking user already has a GNOME record in AccountsService;
    #     override it so they land in MATE too.
    if [ -n "${SUDO_USER:-}" ]; then
        af="/var/lib/AccountsService/users/${SUDO_USER}"
        install -d /var/lib/AccountsService/users
        if [ -f "$af" ]; then
            sed -i '/^XSession=/d; /^Session=/d' "$af"
            if grep -q '^\[User\]' "$af"; then
                sed -i "0,/^\[User\]/s//[User]\nXSession=${MATE_SESSION}\nSession=${MATE_SESSION}/" "$af"
            else
                printf '[User]\nXSession=%s\nSession=%s\n' "$MATE_SESSION" "$MATE_SESSION" >> "$af"
            fi
        else
            printf '[User]\nXSession=%s\nSession=%s\nSystemAccount=false\n' "$MATE_SESSION" "$MATE_SESSION" > "$af"
        fi
    fi
    log_ok "Default session set to MATE (${MATE_SESSION})."
else
    log_warn "No MATE session found in /usr/share/xsessions/; is ubuntu-mate-desktop installed? Default session left unchanged."
fi

echo
log_ok "iK4lN3 branding applied."
echo "  Desktop wallpaper : ${DESKTOP_BG}"
echo "  Login background  : ${LOGIN_BG}"
echo "  Theme / icons     : ${THEME} / ${ICONS}"
echo "  Display manager   : LightDM   Default session: MATE"
echo "  Reboot to land at the LightDM login and a MATE session."