# Repository GPG key errors for Kali and Parrot (NO_PUBKEY / not signed)

**Labels:** bug, repositories, fixed
**Affects:** step 08 (repositories), Kali and Parrot targets
**Status:** Fixed in v2.0.1

## Symptoms
`step 08` fails while adding the distro repository:

```
E: Could not get lock ...            (red herring, see issue note)
GPG error: ... InRelease: NO_PUBKEY <id>
E: The repository '...' is not signed.
gpg: no valid OpenPGP data found
```

## Root cause
Third-party repos rotate their signing keys every few years:

- **Kali** rotated its key (old `ED444FF07D8D0BF6` -> new
  `ED65462EC8D5E4C5`). The installer fetched `archive-key.asc` and ran
  `gpg --dearmor`; when the key changes or that URL moves, dearmor gets no
  valid data -> empty keyring -> `NO_PUBKEY`.
- **Parrot** serves `parrotsec.gpg`, which may be **armored or already
  binary**; `gpg --dearmor` on an already-binary key fails the same way.

## Fix (v2.0.1)
- **Kali:** download the official **binary** keyring
  `https://archive.kali.org/archive-keyring.gpg` directly (it contains both
  old and new keys), with `curl` fallback, then validate it.
- **Parrot:** download the key, **detect armored vs binary** (`BEGIN PGP`)
  and handle both, with fallback and validation.

If the keyring ends up missing/invalid, the step now logs a clear error with
the manual command instead of failing silently.

## Manual fix (for a stuck install)
```
# Kali
sudo wget -q -O /etc/apt/keyrings/kali-archive.gpg https://archive.kali.org/archive-keyring.gpg
# Parrot
sudo bash -c 'wget -q -O /tmp/p.key https://deb.parrot.sh/parrot/misc/parrotsec.gpg
  grep -qa "BEGIN PGP" /tmp/p.key && gpg --dearmor < /tmp/p.key > /etc/apt/keyrings/parrot.gpg || cp /tmp/p.key /etc/apt/keyrings/parrot.gpg'
sudo apt update
```
