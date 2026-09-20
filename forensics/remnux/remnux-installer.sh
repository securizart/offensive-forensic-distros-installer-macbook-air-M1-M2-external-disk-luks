#!/bin/bash
#
# remnux-installer.sh — Script único para todo el proceso de instalación
# de REMnux en arm64 (Ubuntu Desktop 24.04 / Debian Asahi sobre Apple
# Silicon). Fusiona en un solo fichero lo que antes eran 4 scripts
# separados del test-kit (install.sh, cleanup.sh, verify.sh,
# install-extra-tools.sh), organizados como fases encadenables por flags.
#
# Usuario de destino de la instalación: "remnux" (contraseña "malware").
# Ver FINDINGS.md / DEPENDENCIES.md para el detalle de por qué (nota de
# instalación de Ubuntu/Asahi para este proyecto). Las VM de pruebas
# históricas usaron el usuario "iac"; este script asume $HOME del
# usuario que lo ejecuta, sea cual sea, así que basta con ejecutarlo
# como el usuario "remnux" en la instalación real.
#
# ---------------------------------------------------------------------
# FASES (en este orden fijo, independientemente de cómo se pidan):
#   1. base     — aplica remnux.addon COMPLETO en Salt, sin exclude=
#                 (exclude= rompe la compilación de Salt masterless
#                 3008.2 si un .sls excluido es referenciado por un
#                 require: de otro .sls no excluido). Se acepta el
#                 ~88% de éxito conocido (~120 Failed de 1009 estados).
#   2. cleanup  — mueve a backup los binarios x86-64 "silenciosos" que
#                 Salt marcó Succeeded pero que dan Exec format error
#                 en arm64 (cutter, redress, yr, docker-compose).
#   3. verify   — comprueba que esos binarios ya no están, que radare2
#                 funciona, e instala las 4 alternativas nativas arm64
#                 confirmadas sin matices: docker-compose (plugin apt),
#                 redress (Go nativo), yr/yara-x (Rust vía rustup),
#                 die/diec (Flatpak Flathub).
#   4. extra    — instala las 20 herramientas "NO-PKG" resueltas SIN
#                 matices (el PPA propio de REMnux solo compila amd64;
#                 estas se instalan desde el binario/repo/fuente
#                 OFICIAL del proyecto correspondiente en su lugar).
#   5. partial  — intenta/gestiona los casos "parcialmente resueltos",
#                 cada uno con una limitación real conocida y descrita:
#                   - cutter: intento vía repo RizinOrg (xUbuntu_24.04),
#                     SIN garantía confirmada al 100%.
#                   - inspircd: downgrade a v3.17.0 de Ubuntu (la v4.7.0
#                     que pide remnux no tiene build arm64), requiere
#                     confirmación interactiva explícita.
#                   - ghidra: release oficial funciona (GUI, desensam-
#                     blador, scripting), pero SIN decompilador nativo
#                     (sin build linux_arm_64, bug Gradle upstream sin
#                     resolver).
#                   - burpsuite-community: no automatizable (descarga
#                     con formulario/licencia), solo imprime la guía.
#
# FLAGS PRINCIPALES (combinables):
#   --all       fases 1-4 (base + cleanup + verify + extra)
#   --partial   fase 5 (cutter + inspircd + ghidra + guía burpsuite)
#   --all --partial   TODO el proceso de una vez
#
# FLAGS GRANULARES (para repetir una fase suelta o depurar):
#   --base | --cleanup | --verify | --extra
#   --with-cutter | --install-inspircd-downgrade | --ghidra | --burpsuite-guide
#   --<herramienta>   (una sola de las 20 de la fase "extra", ver --help)
#
# Requisitos previos: ver DEPENDENCIES.md / CAST-INSTALL.md
#   - Ubuntu/Debian arm64 con salida a internet
#   - Cast v1.0.4+ y Salt 3008.2 (masterless) ya instalados
#   - remnux/salt-states clonado (normalmente vía: cast install remnux/salt-states)
#
set -uo pipefail

SALT_STATES_DIR="${SALT_STATES_DIR:-$HOME/salt-states}"
LOG_FILE="${LOG_FILE:-$HOME/remnux-install-$(date +%Y%m%d-%H%M%S).log}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/remnux-broken-binaries-backup}"
WORKDIR="${WORKDIR:-$HOME/remnux-extra-tools-build}"

verify_fail=0

# =============================================================================
# FASE 1 — base: remnux.addon completo, sin exclude=
# =============================================================================

phase_base() {
    if [ ! -d "$SALT_STATES_DIR" ]; then
        echo "ERROR: no se encuentra $SALT_STATES_DIR. Instala primero con:"
        echo "  cast install remnux/salt-states"
        echo "o ajusta la variable SALT_STATES_DIR."
        exit 1
    fi

    echo "== [base] Verificando arquitectura =="
    ARCH=$(sudo salt-call --local grains.get osarch --out=txt | awk -F': ' '{print $2}')
    echo "grains osarch = $ARCH"
    if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "aarch64" ]; then
        echo "AVISO: arquitectura detectada '$ARCH', este flujo se validó en arm64."
        read -r -p "¿Continuar de todas formas? [y/N] " ans
        [ "$ans" = "y" ] || [ "$ans" = "Y" ] || exit 1
    fi

    echo "== [base] Aplicando remnux.addon COMPLETO, sin exclude= (esto puede tardar ~20 min) =="
    echo "Se esperan del orden de ~120 estados fallidos conocidos (~88% de éxito)."
    echo ""

    sudo salt-call --local state.apply remnux.addon \
        --state-output=changes --log-level=info 2>&1 | tee "$LOG_FILE"

    SUCCEEDED=$(grep -c 'Result: True' "$LOG_FILE" || true)
    FAILED=$(grep -c 'Result: False' "$LOG_FILE" || true)
    echo ""
    echo "== [base] Resultado =="
    echo "Log completo en: $LOG_FILE"
    echo "Estados con Result: True  -> $SUCCEEDED"
    echo "Estados con Result: False -> $FAILED"
}

# =============================================================================
# FASE 2 — cleanup: mover a backup los binarios x86-64 "silenciosos"
# =============================================================================

phase_cleanup() {
    mkdir -p "$BACKUP_DIR"

    declare -A silent_binaries=(
        [cutter]="remnux.tools.cutter"
        [redress]="remnux.tools.redress"
        [yr]="remnux.python3-packages.yara-x"
        [docker-compose]="remnux.tools.docker-compose"
    )

    moved=0
    echo "== [cleanup] Buscando binarios amd64 conocidos como rotos en arm64 =="
    for bin in "${!silent_binaries[@]}"; do
        src="remnux.addon:${silent_binaries[$bin]}"
        path=$(command -v "$bin" 2>/dev/null || true)
        if [ -z "$path" ]; then
            echo "  [--]   $bin: no está instalado, nada que hacer"
            continue
        fi
        elf_out=$(file -b "$path" 2>/dev/null || echo "")
        if ! echo "$elf_out" | grep -qiE 'x86[_-]64'; then
            echo "  [SKIP] $bin: instalado en $path pero NO es x86-64 (arch: $elf_out) — no se toca"
            continue
        fi
        dest="$BACKUP_DIR/$(basename "$path").x86_64.bak"
        echo "  [MOVE] $bin: $path (x86-64) -> $dest  [origen: $src]"
        if sudo mv "$path" "$dest" 2>/dev/null; then
            moved=$((moved + 1))
        else
            echo "         ERROR moviendo $path, revisa permisos manualmente"
        fi
    done

    echo ""
    echo "== [cleanup] Binarios movidos a backup: $moved (en $BACKUP_DIR) =="

    echo ""
    echo "== [cleanup] Comprobando estado de apt tras los intentos fallidos de RUIDOSO =="
    if sudo apt-get check >/tmp/remnux-apt-check.log 2>&1; then
        echo "  [OK] apt-get check no reporta problemas."
    else
        echo "  [AVISO] apt-get check reporta problemas, ver /tmp/remnux-apt-check.log"
        echo "  Puedes intentar arreglarlo con: sudo apt --fix-broken install"
    fi
}

# =============================================================================
# FASE 3 — verify: comprobación final + alternativas nativas arm64
# =============================================================================

phase_verify_check() {
    declare -A broken_binaries=(
        [cutter]="cutter"
        [redress]="redress"
        [yr]="yr"
        [docker-compose]="docker-compose"
        [die]="die"
        [diec]="diec"
        [inspircd]="inspircd"
    )

    echo "== [verify] Comprobando que los binarios amd64-only NO están instalados =="
    for name in "${!broken_binaries[@]}"; do
        bin="${broken_binaries[$name]}"
        path=$(command -v "$bin" 2>/dev/null || true)
        if [ -z "$path" ]; then
            echo "  [OK]   $name: no instalado"
            continue
        fi
        elf_out=$(file -b "$path" 2>/dev/null || echo "")
        if echo "$elf_out" | grep -qiE 'x86[_-]64'; then
            echo "  [MAL]  $name: instalado en $path pero es x86-64 (Exec format error esperado)"
            verify_fail=1
        elif echo "$elf_out" | grep -qiE 'aarch64|arm64'; then
            echo "  [INFO] $name: instalado en $path y SÍ es arm64 (¿parche upstream? revisar)"
        elif echo "$elf_out" | grep -qi 'elf'; then
            echo "  [WARN] $name: instalado en $path, ELF de arquitectura no reconocida ($elf_out)"
            verify_fail=1
        else
            echo "  [INFO] $name: instalado en $path como script/wrapper, no ELF ($elf_out) — asumido OK"
        fi
    done

    echo ""
    echo "== [verify] Comprobando que radare2 (macro osarch.sls) funciona =="
    if command -v r2 >/dev/null 2>&1; then
        if r2 -v >/dev/null 2>&1; then
            echo "  [OK]   radare2 responde correctamente: $(r2 -v | head -1)"
        else
            echo "  [MAL]  radare2 instalado pero falla al ejecutar"
            verify_fail=1
        fi
    else
        echo "  [WARN] radare2 no está instalado (revisar log de la fase base)"
    fi

    echo ""
    if [ "$verify_fail" -eq 0 ]; then
        echo "[verify] RESULTADO: verificación OK."
    else
        echo "[verify] RESULTADO: hay incidencias, revisa el detalle arriba."
    fi
}

install_docker_compose() {
    echo "[verify 1/4] docker-compose -> docker-compose-plugin (dependencia de docker-ce, arm64 nativo)"
    if [ ! -e /usr/libexec/docker/cli-plugins/docker-compose ]; then
        echo "      AVISO: no se encuentra el plugin; instalando por si acaso."
        sudo apt-get install -y docker-compose-plugin
    fi
    sudo ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
    echo "      Symlink creado. Prueba: docker-compose version  (o: docker compose version)"
}

install_redress() {
    echo "[verify 2/4] redress -> compilado con Go nativo (golang-go, apt)"
    sudo apt-get install -y golang-go
    sudo GOBIN=/usr/local/bin go install github.com/goretk/redress@latest
    echo "      Instalado en /usr/local/bin/redress. Prueba: redress version"
}

install_yara_x() {
    echo "[verify 3/4] yr (yara-x) -> compilado con Rust vía rustup (NO el cargo de apt)"
    echo "      cargo/rustc de Ubuntu 24.04 es 1.75.0; yara-x-cli exige rustc >= 1.93."
    if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    fi
    "$HOME/.cargo/bin/cargo" install yara-x-cli
    sudo ln -sf "$HOME/.cargo/bin/yr" /usr/local/bin/yr
    echo "      Instalado. Prueba: yr --version"
}

install_detect_it_easy() {
    echo "[verify 4/4] die/diec -> Flatpak oficial (Flathub, arm64)"
    sudo apt-get install -y flatpak
    sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    sudo flatpak install -y flathub io.github.horsicq.detect-it-easy
    sudo tee /usr/local/bin/die >/dev/null <<'WRAPPER'
#!/bin/bash
exec flatpak run io.github.horsicq.detect-it-easy "$@"
WRAPPER
    sudo chmod +x /usr/local/bin/die
    echo "      Instalado como 'die' (wrapper a Flatpak)."
    echo "      Para 'diec': flatpak run --command=diec io.github.horsicq.detect-it-easy --help"
}

phase_verify() {
    phase_verify_check
    echo ""
    echo "== [verify] Instalando alternativas nativas arm64 confirmadas sin matices =="
    install_docker_compose
    install_redress
    install_yara_x
    install_detect_it_easy
    echo ""
    echo "cutter e inspircd NO se instalan aquí (parcialmente resueltos, con matiz real) -> usa --partial"
}

# =============================================================================
# FASE 4 — extra: 20 herramientas NO-PKG resueltas SIN matices
# =============================================================================

install_powershell() {
    echo "[extra] powershell -> .deb oficial arm64 de Microsoft"
    local url
    url=$(curl -s https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
        | grep -o 'https://[^"]*deb_arm64\.deb' | head -1)
    if [ -z "$url" ]; then
        echo "      No se pudo resolver la URL automáticamente, usando versión conocida 7.6.6"
        url="https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell_7.6.6-1.deb_arm64.deb"
    fi
    curl -fsSL -o "$WORKDIR/powershell-arm64.deb" "$url"
    sudo apt-get install -y "$WORKDIR/powershell-arm64.deb"
    echo "      Prueba: pwsh --version"
}

install_7zz() {
    echo "[extra] 7zz -> binario oficial arm64 de 7-zip.org"
    local rel
    rel=$(curl -s https://www.7-zip.org/download.html | grep -oE 'a/7z[0-9]+-linux-arm64\.tar\.xz' | head -1)
    if [ -z "$rel" ]; then
        echo "      No se pudo resolver la URL automáticamente, revisa https://www.7-zip.org/download.html"
        return 1
    fi
    curl -fsSL -o "$WORKDIR/7zz-linux-arm64.tar.xz" "https://www.7-zip.org/$rel"
    mkdir -p "$WORKDIR/7zz-install"
    tar xf "$WORKDIR/7zz-linux-arm64.tar.xz" -C "$WORKDIR/7zz-install"
    sudo install -m 755 "$WORKDIR/7zz-install/7zz" /usr/local/bin/7zz
    echo "      Prueba: 7zz i"
}

install_unrar() {
    echo "[extra] unrar -> compilado desde fuente oficial de rarlab.com (solo EXTRACCIÓN)"
    echo "        ('rar', el archivador completo para CREAR .rar, es Categoría A: sin build"
    echo "         arm64 Linux de RARLAB, solo vía emulación QEMU/FEX)"
    curl -fsSL -o "$WORKDIR/unrarsrc.tar.gz" https://www.rarlab.com/rar/unrarsrc-7.2.4.tar.gz
    (cd "$WORKDIR" && tar xzf unrarsrc.tar.gz && cd unrar && make -f makefile)
    sudo install -v -m755 "$WORKDIR/unrar/unrar" /usr/local/bin/
    echo "      Prueba: unrar"
}

install_aeskeyfind() {
    echo "[extra] aeskeyfind -> compilado desde fuente (mbroz/aeskeyfind)"
    git clone --depth 1 https://github.com/mbroz/aeskeyfind.git "$WORKDIR/aeskeyfind" 2>/dev/null \
        || (cd "$WORKDIR/aeskeyfind" && git pull)
    (cd "$WORKDIR/aeskeyfind" && make)
    sudo install -m755 "$WORKDIR/aeskeyfind/aeskeyfind" /usr/local/bin/
    echo "      Prueba: aeskeyfind -h"
}

install_xorsearch() {
    echo "[extra] xorsearch -> vía la versión Python de DidierStevensSuite (agnóstica de arquitectura)"
    echo "        NOTA: 'xorstrings' NO tiene equivalente resuelto en este mirror, sigue aparcado."
    git clone --depth 1 https://github.com/DidierStevens/DidierStevensSuite.git "$WORKDIR/DidierStevensSuite" 2>/dev/null \
        || (cd "$WORKDIR/DidierStevensSuite" && git pull)
    sudo tee /usr/local/bin/xorsearch >/dev/null <<WRAPPER
#!/bin/bash
exec python3 "$WORKDIR/DidierStevensSuite/xorsearch.py" "\$@"
WRAPPER
    sudo chmod +x /usr/local/bin/xorsearch
    echo "      Prueba: xorsearch -h"
}

install_jd_gui() {
    echo "[extra] jd-gui -> jar oficial (java-decompiler/jd-gui), requiere JDK"
    curl -fsSL -o "$WORKDIR/jd-gui.jar" \
        https://github.com/java-decompiler/jd-gui/releases/download/v1.6.6/jd-gui-1.6.6.jar
    sudo install -m755 -d /opt/jd-gui
    sudo install -m644 "$WORKDIR/jd-gui.jar" /opt/jd-gui/jd-gui.jar
    sudo tee /usr/local/bin/jd-gui >/dev/null <<'WRAPPER'
#!/bin/bash
exec java -jar /opt/jd-gui/jd-gui.jar "$@"
WRAPPER
    sudo chmod +x /usr/local/bin/jd-gui
    echo "      Prueba: jd-gui (abre GUI)"
}

install_baksmali() {
    echo "[extra] baksmali -> fat jar oficial (baksmali/smali), requiere JDK"
    local url
    url=$(curl -s https://api.github.com/repos/baksmali/smali/releases/latest \
        | grep -o 'https://[^"]*baksmali-[0-9.]*-fat\.jar' | head -1)
    if [ -z "$url" ]; then
        echo "      No se pudo resolver automáticamente, usando versión conocida 3.0.10"
        url="https://github.com/baksmali/smali/releases/download/3.0.10/baksmali-3.0.10-fat.jar"
    fi
    curl -fsSL -o "$WORKDIR/baksmali.jar" "$url"
    sudo install -m755 -d /opt/baksmali
    sudo install -m644 "$WORKDIR/baksmali.jar" /opt/baksmali/baksmali.jar
    sudo tee /usr/local/bin/baksmali >/dev/null <<'WRAPPER'
#!/bin/bash
exec java -jar /opt/baksmali/baksmali.jar "$@"
WRAPPER
    sudo chmod +x /usr/local/bin/baksmali
    echo "      Prueba: baksmali --version"
}

install_binee() {
    echo "[extra] binee -> compilado con Go (carbonblack/binee), depende de Unicorn Engine"
    sudo apt-get install -y libunicorn-dev golang-go
    git clone --depth 1 https://github.com/carbonblack/binee.git "$WORKDIR/binee" 2>/dev/null \
        || (cd "$WORKDIR/binee" && git pull)
    (cd "$WORKDIR/binee" && go build -o binee .)
    sudo install -m755 "$WORKDIR/binee/binee" /usr/local/bin/
    echo "      Prueba: binee -h"
}

install_manalyze() {
    echo "[extra] manalyze -> compilado con CMake (JusticeRage/Manalyze)"
    sudo apt-get install -y libboost-regex-dev libboost-program-options-dev \
        libboost-system-dev libboost-filesystem-dev libssl-dev cmake
    git clone --depth 1 https://github.com/JusticeRage/Manalyze.git "$WORKDIR/Manalyze" 2>/dev/null \
        || (cd "$WORKDIR/Manalyze" && git pull)
    (cd "$WORKDIR/Manalyze" && cmake . && make -j"$(nproc)")
    sudo install -m755 "$WORKDIR/Manalyze/bin/manalyze" /usr/local/bin/
    echo "      Prueba: manalyze --version"
}

install_bearparser() {
    echo "[extra] bearparser -> compilado con CMake + Qt5 (hasherezade/bearparser)"
    sudo apt-get install -y qtbase5-dev cmake
    git clone --depth 1 https://github.com/hasherezade/bearparser.git "$WORKDIR/bearparser-src" 2>/dev/null \
        || (cd "$WORKDIR/bearparser-src" && git pull)
    mkdir -p "$WORKDIR/bearparser-build"
    (cd "$WORKDIR/bearparser-build" && cmake -G "Unix Makefiles" "$WORKDIR/bearparser-src/" && make -j"$(nproc)")
    sudo install -m755 "$WORKDIR/bearparser-build/commander/bearcommander" /usr/local/bin/
    echo "      Prueba: bearcommander"
}

install_pycdc() {
    echo "[extra] pycdc/pycdas -> compilado con CMake, sin dependencias externas (zrax/pycdc)"
    sudo apt-get install -y cmake
    git clone --depth 1 https://github.com/zrax/pycdc.git "$WORKDIR/pycdc" 2>/dev/null \
        || (cd "$WORKDIR/pycdc" && git pull)
    mkdir -p "$WORKDIR/pycdc/build"
    (cd "$WORKDIR/pycdc/build" && cmake -DCMAKE_BUILD_TYPE=Release .. && make -j"$(nproc)")
    sudo install -m755 "$WORKDIR/pycdc/build/pycdc" /usr/local/bin/
    sudo install -m755 "$WORKDIR/pycdc/build/pycdas" /usr/local/bin/
    echo "      Prueba: pycdas --help"
}

install_msoffice_crypt() {
    echo "[extra] msoffice-crypt -> compilado con make (herumi/msoffice + herumi/cybozulib)"
    mkdir -p "$WORKDIR/msoffice-work" && cd "$WORKDIR/msoffice-work"
    git clone --depth 1 https://github.com/herumi/cybozulib 2>/dev/null || (cd cybozulib && git pull)
    git clone --depth 1 https://github.com/herumi/msoffice 2>/dev/null || true
    (cd msoffice && mkdir -p bin && make -j"$(nproc)" RELEASE=1)
    sudo install -m755 "$WORKDIR/msoffice-work/msoffice/bin/msoffice-crypt.exe" /usr/local/bin/msoffice-crypt
    cd - >/dev/null
    echo "      Prueba: msoffice-crypt -h  (nota: se instala sin el sufijo .exe)"
}

install_portex() {
    echo "[extra] portex -> CLI ya compilada (PortexAnalyzer.jar, struppigel/PortEx), requiere JDK"
    curl -fsSL -o "$WORKDIR/PortexAnalyzer.jar" \
        https://github.com/struppigel/PortEx/releases/latest/download/PortexAnalyzer.jar
    sudo install -m755 -d /opt/portex
    sudo install -m644 "$WORKDIR/PortexAnalyzer.jar" /opt/portex/PortexAnalyzer.jar
    sudo tee /usr/local/bin/portex >/dev/null <<'WRAPPER'
#!/bin/bash
exec java -jar /opt/portex/PortexAnalyzer.jar "$@"
WRAPPER
    sudo chmod +x /usr/local/bin/portex
    echo "      Prueba: portex -v"
}

install_signsrch() {
    echo "[extra] signsrch -> compilado con make (mirror sandsmark/signsrch del original de Luigi Auriemma)"
    git clone --depth 1 https://github.com/sandsmark/signsrch.git "$WORKDIR/signsrch" 2>/dev/null \
        || (cd "$WORKDIR/signsrch" && git pull)
    (cd "$WORKDIR/signsrch" && make)
    sudo install -m755 "$WORKDIR/signsrch/signsrch" /usr/local/bin/
    echo "      Prueba: signsrch"
    echo "      NOTA: hace falta también signsrch.sig (firmas), aparte, de http://aluigi.org/mytoolz/signsrch.sig.zip"
}

install_ilspycmd() {
    echo "[extra] ilspycmd -> herramienta dotnet (ICSharpCode.ILSpy), requiere .NET SDK 8"
    sudo apt-get install -y dotnet-sdk-8.0 2>/dev/null \
        || { wget -q https://dot.net/v1/dotnet-install.sh -O "$WORKDIR/dotnet-install.sh" \
             && bash "$WORKDIR/dotnet-install.sh" --channel 8.0; }
    export PATH="$PATH:$HOME/.dotnet:$HOME/.dotnet/tools"
    dotnet nuget locals all --clear >/dev/null 2>&1 || true
    dotnet tool install --global ilspycmd --version 9.1.0.7988 \
        || dotnet tool update --global ilspycmd --version 9.1.0.7988 --allow-downgrade
    echo "      Prueba: ilspycmd --version  (asegúrate de tener \$HOME/.dotnet/tools en el PATH)"
}

install_flare_floss() {
    echo "[extra] flare-floss -> Mandiant FLARE team, vía pip (incluye vivisect, sin problema en arm64)"
    pip install flare-floss --break-system-packages
    echo "      Prueba: floss --help  (asegúrate de tener \$HOME/.local/bin en el PATH)"
}

install_evilclippy() {
    echo "[extra] evilclippy -> compilado con Mono (outflanknl/EvilClippy, no distribuye binario)"
    sudo apt-get install -y mono-complete
    git clone --depth 1 https://github.com/outflanknl/EvilClippy.git "$WORKDIR/EvilClippy" 2>/dev/null \
        || (cd "$WORKDIR/EvilClippy" && git pull)
    (cd "$WORKDIR/EvilClippy" && mcs /reference:OpenMcdf.dll,System.IO.Compression.FileSystem.dll -out:EvilClippy.exe *.cs)
    sudo install -m755 -d /opt/evilclippy
    sudo install -m644 "$WORKDIR/EvilClippy/EvilClippy.exe" /opt/evilclippy/
    sudo tee /usr/local/bin/evilclippy >/dev/null <<'WRAPPER'
#!/bin/bash
exec mono /opt/evilclippy/EvilClippy.exe "$@"
WRAPPER
    sudo chmod +x /usr/local/bin/evilclippy
    echo "      Prueba: evilclippy -h"
}

install_android_project_creator() {
    echo "[extra] android-project-creator -> jar oficial con dependencias (ThisIsLibra/AndroidProjectCreator), requiere JDK"
    local url
    url=$(curl -s https://api.github.com/repos/ThisIsLibra/AndroidProjectCreator/releases/latest \
        | grep -o 'https://[^"]*\.jar' | head -1)
    if [ -z "$url" ]; then
        echo "      No se pudo resolver automáticamente, usando versión conocida 1.5.2-stable"
        url="https://github.com/ThisIsLibra/AndroidProjectCreator/releases/download/1.5.2-stable/AndroidProjectCreator-1.5.2-stable-jar-with-dependencies.jar"
    fi
    curl -fsSL -o "$WORKDIR/AndroidProjectCreator.jar" "$url"
    sudo install -m755 -d /opt/android-project-creator
    sudo install -m644 "$WORKDIR/AndroidProjectCreator.jar" /opt/android-project-creator/
    sudo tee /usr/local/bin/AndroidProjectCreator >/dev/null <<'WRAPPER'
#!/bin/bash
exec java -jar /opt/android-project-creator/AndroidProjectCreator.jar "$@"
WRAPPER
    sudo chmod +x /usr/local/bin/AndroidProjectCreator
    echo "      Prueba: AndroidProjectCreator -h"
}

install_sandfly_processdecloak() {
    echo "[extra] sandfly-processdecloak -> compilado con Go (sandflysecurity/sandfly-processdecloak)"
    sudo apt-get install -y golang-go
    git clone --depth 1 https://github.com/sandflysecurity/sandfly-processdecloak.git "$WORKDIR/sandfly-processdecloak" 2>/dev/null \
        || (cd "$WORKDIR/sandfly-processdecloak" && git pull)
    (cd "$WORKDIR/sandfly-processdecloak" && go build -o sandfly-processdecloak .)
    sudo install -m755 "$WORKDIR/sandfly-processdecloak/sandfly-processdecloak" /usr/local/bin/
    echo "      Prueba: sandfly-processdecloak"
}

phase_extra() {
    mkdir -p "$WORKDIR"
    install_powershell
    install_7zz
    install_unrar
    install_aeskeyfind
    install_xorsearch
    install_jd_gui
    install_baksmali
    install_binee
    install_manalyze
    install_bearparser
    install_pycdc
    install_msoffice_crypt
    install_portex
    install_signsrch
    install_ilspycmd
    install_flare_floss
    install_evilclippy
    install_android_project_creator
    install_sandfly_processdecloak
    echo ""
    echo "[extra] 19 herramientas de la fase 'extra' completadas."
    echo "Ghidra y Burp Suite Community van en --partial (con matiz / guía manual)."
}

# =============================================================================
# FASE 5 — partial: casos parcialmente resueltos, con matiz real conocido
# =============================================================================

install_cutter() {
    echo "[partial] cutter -> cutter-re (repo oficial RizinOrg)"
    echo "      AVISO: CONFIRMADO FALLIDO en AMBOS repos OBS de RizinOrg — xUbuntu_22.04"
    echo "      (libpython3.10 vs libpython3.12 del sistema) y xUbuntu_24.04 (fallo"
    echo "      confirmado en la práctica, no solo teórico). Este intento probablemente"
    echo "      volverá a fallar; la única vía que queda es compilar Cutter desde fuente"
    echo "      (https://github.com/rizinorg/cutter, Building Docs), no automatizada aquí."
    curl -fsSL https://download.opensuse.org/repositories/home:RizinOrg/xUbuntu_24.04/Release.key \
        | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/home-rizinorg.gpg >/dev/null
    echo 'deb [signed-by=/etc/apt/trusted.gpg.d/home-rizinorg.gpg] https://download.opensuse.org/repositories/home:/RizinOrg/xUbuntu_24.04/ /' \
        | sudo tee /etc/apt/sources.list.d/home-rizinorg.list >/dev/null
    printf 'Package: *\nPin: origin download.opensuse.org\nPin-Priority: 100\n' \
        | sudo tee /etc/apt/preferences.d/rizinorg.pref >/dev/null
    sudo apt-get update
    if sudo apt-get install -y cutter-re; then
        echo "      Instalado como 'cutter-re' — revisa 'dpkg -L cutter-re' si necesitas symlink a 'cutter'."
    else
        echo "      FALLÓ también con xUbuntu_24.04. Alternativa: compilar desde fuente"
        echo "      (https://github.com/rizinorg/cutter, Building Docs) o AppImage x86_64"
        echo "      vía FEX-Emu/Box64 (no probado)."
    fi
}

install_inspircd_downgrade() {
    echo "[partial] inspircd -> AVISO: solo hay v3.17.0 en Ubuntu arm64, remnux pide v4.7.0."
    echo "      Esto NO es un sustituto limpio: configs/módulos de la v4 pueden no funcionar en la v3."
    read -r -p "      ¿Instalar igualmente la v3.17.0 de Ubuntu? [y/N] " ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        sudo apt-get install -y inspircd
        echo "      Instalada v3.17.0 — revisa la config manualmente."
    else
        echo "      Omitido."
    fi
}

install_ghidra() {
    echo "[partial] ghidra -> release oficial multiplataforma (NationalSecurityAgency/ghidra)"
    echo "      AVISO: GUI y desensamblador funcionan perfectamente en arm64, pero el"
    echo "      DECOMPILADOR NATIVO no tiene build linux_arm_64 oficial y compilarlo"
    echo "      choca con un bug conocido sin resolver upstream (issues #7958/#5204)."
    echo "      Queda utilizable para desensamblador, navegación y scripting, SIN decompilador."
    mkdir -p "$WORKDIR"
    sudo apt-get install -y openjdk-21-jdk unzip
    curl -fsSL -o "$WORKDIR/ghidra.zip" \
        https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.3_build/ghidra_12.1.3_PUBLIC_20260817.zip
    echo "93a5d11a9ad510622acaaf908c556a7b9b764d338e78a7567f3689bf5081fd54  $WORKDIR/ghidra.zip" | sha256sum -c - \
        || { echo "      ERROR: el hash SHA256 no coincide, aborta (puede que haya salido una versión nueva)"; return 1; }
    sudo unzip -q -o "$WORKDIR/ghidra.zip" -d /opt
    sudo ln -sf /opt/ghidra_12.1.3_PUBLIC/ghidraRun /usr/local/bin/ghidra
    echo "      Prueba: ghidra (abre GUI, con warning esperado de componentes nativos)"
}

guide_burpsuite() {
    cat <<'EOF'
[partial] burpsuite-community -> NO se puede automatizar con una URL fija: PortSwigger
sirve el instalador desde un formulario de descarga, no una URL estática.
Pasos manuales (confirmado funcionando):
  1. Abre un navegador DENTRO de la VM arm64
  2. Ve a https://portswigger.net/burp/communitydownload
  3. Elige explícitamente la build "Linux (ARM)" (NO "Linux (x64)")
  4. chmod +x burpsuite_community_linux_v*.sh && sudo ./burpsuite_community_linux_v*.sh
Incluye su propia JRE embebida, sin depender de pkgrepo:remnux.
EOF
}

phase_partial() {
    install_cutter
    echo ""
    install_inspircd_downgrade
    echo ""
    install_ghidra
    echo ""
    guide_burpsuite
}

# =============================================================================
# FASE 6 — menu: accesos directos en el menú de aplicaciones (GNOME Shell)
# =============================================================================
#
# Genera entradas .desktop en $HOME/.local/share/applications/ SOLO para
# las herramientas que estén realmente instaladas en esta máquina en el
# momento de ejecutar --menu (se comprueba con `command -v` antes de
# escribir cada entrada) — así el menú siempre refleja exactamente qué
# combinación de --all/--partial/flags sueltos se ha aplicado, sin
# entradas rotas apuntando a binarios que no llegaron a instalarse.
#
# Nota sobre iconos: se usan nombres de icono genéricos del tema estándar
# (utilities-terminal para CLI, applications-development para GUI de
# ingeniería inversa) porque ninguna de estas herramientas trae icono
# propio al instalarse por estas vías alternativas (compilación, jar
# suelto, pip, etc. — no son paquetes .deb con assets). Si se quiere un
# icono específico por herramienta, basta con cambiar el campo Icon= del
# .desktop correspondiente o el último campo de la tabla MENU_TOOLS de
# abajo.
#
# Formato de cada fila de MENU_TOOLS:
#   comando|Nombre a mostrar|Comentario|MODO|comando de ejemplo|icono
# MODO: GUI (Terminal=false, se lanza tal cual) | CLI (Terminal=true,
# ejecuta el comando de ejemplo y deja una shell abierta) | CLI_SHELL
# (Terminal=true, abre directamente el intérprete, sin comando de ejemplo)

DESKTOP_DIR="${DESKTOP_DIR:-$HOME/.local/share/applications}"

MENU_TOOLS=(
    "jd-gui|JD-GUI|Decompilador Java con interfaz gráfica|GUI|jd-gui|applications-development"
    "ghidra|Ghidra|Desensamblador e ingeniería inversa (sin decompilador nativo en arm64)|GUI|ghidra|applications-development"
    "die|Detect It Easy|Identificación de tipos de fichero y packers (GUI)|GUI|die|applications-development"
    "pwsh|PowerShell|Shell multiplataforma de Microsoft|CLI_SHELL|pwsh|utilities-terminal"
    "7zz|7-Zip (7zz)|Compresor/descompresor 7-Zip|CLI|7zz i|utilities-terminal"
    "unrar|UnRAR|Extractor de archivos RAR|CLI|unrar|utilities-terminal"
    "aeskeyfind|AESKeyFind|Búsqueda de claves AES en memoria|CLI|aeskeyfind -h|utilities-terminal"
    "xorsearch|XorSearch|Búsqueda de cadenas con XOR/ROL/ROT (DidierStevensSuite)|CLI|xorsearch -h|utilities-terminal"
    "baksmali|Baksmali|Desensamblador de bytecode Dalvik/Android|CLI|baksmali --version|utilities-terminal"
    "binee|Binee|Emulador de binarios Windows PE vía Unicorn|CLI|binee -h|utilities-terminal"
    "manalyze|Manalyze|Análisis estático de ejecutables PE|CLI|manalyze --version|utilities-terminal"
    "bearcommander|BearParser|Parser de ficheros PE (hasherezade)|CLI|bearcommander|utilities-terminal"
    "pycdc|PyCdc|Decompilador de bytecode Python|CLI|pycdc --help|utilities-terminal"
    "pycdas|PyCdas|Analizador de bytecode compilado Python|CLI|pycdas --help|utilities-terminal"
    "msoffice-crypt|MSOffice-Crypt|Cifrado/descifrado de documentos Office|CLI|msoffice-crypt -h|utilities-terminal"
    "portex|PortEx|Análisis de ficheros PE (Java)|CLI|portex -v|utilities-terminal"
    "signsrch|SignSrch|Búsqueda de firmas de algoritmos criptográficos|CLI|signsrch|utilities-terminal"
    "ilspycmd|ILSpyCmd|Decompilador de ensamblados .NET|CLI|ilspycmd --version|utilities-terminal"
    "floss|FLARE FLOSS|Extracción de cadenas ofuscadas (Mandiant)|CLI|floss --help|utilities-terminal"
    "evilclippy|EvilClippy|Manipulación de macros VBA maliciosas|CLI|evilclippy -h|utilities-terminal"
    "AndroidProjectCreator|Android Project Creator|Generador de proyectos Android desde APK|CLI|AndroidProjectCreator -h|utilities-terminal"
    "sandfly-processdecloak|Sandfly ProcessDecloak|Detección de procesos ocultos tipo rootkit LKM|CLI|sandfly-processdecloak|utilities-terminal"
    "redress|ReDress|Recuperación de información de binarios Go|CLI|redress version|utilities-terminal"
    "yr|YARA-X|Motor YARA reescrito en Rust|CLI|yr --version|utilities-terminal"
    "docker-compose|Docker Compose|Orquestación de contenedores Docker|CLI|docker-compose version|utilities-terminal"
)

write_desktop_entry() {
    # $1=id_fichero $2=Name $3=Comment $4=Exec $5=Terminal(true/false) $6=Icon
    local id="$1" name="$2" comment="$3" exec_line="$4" terminal="$5" icon="$6"
    local dest="$DESKTOP_DIR/remnux-${id}.desktop"
    cat > "$dest" <<EOF
[Desktop Entry]
Type=Application
Name=${name}
Comment=${comment}
Exec=${exec_line}
Terminal=${terminal}
Icon=${icon}
Categories=Utility;Security;
EOF
    echo "  [OK] $name -> $dest"
}

phase_menu() {
    mkdir -p "$DESKTOP_DIR"
    echo "== [menu] Generando accesos en $DESKTOP_DIR (solo para lo que esté instalado) =="

    local created=0 skipped=0
    for row in "${MENU_TOOLS[@]}"; do
        IFS='|' read -r cmd name comment mode sample icon <<< "$row"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "  [--] $name: '$cmd' no está instalado, se omite"
            skipped=$((skipped + 1))
            continue
        fi
        case "$mode" in
            GUI)
                write_desktop_entry "$cmd" "$name" "$comment" "$sample" "false" "$icon"
                ;;
            CLI_SHELL)
                write_desktop_entry "$cmd" "$name" "$comment" "$sample" "true" "$icon"
                ;;
            CLI)
                write_desktop_entry "$cmd" "$name" "$comment" "bash -c '${sample} ; exec bash'" "true" "$icon"
                ;;
        esac
        created=$((created + 1))
    done

    # Casos especiales: no son un comando plano en PATH -----------------

    # cutter: el paquete cutter-re puede exponer el binario como 'cutter'
    # o como 'cutter-re' según cómo haya quedado el symlink (ver verify.sh
    # --with-cutter). Se comprueba primero 'cutter', luego 'cutter-re'.
    if command -v cutter >/dev/null 2>&1; then
        write_desktop_entry "cutter" "Cutter" "Interfaz gráfica para Rizin (ingeniería inversa)" "cutter" "false" "applications-development"
        created=$((created + 1))
    elif command -v cutter-re >/dev/null 2>&1; then
        write_desktop_entry "cutter-re" "Cutter" "Interfaz gráfica para Rizin (ingeniería inversa)" "cutter-re" "false" "applications-development"
        created=$((created + 1))
    else
        echo "  [--] Cutter: no está instalado, se omite"
        skipped=$((skipped + 1))
    fi

    # diec: variante consola de Detect It Easy, se invoca vía flatpak run
    # --command=, no es un binario propio en PATH.
    if command -v flatpak >/dev/null 2>&1 \
        && flatpak info io.github.horsicq.detect-it-easy >/dev/null 2>&1; then
        write_desktop_entry "diec" "Detect It Easy (consola)" \
            "Identificación de tipos de fichero y packers, variante CLI" \
            "bash -c 'flatpak run --command=diec io.github.horsicq.detect-it-easy --help ; exec bash'" \
            "true" "utilities-terminal"
        created=$((created + 1))
    else
        echo "  [--] Detect It Easy (consola): Flatpak no instalado, se omite"
        skipped=$((skipped + 1))
    fi

    echo ""
    echo "== [menu] Accesos creados: $created — omitidos (no instalados): $skipped =="
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    fi
    echo "GNOME Shell los recoge automáticamente (búscalos en Actividades); si no"
    echo "aparecen enseguida, cierra sesión y vuelve a entrar."
}

# =============================================================================
# Dispatcher — flags combinables
# =============================================================================

usage() {
    cat <<'EOF'
Uso: ./remnux-installer.sh [flags]

Flags principales (combinables):
  --all       Fases base + cleanup + verify + extra (el ~88% + 4 alternativas + 19 NO-PKG)
  --partial   Fase de casos parcialmente resueltos (cutter, inspircd, ghidra, guía burpsuite)
  --menu      Genera accesos .desktop en el menú de GNOME SOLO para lo que
              esté realmente instalado en esta máquina (se puede repetir
              en cualquier momento, es idempotente)

  ./remnux-installer.sh --all --partial --menu   -> instalación completa + accesos de menú

Flags granulares (una fase o herramienta suelta):
  --base | --cleanup | --verify | --extra
  --with-cutter | --install-inspircd-downgrade | --ghidra | --burpsuite-guide
  --powershell --7zz --unrar --aeskeyfind --xorsearch --jd-gui --baksmali
  --binee --manalyze --bearparser --pycdc --msoffice-crypt --portex --signsrch
  --ilspycmd --flare-floss --evilclippy --android-project-creator --sandfly-processdecloak
EOF
}

if [ "$#" -eq 0 ]; then
    usage
    exit 1
fi

run_all=0
run_partial=0
run_menu=0
ran_something=0

for arg in "$@"; do
    case "$arg" in
        --all) run_all=1 ;;
        --partial) run_partial=1 ;;
        --menu) run_menu=1 ;;
        --base) phase_base; ran_something=1 ;;
        --cleanup) phase_cleanup; ran_something=1 ;;
        --verify) phase_verify; ran_something=1 ;;
        --extra) phase_extra; ran_something=1 ;;
        --with-cutter) install_cutter; ran_something=1 ;;
        --install-inspircd-downgrade) install_inspircd_downgrade; ran_something=1 ;;
        --ghidra) mkdir -p "$WORKDIR"; install_ghidra; ran_something=1 ;;
        --burpsuite-guide) guide_burpsuite; ran_something=1 ;;
        --powershell) mkdir -p "$WORKDIR"; install_powershell; ran_something=1 ;;
        --7zz) mkdir -p "$WORKDIR"; install_7zz; ran_something=1 ;;
        --unrar) mkdir -p "$WORKDIR"; install_unrar; ran_something=1 ;;
        --aeskeyfind) mkdir -p "$WORKDIR"; install_aeskeyfind; ran_something=1 ;;
        --xorsearch) mkdir -p "$WORKDIR"; install_xorsearch; ran_something=1 ;;
        --jd-gui) mkdir -p "$WORKDIR"; install_jd_gui; ran_something=1 ;;
        --baksmali) mkdir -p "$WORKDIR"; install_baksmali; ran_something=1 ;;
        --binee) mkdir -p "$WORKDIR"; install_binee; ran_something=1 ;;
        --manalyze) mkdir -p "$WORKDIR"; install_manalyze; ran_something=1 ;;
        --bearparser) mkdir -p "$WORKDIR"; install_bearparser; ran_something=1 ;;
        --pycdc) mkdir -p "$WORKDIR"; install_pycdc; ran_something=1 ;;
        --msoffice-crypt) mkdir -p "$WORKDIR"; install_msoffice_crypt; ran_something=1 ;;
        --portex) mkdir -p "$WORKDIR"; install_portex; ran_something=1 ;;
        --signsrch) mkdir -p "$WORKDIR"; install_signsrch; ran_something=1 ;;
        --ilspycmd) mkdir -p "$WORKDIR"; install_ilspycmd; ran_something=1 ;;
        --flare-floss) mkdir -p "$WORKDIR"; install_flare_floss; ran_something=1 ;;
        --evilclippy) mkdir -p "$WORKDIR"; install_evilclippy; ran_something=1 ;;
        --android-project-creator) mkdir -p "$WORKDIR"; install_android_project_creator; ran_something=1 ;;
        --sandfly-processdecloak) mkdir -p "$WORKDIR"; install_sandfly_processdecloak; ran_something=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Flag desconocido: $arg"
            usage
            exit 1
            ;;
    esac
done

if [ "$run_all" -eq 1 ]; then
    phase_base
    echo ""
    phase_cleanup
    echo ""
    phase_verify
    echo ""
    phase_extra
    ran_something=1
fi

if [ "$run_partial" -eq 1 ]; then
    echo ""
    phase_partial
    ran_something=1
fi

if [ "$run_menu" -eq 1 ]; then
    echo ""
    phase_menu
    ran_something=1
fi

if [ "$ran_something" -eq 0 ]; then
    usage
    exit 1
fi

exit "$verify_fail"
