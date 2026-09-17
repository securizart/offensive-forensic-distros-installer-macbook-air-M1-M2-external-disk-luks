# forensics/

This directory holds scripts **vendored as-is** from the
[`forensic-distros-silicon-external-disk`](https://github.com/securizart/forensic-distros-silicon-external-disk)
satellite project, which owns their actual logic, testing and
validation on a real VM. This installer only orchestrates them (see
`install_remnux_arm64` in `lib/common.sh`, called from
`steps/09_package_installation.sh`'s `ubuntu)` branch) — it does not
duplicate or reimplement their behavior.

## Current status

- `remnux/`: vendored from the forensics project, still flagged there as
  **"in doubt"** for full arm64 coverage (see `remnux/FINDINGS.md` in
  this same folder): a full `remnux.addon` run succeeds on ~88% of
  states, with a documented set of known-broken binaries that
  `cleanup.sh` removes and `verify.sh` partially replaces with native
  arm64 alternatives. Offered as an **optional** step, same pattern as
  SIFT.

## Demo account created for this install

`steps/09_package_installation.sh` creates a `remnux` user (in the
`sudo` group) with the password `malware` right before calling
`install_remnux_arm64` (`lib/common.sh`), which in turn runs
`install.sh` above — matching REMnux's own official upstream convention
for training/demo VMs, not something invented by this installer. The
vendored `install.sh`/`cleanup.sh`/`verify.sh` scripts themselves don't
create this account, so step 09 does it directly, only when REMnux is
actually confirmed for install.

**This repository is public.** `malware` is a well-known, publicly
documented default — change it before exposing the resulting system to
any network you don't fully control.

## Updating these scripts

When a new version is approved on the forensics project, copy its
`remnux/install.sh`, `cleanup.sh`, `verify.sh` and `exclude-list.txt`
here, replacing these files, and update `CHANGELOG.md` noting the
version pulled in. No changes should be needed on the orchestration side
(`lib/common.sh`) unless the forensics scripts' interface changes (flags,
expected environment variables, or output contract with `verify.sh`'s
exit code).
