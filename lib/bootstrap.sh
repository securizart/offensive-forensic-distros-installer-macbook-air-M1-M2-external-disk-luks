#!/bin/bash
# lib/bootstrap.sh
# Bootstrap común a todos los steps/*.sh: antes, cada step repetía ~10
# líneas idénticas (source de state/os_catalog/i18n, carga de idioma,
# source de common.sh, CURRENT_STEP_ID, init_step_log, require_root).
# Ahora basta con:
#
#   STEP_ID="02"
#   BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#   source "${BASE_DIR}/lib/bootstrap.sh"
#   step_bootstrap "$STEP_ID"
#
# BASE_DIR debe estar ya definido por el step (usa su propia ruta, así
# que no puede resolverse aquí dentro).

step_bootstrap() {
    local step_id="$1"
    source "${BASE_DIR}/lib/state.sh"
    source "${BASE_DIR}/lib/os_catalog.sh"
    source "${BASE_DIR}/lib/i18n.sh"
    [ -z "${IAC_LANG:-}" ] && IAC_LANG="$(i18n_detect_default_lang)"
    i18n_load "$IAC_LANG"
    source "${BASE_DIR}/lib/common.sh"
    CURRENT_STEP_ID="$step_id"
    init_step_log "$step_id"
    require_root
}
