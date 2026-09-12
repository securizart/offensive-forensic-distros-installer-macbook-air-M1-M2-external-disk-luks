#!/bin/bash
# lib/i18n.sh
# Minimal string-translation engine. Text lives in i18n/strings.<lang>.sh
# as entries of an associative array STRINGS[key]="text with %s
# placeholders (printf format).
#
# Currently only English (i18n/strings.en.sh) ships with the project.
# The engine stays generic so a new language can be added later by
# copying that file, translating the values, and loading it.
#
# Usage:
#   t key arg1 arg2   -> prints the translated text with printf, with
#                        the arguments already substituted.

I18N_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../i18n" && pwd)"
declare -A STRINGS=()
IAC_LANG="${IAC_LANG:-}"

i18n_available_langs() {
    # Derives the language list from the strings.<lang>.sh files present,
    # so adding a new language doesn't require touching this file.
    local f lang
    for f in "$I18N_DIR"/strings.*.sh; do
        lang="$(basename "$f" .sh)"
        lang="${lang#strings.}"
        printf '%s\n' "$lang"
    done
}

i18n_detect_default_lang() {
    echo "en"
}

# i18n_load LANG -> loads i18n/strings.LANG.sh into STRINGS[]
i18n_load() {
    local lang="$1"
    local file="${I18N_DIR}/strings.${lang}.sh"
    if [ ! -f "$file" ]; then
        echo "i18n: $file does not exist, defaulting to 'en'" >&2
        lang="en"
        file="${I18N_DIR}/strings.en.sh"
    fi
    STRINGS=()
    # shellcheck source=/dev/null
    source "$file"
    IAC_LANG="$lang"
    export IAC_LANG
}

# t key [args...] -> translates and interpolates with printf
t() {
    local key="$1"; shift || true
    local fmt="${STRINGS[$key]:-}"
    if [ -z "$fmt" ]; then
        # Key not found: return the key itself so it's obvious on
        # screen/in logs that a translation is missing, instead of
        # failing outright.
        printf '[[%s]]' "$key"
        return
    fi
    # shellcheck disable=SC2059
    printf "$fmt\n" "$@"
}

# t_raw: same as t but without a trailing newline (for inline prompts)
t_raw() {
    local key="$1"; shift || true
    local fmt="${STRINGS[$key]:-}"
    if [ -z "$fmt" ]; then
        printf '[[%s]]' "$key"
        return
    fi
    # shellcheck disable=SC2059
    printf "$fmt" "$@"
}
