#!/bin/bash
# forensics/ik4ln3/12_install_ik4ln3_desktop.sh
#
# Build a "Forensic Tools" menu (our own generated files, with familiar
# forensic category names) for the MATE desktop on
# an Ubuntu/Asahi clone where 10_install_ik4ln3_apt.sh has already run.
#
# What it does
# ------------
# For every forensic package we installed (packages-apt.txt, grouped),
# it discovers the package's real executables via `dpkg -L`, and for each
# one generates a .desktop launcher that opens the tool in a MATE
# terminal with its help + an interactive shell. It groups those
# launchers under a top-level "Forensic Tools" menu whose subcategories
# use familiar forensic names (Analysis, Disks, Hash, Memory Forensics,
# Registry, Timeline, Network Forensics, Malware, Password Recovery).
#
# Design choices / honesty
# ------------------------
#  * Only tools whose command actually resolves get a launcher, so there
#    are ZERO dead entries (the whole problem with copying a stock menu
#    verbatim, which points at ~500 tools most of which aren't on arm64).
#  * Files are AUTHORED here. Category NAMES are
#    familiar forensic terms; ICONS are standard system-theme names, NOT
#    third-party proprietary artwork (that's the branding line we don't
#    cross). Swap CAT_ICON below if you ship your own icon set.
#  * The write-blocker / Mounter is NOT here — that's udev rules + scripts,
#    handled separately; this script is purely the applications menu.
#  * No kernel/GRUB interaction at all: this only writes .desktop/
#    .directory/.menu files and refreshes the desktop database.
#
# Idempotent: every generated file has a stable name and is overwritten
# on re-run. Uninstall with --remove.

set -u -o pipefail

IK4lN3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MASTER_LOG:=/tmp/ik4ln3-standalone.log}"
if [ -f "${IK4lN3_DIR%/forensics/ik4ln3}/lib/common.sh" ]; then
    . "${IK4lN3_DIR%/forensics/ik4ln3}/lib/common.sh"
fi
if ! declare -F log_info >/dev/null 2>&1; then
    log_info(){ printf '[INFO] %s\n' "$*"; }
    log_warn(){ printf '\342\232\240 %s\n' "$*" >&2; }
    log_error(){ printf '\342\234\226 %s\n' "$*" >&2; }
    log_ok(){ printf '[OK] %s\n' "$*"; }
fi

# --- output locations -------------------------------------------------------
APPS_DIR="/usr/share/applications"
DIRS_DIR="/usr/share/desktop-directories"
MENU_DIR="/etc/xdg/menus/applications-merged"     # MATE merges *.menu here
LAUNCH_HELPER="/usr/local/bin/ik4ln3-run"
PREFIX="ik4ln3-forensics"                          # filename prefix for all we create

# --- forensic taxonomy -------------------------------------------------
# category id -> display name (familiar forensic names) and a SYSTEM-THEME icon.
declare -A CAT_NAME=(
    [analysis]="Analysis"
    [disks]="Disks"
    [hash]="Hash"
    [memory]="Memory Forensics"
    [registry]="Registry"
    [timeline]="Timeline"
    [network]="Network Forensics"
    [malware]="Malware"
    [passwords]="Password Recovery"
)
declare -A CAT_ICON=(
    [analysis]="edit-find"
    [disks]="drive-harddisk"
    [hash]="application-certificate"
    [memory]="applications-system"
    [registry]="applications-engineering"
    [timeline]="x-office-calendar"
    [network]="network-workgroup"
    [malware]="security-medium"
    [passwords]="dialog-password"
)
CATS_ORDER=(disks analysis hash memory registry timeline network malware passwords)

# map a packages-apt.txt group header -> category id
group_to_cat() {
    case "$1" in
        "Disk imaging & acquisition") echo disks ;;
        "Filesystem / partition analysis") echo disks ;;
        "Secure wipe") echo disks ;;
        "File carving & recovery") echo analysis ;;
        "Hex / binary editors & RE") echo analysis ;;
        "Steganography") echo analysis ;;
        "Metadata / images / documents") echo analysis ;;
        "Hashing & integrity") echo hash ;;
        "Memory forensics") echo memory ;;
        "Windows artifacts / registry") echo registry ;;
        "Timeline / triage") echo timeline ;;
        "Network forensics / capture") echo network ;;
        "Anti-rootkit / audit") echo malware ;;
        "Password / cracking (auth)") echo passwords ;;
        *) echo "" ;;   # "Meta / bundles" and unknowns -> not menu-ized
    esac
}

# Generic, non-forensic commands that some packages ship as helpers. If a
# forensic package happens to include one, it's noise in a forensic menu,
# so skip it. (None of the real forensic tools we want are in here — e.g.
# 'shred' is intentionally absent, it's a legitimate wipe tool.)
GENERIC_DENY=" [ cat ls cp mv rm mkdir rmdir ln link unlink touch echo printf test true false pwd chmod chown chgrp chcon df du stat sync sleep seq yes tee wc sort uniq head tail cut tr od nl numfmt fold fmt join paste split csplit comm expand unexpand base32 base64 basenc arch nproc uname hostname id groups users who whoami logname tty date cal env printenv dirname basename readlink realpath mktemp pinky vdir dir runcon stdbuf tsort ptx pr factor "

# skip binaries that aren't user-facing forensic tools
skip_binary() {
    local b="$1"
    case "$b" in
        *-config|*-config-*|*.so|*.so.*|*-completion) return 0 ;;
        lib*|*.py|*.pyc) return 0 ;;
        ?) return 0 ;;                       # single-char names like '['
    esac
    case "$GENERIC_DENY" in *" $b "*) return 0 ;; esac
    return 1
}

# --- removal ---------------------------------------------------------------
if [ "${1:-}" = "--remove" ]; then
    log_info "Removing generated Forensic Tools menu..."
    rm -f "${APPS_DIR}/${PREFIX}-"*.desktop \
          "${DIRS_DIR}/${PREFIX}"*.directory \
          "${MENU_DIR}/${PREFIX}.menu" \
          "$LAUNCH_HELPER"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true
    log_ok "Removed. Log out/in for the menu to disappear."
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { log_error "Run as root (sudo)."; exit 1; }
mkdir -p "$APPS_DIR" "$DIRS_DIR" "$MENU_DIR"

# --- the shared launcher helper (opens a tool's help + a shell) ------------
cat > "$LAUNCH_HELPER" <<'HELP'
#!/bin/bash
# ik4ln3-run <tool> — show a forensic CLI tool's help, then drop to a shell.
# 'man' is side-effect-free and never hangs, so we lead with it.
tool="$1"
clear
printf '\033[1m== %s ==\033[0m\n\n' "$tool"
man "$tool" 2>/dev/null | col -b 2>/dev/null | sed -n '1,25p'
printf '\n\033[2mType:  %s --help    (or:  man %s)\nReady.\033[0m\n\n' "$tool" "$tool"
exec bash
HELP
chmod +x "$LAUNCH_HELPER"

# pick a terminal: MATE's by preference, else the Debian alternative
TERM_EMU="mate-terminal"
command -v mate-terminal >/dev/null 2>&1 || TERM_EMU="x-terminal-emulator"

# --- generate a .desktop per real binary -----------------------------------
declare -A USED=()          # dedupe binaries seen across packages
declare -A CAT_HAS=()       # which categories ended up non-empty
made=0

emit_desktop() {
    local bin="$1" cat="$2"
    local name="$bin"
    local file="${APPS_DIR}/${PREFIX}-${bin}.desktop"
    local exec_line term_line icon="${CAT_ICON[$cat]}"
    if is_gui "$bin"; then
        # GUI tool (ships its own .desktop): launch it directly, no terminal.
        exec_line="Exec=${bin}"
        term_line="Terminal=false"
    else
        # CLI tool: open a MATE terminal with its help + an interactive shell.
        exec_line="Exec=${TERM_EMU} -t \"${name}\" -e \"${LAUNCH_HELPER} ${bin}\""
        term_line="Terminal=false"
    fi
    {
        echo "[Desktop Entry]"
        echo "Type=Application"
        echo "Version=1.0"
        echo "Name=${name}"
        echo "Comment=Forensic tool (${CAT_NAME[$cat]})"
        echo "TryExec=${bin}"
        echo "$exec_line"
        echo "Icon=${icon}"
        echo "$term_line"
        echo "Categories=X-Forensics-${cat};"
        echo "Keywords=forensics;ik4ln3;${cat};"
    } > "$file"
    CAT_HAS[$cat]=1
    made=$((made+1))
}

# is_gui BIN -> 0 if some package (not ours) already ships a .desktop that
# runs this binary, i.e. it's a GUI app that should launch its own window.
is_gui() {
    local b="$1"
    grep -lE "^Exec=(/usr/bin/)?${b}( |$)" "${APPS_DIR}"/*.desktop 2>/dev/null \
        | grep -qv "/${PREFIX}-"
}

# write_ik4ln3_layout -> install the iK4lN3 panel layout (classic
# menu-bar with the nested Forensic Tools tree + a "Run Application"
# button + the usual applets). Returns 0 if written. Format follows
# mate-panel's own data/default.layout.
write_ik4ln3_layout() {
    local ldir="/usr/share/mate-panel/layouts"
    mkdir -p "$ldir" 2>/dev/null || return 1
    cat > "${ldir}/ik4ln3.layout" <<'LAYOUT' || return 1
[Toplevel top]
expand=true
orientation=top
size=26

[Toplevel bottom]
expand=true
orientation=bottom
size=26

# Classic menu: Applications / Places / System (renders our nested
# "Forensic Tools" tree, unlike Brisk).
[Object menu-bar]
object-type=menu-bar
toplevel-id=top
position=0
locked=true

# Run Application button ("el ejecutar").
[Object run]
object-type=action
action-type=run
toplevel-id=top
position=100
locked=true

[Object notification-area]
object-type=applet
applet-iid=NotificationAreaAppletFactory::NotificationArea
toplevel-id=top
position=10
panel-right-stick=true
locked=true

[Object clock]
object-type=applet
applet-iid=ClockAppletFactory::ClockApplet
toplevel-id=top
position=0
panel-right-stick=true
locked=true

[Object show-desktop]
object-type=applet
applet-iid=WnckletFactory::ShowDesktopApplet
toplevel-id=bottom
position=0
locked=true

# Brisk Menu — the Windows-style start menu with search, bottom-left.
[Object brisk]
object-type=applet
applet-iid=BriskMenuFactory::BriskMenu
toplevel-id=bottom
position=10
locked=true

[Object window-list]
object-type=applet
applet-iid=WnckletFactory::WindowListApplet
toplevel-id=bottom
position=40
locked=true

[Object workspace-switcher]
object-type=applet
applet-iid=WnckletFactory::WorkspaceSwitcherApplet
toplevel-id=bottom
position=0
panel-right-stick=true
locked=true
LAYOUT
    [ -f "${ldir}/ik4ln3.layout" ]
}

# apply_traditional_menu -> switch the panel from Brisk (Ubuntu MATE's
# default single-level menu, which flattens our nested tree) to the classic
# Applications/Places/System menu-bar, which renders the nested "Forensic
# Tools" tree properly. Applies live if a MATE session is running
# for the desktop user, and sets it as their default for next login.
apply_traditional_menu() {
    local user uid layout ldir="/usr/share/mate-panel/layouts"
    user="${SUDO_USER:-$(logname 2>/dev/null || true)}"
    if [ -z "$user" ] || [ "$user" = "root" ]; then
        log_warn "Couldn't determine the desktop user; not switching the menu layout. As your user, run: mate-panel --reset --layout traditional --replace"
        return 0
    fi
    uid="$(id -u "$user" 2>/dev/null || true)"
    [ -n "$uid" ] || { log_warn "User '$user' has no uid; skipping menu-layout switch."; return 0; }

    # Prefer our own iK4lN3 layout (classic menu-bar + Run button).
    if write_ik4ln3_layout; then
        layout="ik4ln3"
    elif [ -f "${ldir}/traditional.layout" ]; then
        layout="traditional"
    else
        # any layout that defines a menu-bar object and isn't Brisk-based
        layout="$(grep -lZ 'object-type=menu-bar' "${ldir}"/*.layout 2>/dev/null \
                  | xargs -r -I{} sh -c 'grep -qi brisk "{}" || basename "{}" .layout' 2>/dev/null \
                  | head -1)"
        # portable fallback if the fancy pipe found nothing
        if [ -z "$layout" ]; then
            for f in "${ldir}"/*.layout; do
                [ -f "$f" ] || continue
                grep -q 'object-type=menu-bar' "$f" 2>/dev/null || continue
                grep -qi brisk "$f" 2>/dev/null && continue
                layout="$(basename "$f" .layout)"; break
            done
        fi
    fi
    if [ -z "$layout" ]; then
        log_warn "No classic menu-bar layout found in ${ldir}; panel left as-is. Add the 'Menu Bar' applet by hand to see the nested menu."
        return 0
    fi
    log_info "Switching '$user' to the '$layout' panel layout (classic menu-bar)..."

    # Persist as this user's default (honored on a fresh first login).
    sudo -u "$user" dconf write /org/mate/panel/general/default-layout "'$layout'" 2>/dev/null || true

    # Apply live if this user has a running MATE panel (pull DISPLAY/DBUS/
    # XAUTHORITY from its actual environment so we hit the right session).
    local pid; pid="$(pgrep -u "$user" -x mate-panel 2>/dev/null | head -1)"
    if [ -n "$pid" ] && [ -r "/proc/$pid/environ" ]; then
        local disp dbus xauth
        disp="$(tr '\0' '\n' < "/proc/$pid/environ" | grep -m1 '^DISPLAY=' || true)"
        dbus="$(tr '\0' '\n' < "/proc/$pid/environ" | grep -m1 '^DBUS_SESSION_BUS_ADDRESS=' || true)"
        xauth="$(tr '\0' '\n' < "/proc/$pid/environ" | grep -m1 '^XAUTHORITY=' || true)"
        if [ -n "$disp" ] && [ -n "$dbus" ]; then
            sudo -u "$user" env "$disp" "$dbus" ${xauth:+"$xauth"} mate-panel --reset --layout "$layout" >/dev/null 2>&1 || true
            sudo -u "$user" env "$disp" "$dbus" ${xauth:+"$xauth"} mate-panel --replace >/dev/null 2>&1 &
            log_ok "Panel switched to '$layout' live — the nested Forensic Tools menu is under 'Applications'."
            return 0
        fi
    fi
    log_info "No live MATE session for '$user'; the '$layout' layout will apply on next login."
}

# renamed map: old -> new (we scan the NEW package's binaries)
declare -A RENAME=()
if [ -f "${IK4lN3_DIR}/packages-renamed.txt" ]; then
    while read -r old new _; do
        [ -n "${old:-}" ] && [ "${old:0:1}" != "#" ] && RENAME[$old]="$new"
    done < <(sed -E 's/#.*//' "${IK4lN3_DIR}/packages-renamed.txt" | awk 'NF>=2')
fi

cur_cat=""
while IFS= read -r line; do
    # group header?  "# --- Group name ---"
    if [[ "$line" =~ ^#\ ---\ (.*)\ ---$ ]]; then
        cur_cat="$(group_to_cat "${BASH_REMATCH[1]}")"
        continue
    fi
    # strip comments/space -> package name
    pkg="$(sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$line")"
    [ -z "$pkg" ] && continue
    [ -z "$cur_cat" ] && continue          # group not menu-ized (e.g. Meta)
    # honor rename
    [ -n "${RENAME[$pkg]:-}" ] && pkg="${RENAME[$pkg]}"
    # not installed? skip silently (guard already reported those)
    dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' || continue
    # enumerate this package's executables in the usual bin dirs
    while IFS= read -r path; do
        case "$path" in
            /usr/bin/*|/usr/sbin/*|/bin/*|/sbin/*) : ;;
            *) continue ;;
        esac
        [ -f "$path" ] && [ -x "$path" ] || continue
        bin="$(basename "$path")"
        skip_binary "$bin" && continue
        [ -n "${USED[$bin]:-}" ] && continue
        command -v "$bin" >/dev/null 2>&1 || continue
        USED[$bin]=1
        emit_desktop "$bin" "$cur_cat"
    done < <(dpkg -L "$pkg" 2>/dev/null)
done < <(cat "${IK4lN3_DIR}/packages-apt.txt"; echo)

log_info "Generated ${made} launchers across $(echo "${!CAT_HAS[@]}" | wc -w) categories."

# --- .directory files (top folder + each category) -------------------------
cat > "${DIRS_DIR}/${PREFIX}.directory" <<EOF
[Desktop Entry]
Type=Directory
Name=Forensic Tools
Icon=applications-utilities
EOF
for cat in "${CATS_ORDER[@]}"; do
    [ -n "${CAT_HAS[$cat]:-}" ] || continue
    cat > "${DIRS_DIR}/${PREFIX}-${cat}.directory" <<EOF
[Desktop Entry]
Type=Directory
Name=${CAT_NAME[$cat]}
Icon=${CAT_ICON[$cat]}
EOF
done

# --- the merged .menu (assembles the "Forensic Tools" tree) ----------------
{
    echo '<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"'
    echo ' "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">'
    echo '<Menu>'
    echo '  <Name>Applications</Name>'
    echo '  <Menu>'
    echo '    <Name>Forensic Tools</Name>'
    echo "    <Directory>${PREFIX}.directory</Directory>"
    for cat in "${CATS_ORDER[@]}"; do
        [ -n "${CAT_HAS[$cat]:-}" ] || continue
        echo '    <Menu>'
        echo "      <Name>${CAT_NAME[$cat]}</Name>"
        echo "      <Directory>${PREFIX}-${cat}.directory</Directory>"
        echo '      <Include>'
        echo "        <And><Category>X-Forensics-${cat}</Category></And>"
        echo '      </Include>'
        echo '    </Menu>'
    done
    echo '  </Menu>'
    echo '</Menu>'
} > "${MENU_DIR}/${PREFIX}.menu"

# --- refresh caches --------------------------------------------------------
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true
command -v update-menus >/dev/null 2>&1 && update-menus 2>/dev/null || true

# --- switch the panel to the classic menu-bar (unless told not to) ---------
DO_LAYOUT=1
for a in "$@"; do [ "$a" = "--no-layout" ] && DO_LAYOUT=0; done
if [ "$DO_LAYOUT" -eq 1 ]; then
    apply_traditional_menu
else
    log_info "Menu-layout switch skipped (--no-layout). The nested menu needs the classic menu-bar applet to show subcategories."
fi

log_ok "Forensic Tools menu built (${made} launchers). Log out and back into MATE to see it."
log_info "To undo: sudo bash ${BASH_SOURCE[0]##*/} --remove"

# --- first-boot panel apply -------------------------------------------------
# In the installer (chroot / no live MATE session) the layout can't be
# applied live, and MATE only reads default-layout for a user that has NO
# panel config yet. So drop a one-shot autostart that applies our layout in
# the user's FIRST MATE session (top = classic menu, bottom = Brisk), then
# removes itself. This is what makes the panels come up right on a fresh
# appliance boot.
cat > /usr/local/bin/ik4ln3-apply-panel <<'HELP'
#!/bin/bash
mark="${HOME}/.config/ik4ln3-panel-applied"
[ -f "$mark" ] && exit 0
# panel layout (classic menu top, Brisk bottom)
if [ -f /usr/share/mate-panel/layouts/ik4ln3.layout ]; then
    dconf write /org/mate/panel/general/default-layout "'ik4ln3'" 2>/dev/null || true
    mate-panel --reset --layout ik4ln3 >/dev/null 2>&1 || true
    ( sleep 2; mate-panel --replace >/dev/null 2>&1 & ) 2>/dev/null
fi
# make sure the desktop shows icons, and place + trust the Mounter shortcut
gsettings set org.mate.background show-desktop-icons true 2>/dev/null || true
if [ -f /usr/share/applications/ik4ln3-mounter.desktop ]; then
    mkdir -p "${HOME}/Desktop"
    cp -f /usr/share/applications/ik4ln3-mounter.desktop "${HOME}/Desktop/ik4ln3-mounter.desktop"
    chmod +x "${HOME}/Desktop/ik4ln3-mounter.desktop"
    d="${HOME}/Desktop/ik4ln3-mounter.desktop"
    gio set "$d" metadata::caja-trusted-launcher true 2>/dev/null \
        || setfattr -n user.metadata::caja-trusted-launcher -v true "$d" 2>/dev/null || true
fi
mkdir -p "${HOME}/.config"; : > "$mark"
HELP
chmod +x /usr/local/bin/ik4ln3-apply-panel
install -d /etc/xdg/autostart
cat > /etc/xdg/autostart/ik4ln3-apply-panel.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=iK4lN3 panel setup
Exec=ik4ln3-apply-panel
OnlyShowIn=MATE;
X-MATE-Autostart-enabled=true
NoDisplay=true
EOF
log_ok "Panel layout will apply on the first MATE login (classic menu top, Brisk bottom)."
