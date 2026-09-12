#!/bin/bash
#
# verify.sh — Run AFTER install.sh + cleanup.sh. Checks that the
# amd64-only binaries known to be broken on arm64 are no longer
# present (cleanup.sh moves them to backup), and that the binaries
# that ARE supported (radare2, via the osarch.sls macro) work
# correctly.
#
set -uo pipefail

# Binary -> ELF architecture check command.
# If the command fails or the binary doesn't exist, it's treated as "OK, not installed".
declare -A BROKEN_BINARIES=(
    [cutter]="cutter"
    [redress]="redress"
    [yr]="yr"
    [docker-compose]="docker-compose"
    [die]="die"
    [diec]="diec"
    [inspircd]="inspircd"
)

fail=0

echo "== Checking that the amd64-only binaries are NOT installed =="
for name in "${!BROKEN_BINARIES[@]}"; do
    bin="${BROKEN_BINARIES[$name]}"
    path=$(command -v "$bin" 2>/dev/null || true)
    if [ -z "$path" ]; then
        echo "  [OK]   $name: not installed"
        continue
    fi
    elf_out=$(file -b "$path" 2>/dev/null || echo "")
    if echo "$elf_out" | grep -qiE 'x86[_-]64'; then
        echo "  [MAL]  $name: installed at $path but is x86-64 (Exec format error expected)"
        fail=1
    elif echo "$elf_out" | grep -qiE 'aarch64|arm64'; then
        echo "  [INFO] $name: installed at $path and IS arm64 (upstream patch? check it)"
    elif echo "$elf_out" | grep -qi 'elf'; then
        echo "  [WARN] $name: installed at $path, ELF of unrecognized architecture ($elf_out)"
        fail=1
    else
        echo "  [INFO] $name: installed at $path as a script/wrapper, not ELF ($elf_out) — assumed OK"
    fi
done

echo ""
echo "== Checking that radare2 (osarch.sls macro) works =="
if command -v r2 >/dev/null 2>&1; then
    if r2 -v >/dev/null 2>&1; then
        echo "  [OK]   radare2 responds correctly: $(r2 -v | head -1)"
    else
        echo "  [MAL]  radare2 is installed but fails to run"
        fail=1
    fi
else
    echo "  [WARN] radare2 is not installed (check the install.sh log)"
fi

echo ""
if [ "$fail" -eq 0 ]; then
    echo "RESULT: verification OK."
else
    echo "RESULT: there are issues, check the detail above."
fi

# =============================================================================
# Native arm64 alternatives for the broken binaries
# =============================================================================
# These ALWAYS run, with no flags needed: after the verification above,
# this script directly installs docker-compose, redress, yr and die (the
# 4 confirmed working). cutter is skipped by default (no confirmed native
# alternative); use --with-cutter to try it anyway. inspircd is only
# installed with --install-inspircd-downgrade, since it's a version
# downgrade, not a clean substitute.
#
# Each binary uses whichever method suits it, so as not to drag in broken
# dependencies or step on system packages:
#   - docker-compose: native Ubuntu package (apt, no external repos)
#   - cutter:         the project's official repo (RizinOrg), pinned to
#                      low priority so it NEVER competes with Ubuntu's
#                      own archive for other packages (same pattern as
#                      Kali's pin in the base installer)
#   - redress:        native toolchain (apt's golang-go) + its own build;
#                      doesn't touch system libs beyond the build itself
#   - yr (yara-x):    rustup (an isolated Rust toolchain in $HOME), NOT
#                      apt's cargo (too old for yara-x-cli)
#   - inspircd:       ONLY behind a separate flag — Ubuntu's version
#                      (3.17.0) is 2 majors older than the 4.7.0 remnux
#                      requires, so it's not a clean substitute
#   - die/diec:       official Flatpak (Flathub), isolated from the
#                      system by design (doesn't touch apt dependencies
#                      at all)
# =============================================================================

install_docker_compose() {
    echo "[1/6] docker-compose -> docker-compose-plugin (already installed as a docker-ce dependency, native arm64)"
    if [ ! -e /usr/libexec/docker/cli-plugins/docker-compose ]; then
        echo "      WARNING: plugin not found; installing it just in case."
        sudo apt-get install -y docker-compose-plugin
    fi
    sudo ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
    echo "      Symlink created. Test with: docker-compose version  (or: docker compose version)"
}

install_cutter() {
    echo "[2/6] cutter -> cutter-re (RizinOrg's official repo, arm64, xUbuntu_24.04 build)"
    echo "      WARNING: the xUbuntu_22.04 build fails on Ubuntu 24.04 because it"
    echo "      depends on libpython3.10 (24.04 ships libpython3.12). This uses the"
    echo "      xUbuntu_24.04 folder of the same OBS repo, not 100% confirmed from"
    echo "      here (no direct access to the repo) — if it also fails, the"
    echo "      fallback is to compile Cutter from source."
    echo "      The repo is pinned to Pin-Priority 100 so it never overrides"
    echo "      packages from Ubuntu's main archive."
    curl -fsSL https://download.opensuse.org/repositories/home:RizinOrg/xUbuntu_24.04/Release.key \
        | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/home-rizinorg.gpg >/dev/null
    echo 'deb [signed-by=/etc/apt/trusted.gpg.d/home-rizinorg.gpg] https://download.opensuse.org/repositories/home:/RizinOrg/xUbuntu_24.04/ /' \
        | sudo tee /etc/apt/sources.list.d/home-rizinorg.list >/dev/null
    printf 'Package: *\nPin: origin download.opensuse.org\nPin-Priority: 100\n' \
        | sudo tee /etc/apt/preferences.d/rizinorg.pref >/dev/null
    sudo apt-get update
    if sudo apt-get install -y cutter-re; then
        echo "      Installed as 'cutter-re'. The binary usually ends up at"
        echo "      /usr/bin/cutter-re or similar — check 'dpkg -L cutter-re'"
        echo "      if you need a symlink to 'cutter'."
    else
        echo "      Also FAILED with xUbuntu_24.04. Alternative: build from"
        echo "      source (see https://github.com/rizinorg/cutter, Building Docs)"
        echo "      or use the x86_64 AppImage via FEX-Emu/Box64 (untested)."
    fi
}

install_redress() {
    echo "[3/6] redress -> compiled with native Go (golang-go, apt)"
    sudo apt-get install -y golang-go
    sudo GOBIN=/usr/local/bin go install github.com/goretk/redress@latest
    echo "      Installed at /usr/local/bin/redress. Test with: redress version"
}

install_yara_x() {
    echo "[4/6] yr (yara-x) -> compiled with Rust via rustup (NOT apt's cargo)"
    echo "      Ubuntu 24.04's repo cargo/rustc is 1.75.0;"
    echo "      yara-x-cli requires rustc >= 1.93. rustup installs a modern"
    echo "      toolchain isolated in \$HOME/.cargo, without touching system packages."
    if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    fi
    "$HOME/.cargo/bin/cargo" install yara-x-cli
    sudo ln -sf "$HOME/.cargo/bin/yr" /usr/local/bin/yr
    echo "      Installed. Test with: yr --version"
}

install_inspircd_downgrade() {
    echo "[5/6] inspircd -> WARNING: only v3.17.0 is available on Ubuntu arm64,"
    echo "      remnux.sls asks for v4.7.0. This is NOT a clean substitute:"
    echo "      v4 configs/modules may not work on v3."
    read -r -p "      Install Ubuntu's v3.17.0 anyway? [y/N] " ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        sudo apt-get install -y inspircd
        echo "      Installed v3.17.0 — review the config by hand."
    else
        echo "      Skipped."
    fi
}

install_detect_it_easy() {
    echo "[6/6] die/diec -> official Flatpak (Flathub, arm64)"
    sudo apt-get install -y flatpak
    sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    sudo flatpak install -y flathub io.github.horsicq.detect-it-easy
    sudo tee /usr/local/bin/die >/dev/null <<'WRAPPER'
#!/bin/bash
exec flatpak run io.github.horsicq.detect-it-easy "$@"
WRAPPER
    sudo chmod +x /usr/local/bin/die
    echo "      Installed as 'die' (Flatpak wrapper)."
    echo "      WARNING: not confirmed whether the Flatpak also exposes 'diec'"
    echo "      (console variant) as a separate command — check manually"
    echo "      with: flatpak run --command=diec io.github.horsicq.detect-it-easy --help"
}

install_arm64_alternatives() {
    install_docker_compose
    install_redress
    install_yara_x
    install_detect_it_easy
    echo ""
    echo "cutter: SKIPPED — no confirmed native arm64 alternative yet"
    echo "(RizinOrg repo tried on xUbuntu_22.04 and xUbuntu_24.04, both fail)."
    echo "To try installing it anyway: ./verify.sh --with-cutter"
    echo ""
    echo "inspircd NOT included automatically (a downgrade, not a clean substitute)."
    echo "To try it: ./verify.sh --install-inspircd-downgrade"
}

case "${1:-}" in
    --install-inspircd-downgrade)
        install_inspircd_downgrade
        ;;
    --with-cutter)
        install_cutter
        install_arm64_alternatives
        ;;
    *)
        install_arm64_alternatives
        ;;
esac

exit "$fail"
