#!/bin/bash
# steps/01a_network.sh
# Adapted from the original WiFi network setup script, with two security
# fixes:
#  1) no more copies of the password are kept outside /etc (the original
#     left a copy in /base_inst_kali/preparation/).
#  2) the credentials file ends up with 600 permissions.
# It also uses wpa_passphrase (if available) instead of manipulating the
# password with sed, avoiding issues if it contains special characters.
STEP_ID="01a"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/lib/state.sh"
source "${BASE_DIR}/lib/i18n.sh"
[ -z "${IAC_LANG:-}" ] && IAC_LANG="$(i18n_detect_default_lang)"
i18n_load "$IAC_LANG"
source "${BASE_DIR}/lib/common.sh"
CURRENT_STEP_ID="$STEP_ID"
init_step_log "$STEP_ID"
require_root

echo "$(t step01a_title)"
echo "$(t step01a_intro)"
echo "$(t step01a_warn_plaintext)"
echo "$(t step01a_warn_keyboard)"
echo

wifi_ssid="$(ui_inputbox "$(t step01a_title)" "$(t step01a_ask_ssid)")"
wifi_password="$(ui_passwordbox "$(t step01a_title)" "$(t step01a_ask_password)")"

WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"

if command -v wpa_passphrase >/dev/null 2>&1; then
    # wpa_passphrase correctly escapes the SSID/passphrase for us.
    wpa_passphrase "$wifi_ssid" "$wifi_password" > "$WPA_CONF"
    # wpa_passphrase leaves the plaintext passphrase commented out; strip it.
    sed -i '/^\s*#psk=/d' "$WPA_CONF"
    # wpa_passphrase never emits scan_ssid/key_mgmt (confirmed on Debian
    # Trixie's wpasupplicant build too) — add them so hidden-SSID networks
    # still connect and key_mgmt is explicit, matching the manual branch
    # below.
    sed -i '/^network={/a\        scan_ssid=1\n        key_mgmt=WPA-PSK' "$WPA_CONF"
else
    {
        echo 'network={'
        printf '        ssid="%s"\n' "${wifi_ssid//\"/\\\"}"
        echo '        scan_ssid=1'
        echo '        key_mgmt=WPA-PSK'
        printf '        psk="%s"\n' "${wifi_password//\"/\\\"}"
        echo '}'
    } > "$WPA_CONF"
fi
unset wifi_password

chmod 600 "$WPA_CONF"
chown root:root "$WPA_CONF"
log_info "$(t step01a_perm_fixed)"
echo "$(t step01a_perm_fixed)"

# Writing wpa_supplicant.conf alone doesn't bring up anything: on this
# ifupdown-based base (no NetworkManager), the interface itself still
# needs a stanza in /etc/network/interfaces.d/ pointing at it.
WIFI_IFACE=""
for ifc in /sys/class/net/*; do
    if [ -d "${ifc}/wireless" ]; then
        WIFI_IFACE="$(basename "$ifc")"
        break
    fi
done

if [ -z "$WIFI_IFACE" ]; then
    log_error "$(t step01a_no_iface)"
    echo "$(t step01a_no_iface)"
    exit 1
fi

log_info "$(t step01a_iface_found "$WIFI_IFACE")"
echo "$(t step01a_iface_found "$WIFI_IFACE")"

IFACES_D="/etc/network/interfaces.d"
mkdir -p "$IFACES_D"
IFACE_FILE="${IFACES_D}/${WIFI_IFACE}"
{
    echo "auto ${WIFI_IFACE}"
    echo "iface ${WIFI_IFACE} inet dhcp"
    echo "    wpa-conf ${WPA_CONF}"
} > "$IFACE_FILE"

# Debian's default /etc/network/interfaces sources interfaces.d/*, but
# don't assume it: add it if it's missing so the stanza actually gets
# picked up.
IFACES_MAIN="/etc/network/interfaces"
if [ -f "$IFACES_MAIN" ] && ! grep -q "^source ${IFACES_D}/\*" "$IFACES_MAIN"; then
    echo "source ${IFACES_D}/*" >> "$IFACES_MAIN"
fi

log_info "$(t step01a_iface_written "$IFACE_FILE")"
echo "$(t step01a_iface_written "$IFACE_FILE")"

# Best-effort bring-up with retries; this must NEVER abort the main
# install flow (01a runs before 01 now — see below — so a flaky AP here
# shouldn't block the rest of the host setup). We check actual
# connectivity (an IPv4 address on the interface) rather than trusting
# ifup's exit code alone, since ifup can return success before the
# WPA handshake/DHCP lease actually completes.
WIFI_MAX_ATTEMPTS=5
WIFI_RETRY_WAIT=5 # seconds between attempts

wifi_has_ip() {
    ip -4 addr show dev "$WIFI_IFACE" 2>/dev/null | grep -q 'inet '
}

WIFI_CONNECTED=0
if command -v ifup >/dev/null 2>&1; then
    attempt=1
    while [ "$attempt" -le "$WIFI_MAX_ATTEMPTS" ]; do
        echo "$(t step01a_connect_attempt "$attempt" "$WIFI_MAX_ATTEMPTS")"
        ifup "$WIFI_IFACE" >/dev/null 2>&1
        sleep "$WIFI_RETRY_WAIT"
        if wifi_has_ip; then
            WIFI_CONNECTED=1
            break
        fi
        ifdown "$WIFI_IFACE" >/dev/null 2>&1 || true
        attempt=$((attempt + 1))
    done
fi

if [ "$WIFI_CONNECTED" -eq 1 ]; then
    log_info "$(t step01a_connected "$WIFI_IFACE")"
    echo "$(t step01a_connected "$WIFI_IFACE")"
else
    # Non-fatal: log and move on. The interfaces.d stanza is already in
    # place, so it'll keep retrying on its own via ifupdown at boot, and
    # you can always run 'ifup <iface>' manually afterward.
    log_warn "$(t step01a_ifup_deferred "$WIFI_IFACE" "$WIFI_IFACE")"
    echo "$(t step01a_ifup_deferred "$WIFI_IFACE" "$WIFI_IFACE")"
fi

echo "$(t step01a_saved)"
mark_step_done "$STEP_ID"
