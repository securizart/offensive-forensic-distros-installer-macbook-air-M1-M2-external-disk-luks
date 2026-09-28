#!/bin/bash
# steps/09_package_installation.sh
# Installs the chosen operating system's ($TARGET_OS) metapackages.
STEP_ID="09"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/bootstrap.sh
source "${BASE_DIR}/lib/bootstrap.sh"
step_bootstrap "$STEP_ID"

# Idempotent, run every time step 09 starts — including on a retry
# after a previous failed attempt, when i386 may already be registered
# and the repos already broken (see ensure_apt_repos_sane in
# lib/common.sh for the full story: WineHQ registers i386, and
# ports.ubuntu.com never serves it, breaking every apt call system-wide
# until fixed).
ensure_apt_repos_sane

TARGET_OS="$(state_get ACTIVE_OS)"
if [ -z "$TARGET_OS" ]; then
    log_error "Could not determine the active OS (ACTIVE_OS is empty in this system's state)."
    exit 1
fi

verify_booted_from_target_disk

echo "$(t step09_title "$(t "os_${TARGET_OS}_name")")"
echo "$(t step09_intro "$(t "os_${TARGET_OS}_name")")"
echo

# Idempotent, and re-installed here too (not just in step 08): if this
# step is retried on its own after a previous failure, policy-rc.d must
# already be in place before ANY apt/dpkg call runs — see the note on
# its installation in step 08 for the full story (a broken package
# postinst trying to start a nonexistent systemd unit aborting the
# whole metapackage transaction).
if [ ! -f /usr/sbin/policy-rc.d ]; then
    cat > /usr/sbin/policy-rc.d <<'POLICY_EOF'
#!/bin/sh
exit 101
POLICY_EOF
    chmod +x /usr/sbin/policy-rc.d
    log_info "Installed /usr/sbin/policy-rc.d (denies service start/stop during package installs) — removed at the end of this step."
fi

# --- WiFi interface: re-detect + pin to a stable name ----------------------
# Step 08 ends with a reboot, and this adapter's kernel-assigned name has
# been observed to CHANGE between boots on this hardware even without any
# OS change (wld0 one boot, wlp1s0f0 the next, for the SAME physical MAC) —
# so whatever step 08 detected can already be stale by the time this step
# runs. Re-detect fresh, drop any interfaces.d stanza left over from a
# different name, and pin this adapter's MAC to a fixed name via udev so
# future boots stop drifting. No-op on sift/remnux: they never carry a
# wpa_supplicant.conf to begin with.
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
if [ -f "$WPA_CONF" ]; then
    WIFI_IFACE=""
    for ifc in /sys/class/net/*; do
        if [ -d "${ifc}/wireless" ]; then
            WIFI_IFACE="$(basename "$ifc")"
            break
        fi
    done
    if [ -n "$WIFI_IFACE" ]; then
        WIFI_MAC="$(cat "/sys/class/net/${WIFI_IFACE}/address" 2>/dev/null || true)"
        IFACES_D="/etc/network/interfaces.d"
        mkdir -p "$IFACES_D"

        # Drop any other interfaces.d file that points at this same
        # wpa_supplicant.conf but under a DIFFERENT interface name — a
        # leftover from a previous boot's naming, now orphaned.
        for f in "$IFACES_D"/*; do
            [ -f "$f" ] || continue
            [ "$(basename "$f")" = "$WIFI_IFACE" ] && continue
            if grep -qi "wpa-conf ${WPA_CONF}" "$f" 2>/dev/null; then
                rm -f "$f"
            fi
        done

        {
            echo "auto ${WIFI_IFACE}"
            echo "iface ${WIFI_IFACE} inet dhcp"
            echo "    wpa-conf ${WPA_CONF}"
        } > "${IFACES_D}/${WIFI_IFACE}"

        IFACES_MAIN="/etc/network/interfaces"
        if [ -f "$IFACES_MAIN" ] && ! grep -q "^source ${IFACES_D}/\*" "$IFACES_MAIN"; then
            echo "source ${IFACES_D}/*" >> "$IFACES_MAIN"
        fi

        ifup "$WIFI_IFACE" 2>/dev/null || true
        log_info "$(t step09_iface_redetected "$WIFI_IFACE")"
        echo "$(t step09_iface_redetected "$WIFI_IFACE")"

        # Pin this MAC to a fixed name (wlan0) so it stops drifting on
        # future boots. Takes effect from the NEXT boot onward — we don't
        # attempt a live rename here, that's riskier mid-setup than it's
        # worth.
        if [ -n "$WIFI_MAC" ] && [ "$WIFI_IFACE" != "wlan0" ]; then
            mkdir -p /etc/udev/rules.d
            echo "SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"${WIFI_MAC}\", NAME=\"wlan0\"" \
                > /etc/udev/rules.d/70-persistent-wifi.rules
            log_info "$(t step09_iface_pinned "$WIFI_MAC")"
            echo "$(t step09_iface_pinned "$WIFI_MAC")"
        fi
    fi
fi

case "$TARGET_OS" in
    kali)
        echo "$(t step09_installing "kali-linux-default, kali-desktop-gnome, kali-linux-large")"
        run_cmd "kali-linux-default" apt-get install -y kali-linux-default -t kali-rolling
        run_cmd "kali-desktop-gnome" apt-get install -y kali-desktop-gnome -t kali-rolling
        run_cmd "kali-linux-large" apt-get install -y kali-linux-large -t kali-rolling
        # kali-linux-arm intentionally NOT installed: it's Kali's
        # metapackage for their ARM SBC images (Raspberry Pi, Rockchip,
        # Allwinner boards) — it depends on SBC-specific
        # firmware/tools (rkflashtool, sunxi-tools, dphys-swapfile,
        # firmware-realtek, etc.) that don't apply to — and in several
        # cases aren't even installable on — a MacBook Air M1/M2.
        ;;
    parrot)
        # NOTE (v1.3.0): parrot-core and parrot-tools-full alone never
        # pull in a desktop environment — Parrot ships that separately
        # as "parrot-interface" (which depends on one of
        # parrot-desktop-kde/-mate/-xfce/... as apt alternatives).
        # Confirmed with Parrot's own release notes: since Parrot OS 7.0
        # "echo" the default DE is KDE Plasma 6 (it was MATE up to
        # 6.x), so pin that alternative explicitly instead of leaving it
        # to apt's dependency resolution. Also "lts" -> "echo", see
        # steps/08_repositories.sh for the matching sources.list/pin
        # change and the reasoning.
        echo "$(t step09_installing "parrot-core, parrot-desktop-kde, parrot-interface, parrot-tools-full")"
        run_cmd "parrot-core" apt-get install -y parrot-core -t echo
        run_cmd "parrot-desktop-kde" apt-get install -y parrot-desktop-kde -t echo
        run_cmd "parrot-interface" apt-get install -y parrot-interface -t echo
        run_cmd "parrot-tools-full" apt-get install -y parrot-tools-full -t echo
        ;;
    sift)
        # Clone with SIFT Workstation (SANS) baked in: official arm64
        # support confirmed on Ubuntu 22.04/24.04 by the project itself
        # (teamdfir/sift-saltstack), with a known caveat: some packages
        # are amd64-only and are automatically skipped on arm64.
        # Choosing this target already IS the decision to have SIFT
        # here — no separate confirmation prompt (see
        # docs/OPERATING_SYSTEMS.md for the two-independent-targets
        # model).
        if dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii'; then
            log_info "ubuntu-desktop is already installed, skipping."
            echo "$(t step09_ubuntu_desktop_already)"
        else
            echo "$(t step09_installing "ubuntu-desktop")"
            run_cmd "apt update" apt update
            run_cmd "ubuntu-desktop" apt-get install -y ubuntu-desktop
        fi

        echo "$(t step09_ubuntu_sift_notice)"
        install_cast_arm64 || {
            log_error "Could not install 'cast'. Skipping SIFT installation."
            echo "$(t step09_ubuntu_cast_install_failed)"
        }
        if command -v cast >/dev/null 2>&1; then
            # SIFT's own SaltStack states (teamdfir/sift-saltstack) add
            # several apt repositories (gift, sift, openjdk, dotnet,
            # Microsoft) as part of provisioning. On real hardware this
            # ended up upgrading unrelated packages (mesa, gnome-shell)
            # to versions expecting a newer kernel than the one left in
            # place by step 08, breaking the graphical session on
            # reboot — the same class of mismatch documented in
            # docs/TROUBLESHOOTING.md, but triggered from inside SIFT's
            # own provisioning this time, not from a command we run
            # ourselves. Hold just the kernel/GPU-userspace family
            # around it (not everything installed — that blocked
            # SIFT's own dependency resolution on real hardware).
            echo "$(t step09_holding_packages)"
            HELD_PKGS="$(hold_graphics_kernel_packages)"
            echo "$(t step09_ubuntu_installing_sift)"
            # A handful of failed salt states here is expected on arm64
            # (SIFT's own docs mention amd64-only packages get skipped)
            # and cast/salt-call exits non-zero even for a handful of
            # failures out of hundreds of states. Checked in an `if`
            # here so that non-zero doesn't fire the script's global
            # ERR trap and abort the step outright — which previously
            # skipped unhold_packages below, leaving the kernel/GPU
            # hold in place indefinitely even though the bulk of the
            # install had actually succeeded.
            if run_cmd "cast install sift" cast install teamdfir/sift-saltstack; then
                echo "$(t step09_ubuntu_sift_done)"
            else
                log_warn "cast install reported some failed states (see the log above for exactly which). This can happen with SIFT's own arm64 package list without making the install unusable — check the failed package name(s) if something you need seems to be missing."
                echo "$(t step09_ubuntu_sift_partial)"
            fi
            unhold_packages "$HELD_PKGS"
            echo "$(t step09_unholding_packages)"
        fi
        ;;

    remnux)
        # Clone with REMnux baked in: vendored from the forensics
        # satellite project (forensics/remnux/), still flagged there as
        # "in doubt" for full arm64 support (~88% of remnux.addon
        # states succeed; a handful of known-broken binaries get
        # cleaned up and, where possible, replaced with native
        # alternatives). Same "target IS the choice" reasoning as sift
        # above — no confirmation prompt.
        if dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii'; then
            log_info "ubuntu-desktop is already installed, skipping."
            echo "$(t step09_ubuntu_desktop_already)"
        else
            echo "$(t step09_installing "ubuntu-desktop")"
            run_cmd "apt update" apt update
            run_cmd "ubuntu-desktop" apt-get install -y ubuntu-desktop
        fi

        echo "$(t step09_ubuntu_remnux_notice)"

        # REMnux's own upstream convention ships a "remnux"/"malware"
        # demo account; this vendored flow doesn't create one on its
        # own (see forensics/remnux/install.sh), so we do it here.
        echo "$(t step09_ubuntu_remnux_user_notice)"
        if id remnux >/dev/null 2>&1; then
            log_warn "User 'remnux' already exists, skipping creation."
        else
            run_cmd "useradd remnux" useradd -m -c 'REMnux (SANS demo account)' -s /bin/bash -G sudo remnux
        fi
        run_cmd "set remnux password" bash -c "echo 'remnux:malware' | chpasswd"
        log_warn "'remnux' account set with the public demo password 'malware' (see README.md's Risks section)."
        echo "$(t step09_ubuntu_remnux_user_warning)"

        # remnux-installer.sh assumes it runs AS the remnux user (uses
        # $HOME for salt-states/rustup/dotnet tools, and critically for
        # the --menu phase's .desktop launchers). Being in the 'sudo'
        # group above isn't enough on its own: sudo still asks for a
        # password interactively, which install_remnux_arm64 runs with
        # no TTY to answer. Grant passwordless sudo here, scoped to
        # this one account.
        echo 'remnux ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/remnux-nopasswd
        chmod 440 /etc/sudoers.d/remnux-nopasswd

        # forensics/remnux/install.sh orchestrates its own SaltStack run
        # (remnux.addon), which — like SIFT's states above — can add
        # repositories and pull in package upgrades as a side effect.
        # Same guard, same reasoning: see docs/TROUBLESHOOTING.md.
        echo "$(t step09_holding_packages)"
        HELD_PKGS="$(hold_graphics_kernel_packages)"
        install_remnux_arm64 || echo "$(t step09_ubuntu_remnux_failed)"
        unhold_packages "$HELD_PKGS"
        echo "$(t step09_unholding_packages)"
        echo "$(t step09_ubuntu_remnux_done)"
        ;;

    *)
        log_error "Unknown operating system: $TARGET_OS"
        exit 1
        ;;
esac

# Remove the policy-rc.d installed in step 08: package installs for
# this OS are done, so future manual apt/service operations (the user's
# own, after this install finishes) should behave normally again,
# actually starting/stopping services as usual.
if [ -f /usr/sbin/policy-rc.d ]; then
    rm -f /usr/sbin/policy-rc.d
    log_info "Removed /usr/sbin/policy-rc.d (package installs for this OS are done)."
fi

mark_os_step_done "$TARGET_OS" "$STEP_ID"
echo
echo "$(t step09_all_done "$(t "os_${TARGET_OS}_name")")"
echo "$(t step09_done_reboot)"
echo "$(t generic_rebooting)"
sleep 5
reboot
