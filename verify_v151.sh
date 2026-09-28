#!/bin/bash
# verify_v151.sh — Ejecutar SIEMPRE en la carpeta app/ (raíz del
# proyecto) ANTES de lanzar install.sh, para confirmar que la copia
# desplegada en el equipo realmente lleva los cambios de v1.5.1 y no
# una mezcla parcial con v1.5.0 (fallo de sincronización de versiones).
#
# Sigue el mismo patrón que verify_v150.sh (comprobar strings concretos
# con grep -qF), ampliado con los puntos añadidos en v1.5.1.
set -u
APP="${1:-.}"
fail=0

check() {
    local desc="$1" file="$2" pattern="$3"
    if grep -qF -- "$pattern" "$APP/$file" 2>/dev/null; then
        echo "  [OK]   $desc"
    else
        echo "  [FALTA] $desc  ($file)"
        fail=1
    fi
}

check_absent() {
    # Para comprobar que algo de v1.5.0 fue efectivamente ELIMINADO
    # (p.ej. el fichero 07b independiente), no solo que algo nuevo esté.
    local desc="$1" path="$2"
    if [ -e "$APP/$path" ]; then
        echo "  [FALTA] $desc  ($path todavía existe, debería haberse eliminado)"
        fail=1
    else
        echo "  [OK]   $desc"
    fi
}

echo "== Verificando $APP antes de arrancar (v1.5.1 sobre v1.5.0) =="

echo ""
echo "-- 1) Bootstrap centralizado --"
check "lib/bootstrap.sh existe" "lib/bootstrap.sh" "step_bootstrap()"
check "declare -gA STRINGS (global, sobrevive a step_bootstrap)" "lib/i18n.sh" "declare -gA STRINGS"
check "declare -gA en os_catalog.sh (global, sobrevive a step_bootstrap)" "lib/os_catalog.sh" "declare -gA OS_RELEASE_ID_TO_BASE"
check "resolve_physical_disk() robusto vía /sys/class/block (LVM-sobre-LUKS)" "lib/common.sh" "/sys/class/block/\${kname}/slaves"
check "resolve_physical_disk() usa KNAME, no NAME (alias LVM)" "lib/common.sh" "lsblk -no KNAME"
check "policy-rc.d en step 08 (evita fallos de postinst)" "steps/08_repositories.sh" "/usr/sbin/policy-rc.d"
check "policy-rc.d también en step 09 (reintento independiente)" "steps/09_package_installation.sh" "/usr/sbin/policy-rc.d"
check "malla GRUB usa configfile /grub/grub.cfg (no /boot/grub/grub.cfg)" "steps/07_grub_merge.sh" "configfile /grub/grub.cfg"
UNFIXED_CONFIGFILE="$(grep -c 'configfile /boot/grub/grub.cfg' "$APP/steps/07_grub_merge.sh" 2>/dev/null)"
UNFIXED_CONFIGFILE="${UNFIXED_CONFIGFILE:-0}"
if [ "$UNFIXED_CONFIGFILE" -eq 0 ]; then
    echo "  [OK]   sin rutas 'configfile /boot/grub/grub.cfg' rotas restantes"
else
    echo "  [FALTA] quedan $UNFIXED_CONFIGFILE rutas 'configfile /boot/grub/grub.cfg' sin corregir en step 07"
    fail=1
fi
check "step 02 usa step_bootstrap" "steps/02_partitions.sh" "step_bootstrap \"\$STEP_ID\""
check "step 09 usa step_bootstrap" "steps/09_package_installation.sh" "step_bootstrap \"\$STEP_ID\""

echo ""
echo "-- 2) Espera LUKS/LVM centralizada --"
check "wait_for_device() en lib/common.sh" "lib/common.sh" "wait_for_device()"
check "open_luks_and_activate_vg() en lib/common.sh" "lib/common.sh" "open_luks_and_activate_vg()"
check "step 04 usa open_luks_and_activate_vg" "steps/04_cloning.sh" "open_luks_and_activate_vg \"\$CRYPTNAME\""
check "step 05 usa open_luks_and_activate_vg" "steps/05_chroot_prep.sh" "open_luks_and_activate_vg \"\$CRYPTNAME\""

echo ""
echo "-- 3) UUID robusto en step 04 --"
check "blkid -s UUID -o value en vez de grep manual" "steps/04_cloning.sh" "blkid -s UUID -o value"

echo ""
echo "-- 4) Tamaños de partición por-OS --"
check "OS_PART_ROOT_SIZE en os_catalog.sh" "lib/os_catalog.sh" "OS_PART_ROOT_SIZE"
check "step 02 usa os_part_root_size" "steps/02_partitions.sh" "os_part_root_size \"\$TARGET_OS\""

echo ""
echo "-- 5) Verificación de arranque antes del paso 8 --"
check "verify_booted_from_target_disk() en lib/common.sh" "lib/common.sh" "verify_booted_from_target_disk()"
check "step 08 la llama" "steps/08_repositories.sh" "verify_booted_from_target_disk"
check "step 09 la llama" "steps/09_package_installation.sh" "verify_booted_from_target_disk"
check "step 10 la llama" "steps/10_grub_menu_fix.sh" "verify_booted_from_target_disk"

echo ""
echo "-- 6) Fusión 07+07b y malla GRUB de los 6 sistemas --"
check_absent "steps/07b_grub_cross_merge.sh eliminado (fusionado en 07)" "steps/07b_grub_cross_merge.sh"
check "07b ya no aparece en OS_STEPS" "install.sh" "OS_STEPS=(02 03 04 05 06 07 08 09 10)"
check "script autodescubridor de hermanos externos" "steps/07_grub_merge.sh" "47_iac_disk_siblings"
check "fase 3: cross-link interno automático (sin confirm)" "steps/07_grub_merge.sh" "step07b_title_generic"
check "fase 4: target aprende de ambas bases internas" "steps/07_grub_merge.sh" "48_iac_internal_"
check "mensaje final indica qué entrada elegir" "i18n/strings.en.sh" "pick the entry labeled"
check "opción de menú 'Sync GRUB now'" "install.sh" "GRUBSYNC"
check "reinicio automático al final del paso 7 consolidado" "steps/07_grub_merge.sh" "reboot"

echo ""
echo "-- 7) Fixes de esta sesión, portados sobre esta base (red, hardware real, Kali/Parrot) --"
check "orden HOST_STEPS con 01a antes que 01" "install.sh" "HOST_STEPS=(00 01a 01)"
check "01a_network.sh restaurado (ifupdown/interfaces.d real)" "steps/01a_network.sh" "wifi_has_ip"
check "iac se añade al grupo sudo en step 01" "steps/01_preparation.sh" "-G sudo iac"
check "locale-gen vía /etc/locale.gen (formato correcto)" "steps/01_preparation.sh" "LOCALE_CHARSET"
check "ntpsec-ntpdate fijo en step 01" "steps/01_preparation.sh" "ntpsec-ntpdate"
check "sin grub-install --removable redundante en step 06" "steps/06_grub_finalize.sh" "confirmed redundant"
check "pin anti-systemd-boot en Kali (step 08)" "steps/08_repositories.sh" "no-systemd-boot.pref"
check "Parrot en suite 'echo', no 'lts' (step 08)" "steps/08_repositories.sh" "deb.parrot.sh/parrot echo"
check "re-detección WiFi en step 08" "steps/08_repositories.sh" "step08_iface_redetected"
check "kali-linux-arm ya NO se instala (step 09)" "steps/09_package_installation.sh" "kali-linux-arm intentionally NOT installed"
check "Parrot instala escritorio KDE (step 09)" "steps/09_package_installation.sh" "parrot-desktop-kde"
check "fijado de MAC WiFi a wlan0 (step 09)" "steps/09_package_installation.sh" "70-persistent-wifi.rules"
check "i386 mirror firmado con signed-by (no rompe Kali/Parrot)" "lib/common.sh" "signed-by=\${ubuntu_keyring}"
check "i386 mirror acotado a bases Ubuntu (is_ubuntu_based)" "lib/common.sh" "is_ubuntu_based"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "TODO CORRECTO. Puedes arrancar con garantías (v1.5.1 completa y coherente)."
else
    echo "FALTAN COSAS. NO arranques todavía — vuelve a copiar el proyecto completo primero."
fi
exit $fail
