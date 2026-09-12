#!/bin/bash
#
# install.sh — Runs remnux.addon IN FULL on arm64 (Ubuntu Desktop
# 24.04 / Debian Asahi), without exclude=.
#
# Why not exclude=: using exclude=[...] with the .sls files known to be
# broken on arm64 makes Salt's (masterless, 3008.2) COMPILER abort
# before running anything, because other .sls files have a
# `require: sls: <the excluded one>` and Salt validates those
# references at compile time. See remnux/FINDINGS.md, section "Why
# exclude= isn't used", for the detail and the real log that confirmed
# this.
#
# Approach used instead: let remnux.addon apply in full, accepting the
# ~120 already-documented "Failed" states (~88% success), then run
# cleanup.sh afterwards to remove the broken binaries that DO end up
# installed silently (Salt marks them Succeeded even though the binary
# is x86-64 and won't run on arm64).
#
# Prerequisites (see DEPENDENCIES.md):
#   - Ubuntu/Debian arm64 with internet access
#   - Cast v1.0.4+ installed (see CAST-INSTALL.md)
#   - Salt 3008.2 installed in masterless mode (see CAST-INSTALL.md)
#   - remnux/salt-states cloned, typically via:
#       cast install remnux/salt-states
#     (cast clones the repo internally; requires `git` to be installed)
#
set -uo pipefail

SALT_STATES_DIR="${SALT_STATES_DIR:-$HOME/salt-states}"
LOG_FILE="${LOG_FILE:-$HOME/remnux-install-$(date +%Y%m%d-%H%M%S).log}"

if [ ! -d "$SALT_STATES_DIR" ]; then
    echo "ERROR: $SALT_STATES_DIR not found. Install it first with:"
    echo "  cast install remnux/salt-states"
    echo "or set the SALT_STATES_DIR variable."
    exit 1
fi

echo "== Checking architecture =="
ARCH=$(sudo salt-call --local grains.get osarch --out=txt | awk -F': ' '{print $2}')
echo "grains osarch = $ARCH"
if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "aarch64" ]; then
    echo "WARNING: detected architecture '$ARCH', this flow was validated on arm64."
    read -r -p "Continue anyway? [y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || exit 1
fi

echo "== Applying remnux.addon IN FULL, without exclude= (this can take ~20 min) =="
echo "Roughly ~120 known failed states are expected (~88% success)."
echo "When it's done, run ./cleanup.sh to remove the broken binaries and"
echo "./verify.sh to confirm the result."
echo ""

sudo salt-call --local state.apply remnux.addon \
    --state-output=changes --log-level=info 2>&1 | tee "$LOG_FILE"

SUCCEEDED=$(grep -c 'Result: True' "$LOG_FILE" || true)
FAILED=$(grep -c 'Result: False' "$LOG_FILE" || true)
echo ""
echo "== Result =="
echo "Full log at: $LOG_FILE"
echo "States with Result: True  -> $SUCCEEDED"
echo "States with Result: False -> $FAILED"
echo ""
echo "Next step: sudo ./cleanup.sh   (removes known broken binaries)"
echo "Then:      ./verify.sh         (confirms they're gone and radare2 works)"
