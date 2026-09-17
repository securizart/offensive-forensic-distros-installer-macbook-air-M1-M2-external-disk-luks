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
source "${BASE_DIR}/lib/os_catalog.sh"
source "${BASE_DIR}/lib/i18n.sh"
[ -z "${IAC_LANG:-}" ] && IAC_LANG="$(i18n_detect_default_lang)"
i18n_load "$IAC_LANG"
source "${BASE_DIR}/lib/common.sh"
CURRENT_STEP_ID="$STEP_ID"
init_step_log "$STEP_ID"
require_root

# Ubuntu/Asahi already has working network from its own install (it's a
# full desktop image, not the minimal Debian/Asahi base this step was
# written for); nothing to configure here in that case.
BOOTED_BASE="$(state_get BOOTED_BASE)"
[ -z "$BOOTED_BASE" ] && BOOTED_BASE="$(detect_booted_base)"

if [ "$BOOTED_BASE" = "ubuntu" ]; then
    log_info "Booted base is Ubuntu/Asahi: skipping WiFi setup (network already works on this base)."
    echo "$(t step01a_title)"
    echo "$(t step01a_ubuntu_skip)"
    mark_step_done "$STEP_ID"
    exit 0
fi

echo "$(t step01a_title)"
echo "$(t step01a_intro)"
echo "$(t step01a_warn_plaintext)"
echo

wifi_ssid="$(ui_inputbox "$(t step01a_title)" "$(t step01a_ask_ssid)")"
wifi_password="$(ui_passwordbox "$(t step01a_title)" "$(t step01a_ask_password)")"

WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"

if command -v wpa_passphrase >/dev/null 2>&1; then
    # wpa_passphrase correctly escapes the SSID/passphrase for us.
    wpa_passphrase "$wifi_ssid" "$wifi_password" > "$WPA_CONF"
    # wpa_passphrase leaves the plaintext passphrase commented out; strip it.
    sed -i '/^\s*#psk=/d' "$WPA_CONF"
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

echo "$(t step01a_saved)"
mark_step_done "$STEP_ID"
