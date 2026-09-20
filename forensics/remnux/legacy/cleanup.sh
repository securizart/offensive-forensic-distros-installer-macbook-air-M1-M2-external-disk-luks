#!/bin/bash
#
# cleanup.sh — Cleanup after install.sh (remnux.addon WITHOUT exclude=).
#
# remnux.addon silently leaves some loose ELF x86-64 binaries installed
# (Salt: Result: True) that throw "Exec format error" on arm64 when run,
# because their .sls files only do a file.managed/archive.extracted with
# a hash check, without any architecture check. This script finds them
# and moves them to a backup folder (it doesn't just delete them, in case
# you want to inspect them or already replaced them by hand).
#
# The [LOUD] category (inspircd, detect-it-easy) does NOT leave a
# half-installed binary: their pkg.installed via apt/dpkg aborts the whole
# transaction over unresolvable :amd64 dependencies, so there's nothing to
# clean up there apart from, potentially, apt's "held broken packages"
# state — see the APT section at the end of this script.
#
set -uo pipefail

BACKUP_DIR="${BACKUP_DIR:-$HOME/remnux-broken-binaries-backup}"
mkdir -p "$BACKUP_DIR"

# command -> originating package/.sls (informational reference only)
declare -A BROKEN_BINARIES=(
    [cutter]="remnux.tools.cutter"
    [redress]="remnux.tools.redress"
    [yr]="remnux.python3-packages.yara-x"
    [docker-compose]="remnux.tools.docker-compose"
)

moved=0
echo "== Looking for amd64 binaries known to be broken on arm64 =="
for bin in "${!BROKEN_BINARIES[@]}"; do
    src="remnux.addon:${BROKEN_BINARIES[$bin]}"
    path=$(command -v "$bin" 2>/dev/null || true)
    if [ -z "$path" ]; then
        echo "  [--]   $bin: not installed, nothing to do"
        continue
    fi
    elf_out=$(file -b "$path" 2>/dev/null || echo "")
    if ! echo "$elf_out" | grep -qiE 'x86[_-]64'; then
        echo "  [SKIP] $bin: installed at $path but is NOT x86-64 (arch: $elf_out) — leaving it alone"
        continue
    fi
    dest="$BACKUP_DIR/$(basename "$path").x86_64.bak"
    echo "  [MOVE] $bin: $path (x86-64) -> $dest  [source: $src]"
    if sudo mv "$path" "$dest" 2>/dev/null; then
        moved=$((moved + 1))
    else
        echo "         ERROR moving $path, check permissions manually"
    fi
done

echo ""
echo "== Binaries moved to backup: $moved (in $BACKUP_DIR) =="

# --- APT: check whether any packages were left "held broken" after the
#     failed attempts to install inspircd.sls / detect-it-easy.sls ---
echo ""
echo "== Checking apt state after the failed LOUD attempts =="
if sudo apt-get check >/tmp/remnux-apt-check.log 2>&1; then
    echo "  [OK] apt-get check reports no problems."
else
    echo "  [WARNING] apt-get check reports problems, see /tmp/remnux-apt-check.log"
    echo "  You can try to fix it with:"
    echo "    sudo apt --fix-broken install"
fi

echo ""
echo "Cleanup finished. Run ./verify.sh to confirm the final result."
