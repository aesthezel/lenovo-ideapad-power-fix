# Security Policy

This repository modifies privileged system state: ACPI tables, kernel command-line
parameters, initramfs contents, udev rules, modprobe configuration, a systemd unit,
and a root-run suspend/resume hook. Treat it as a privileged installer, not as a
regular userspace utility.

## Supported versions

Only the current `main` branch is supported. There are no security backports for
older commits or forks. This is an unofficial community project provided under the
MIT License **without warranty** (see [`LICENSE`](./LICENSE)).

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Use GitHub's private vulnerability reporting:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Include: affected commit, distribution/kernel/firmware, reproduction steps,
   impact, and whether the issue requires local access or only a malicious
   repository/artifact.

You will get an acknowledgement as soon as possible. Please allow time for a fix
and a coordinated disclosure before publishing details.

## Threat model

**In scope — realistic attack paths**

- An unprivileged local user who can write to the checkout or to a directory the
  installer trusts, and then influences a root `install.sh`/`uninstall.sh` run
  (shared machines, NFS homes, `/tmp`, CI workspaces, compromised tarballs).
- Supply-chain tampering with the shipped ACPI binary, the scripts, or the CI
  workflows (forked repository, moved tag, altered release archive).
- Offline tampering with `/boot` (the early-initrd ACPI override is loaded by the
  kernel without signature verification).
- Unsafe defaults that silently apply privileged changes on unsupported systems
  (VMs, containers, Intel platforms) or that can leave a machine unbootable.

**Out of scope**

- An attacker who already has root, physical access to an unlocked session, or
  control of the running kernel/firmware.
- Attacks that require disabling Secure Boot, or that rely on a compromised
  distribution, bootloader, or kernel package.
- Hardware/firmware bugs in Lenovo's ACPI tables themselves; this project can only
  work around the specific `SNTM` reference.

## Security controls implemented

| Control | Implementation |
| :-- | :-- |
| Backups are root-only and outside the repository | `/var/backups/lenovo-ideapad-power-fix`, mode `0700`, `umask 077` (`install.sh`) |
| Restored files are integrity-checked | `manifest.sha256` written by the installer and verified before any restore (`uninstall.sh`) |
| Backups are never followed through symlinks | `-L`/`-f` checks before copy and before restore |
| Legacy in-repo backups are untrusted by default | `./backups` is ignored unless `--trust-legacy-backups` is passed explicitly |
| Source tree trust check | The installer refuses a checkout writable by group/others (`-perm /022`) |
| Fixed, privileged `PATH` | `PATH=/usr/sbin:/usr/bin:/sbin:/bin` in every root-run script |
| Fail-closed hardware/integrity checks | Unknown vendor/CPU or a failed `SNTM` scan skips ACPI instead of proceeding |
| ACPI table verification | `verify-aml.sh`: SSDT signature, declared `Length`, ACPI checksum, OEM Table ID, optional pinned SHA-256 |
| ACPI table rebuild from source | When `iasl` (acpica-tools) is present, the table is recompiled from the audited `ssdt11_patched.dsl` and used instead of the binary |
| Atomic boot configuration edits | `mkstemp` + `fsync` + `os.replace`, preserving file mode (`install.sh`, `uninstall.sh`) |
| Partial-install rollback | `ERR` trap restores the original `/etc/default/grub` and `/etc/kernel/cmdline` |
| Root run hook hardening | Fixed `PATH`, `umask 077`, symlink rejection, FnLock value validated (`0`/`1`) before writing |
| Service hardening | Absolute `/bin/bash`, `UMask=0077`, `NoNewPrivileges=yes` |
| CI supply chain | `actions/checkout` pinned by commit SHA, `persist-credentials: false`, `contents: read`, no third-party ShellCheck action |
| ACPI reproducibility | Dedicated CI job rebuilds the table with `iasl` on every push/PR |

## Verifying a checkout or release

Before running the installer, verify the exact code you are executing:

```sh
# 1. Review provenance (signed tags/commits, if the maintainer signed them)
git log --show-signature -5
git remote -v

# 2. Validate the ACPI table (header/checksum, plus iasl if installed)
bash ./verify-aml.sh

# 3. Check that no repository file is writable by other users
find . -maxdepth 1 -perm /022 -print
```

Optional cryptographic pinning of the shipped AML (after you have reviewed it):

```sh
sha256sum ssdt11_patched.aml > ssdt11_patched.aml.sha256
git add ssdt11_patched.aml.sha256
```

Once that file exists, `verify-aml.sh` fails on any byte change to the AML. The
strongest option remains installing `acpica-tools`, which makes the installer
rebuild the table from `ssdt11_patched.dsl` on every run.

## Residual risks and accepted limitations

1. **Custom ACPI tables are unauthenticated.** The Linux kernel does not verify
   signatures for ACPI tables, and the override is delivered through the
   initramfs/early initrd. This is an intentional workaround for a firmware bug,
   but it weakens measured-boot assumptions. Keep `/boot` protected (encryption
   or at least restricted physical access) and prefer `--skip-acpi` when your
   firmware does not expose the broken `SNTM` reference.
2. **Secure Boot is not a boundary here.** The project never asks you to disable
   Secure Boot, but an ACPI override placed *outside* a signed UKI may not load.
   Do not disable Secure Boot as a workaround; use `--skip-acpi` instead.
3. **No default SHA-256 pin for the AML.** The installer validates structure and
   rebuilds from source when `iasl` is available, but the repository does not
   ship a pinned hash by default. Generate and commit
   `ssdt11_patched.aml.sha256` as shown above to enable byte-level pinning.
4. **The installer still executes code from the checkout.** Running
   `sudo ./install.sh` from a tree you do not control is equivalent to running
   arbitrary code as root. The trust check only blocks group/other-writable
   trees; it cannot detect a malicious owner. Never run it from `/tmp`, a shared
   directory, or an unverified fork/tarball.
5. **Legacy backups are untrusted.** `./backups` from older versions lives in a
   user-writable location. It is ignored unless you opt in with
   `--trust-legacy-backups`, which restores it as root without verification.
6. **`check-status.sh` output can contain identifiers.** `/proc/cmdline` may
   include LUKS/root UUIDs, `cryptdevice=` paths, or network parameters. Redact
   before pasting into issues or chat.
7. **Direct PCI config-space writes in the sleep hook.** The `pre` hook puts an
   unbound AMD ACP device (`1022:15e2`) into `D3hot` by writing PCI config space.
   This intentionally bypasses kernel runtime PM. It runs as root, touches only
   fixed sysfs paths, and is documented here as a hardware-behaviour tradeoff.
8. **Availability, not confidentiality.** Interrupted GRUB/initramfs regeneration
   can still leave a machine unable to boot if the process is killed at the wrong
   moment; edits are now atomic and an `ERR` trap restores boot configuration,
   but no tool can guarantee rollback across `update-grub`/`dracut` failures.

## Security audit (2026-11-01)

An internal review of all scripts and configuration files found **no malicious
code** (no network access, `eval`, obfuscated payloads, hardcoded secrets, or
setuid helpers). The findings and their status:

| ID | Severity | Finding | Status |
| :-- | :-- | :-- | :-- |
| H-01 | High (conditional) | User-writable `./backups` restored as root → local privilege escalation / persistence | Fixed: root-only backup directory + SHA-256 manifest + symlink rejection; legacy backups opt-in only |
| H-02 | High | ACPI AML installed without integrity verification or correspondence to the DSL | Fixed: `verify-aml.sh` (header/checksum/optional hash) and rebuild from `.dsl` via `iasl`; CI job added |
| H-03 | Medium | Fail-open hardware checks and `SNTM` detection | Fixed: unknown vendor/CPU or detection failure skips ACPI |
| H-04 | Medium | Unfixed `PATH` for root-run commands | Fixed in all root-run scripts and the systemd unit |
| H-05 | Medium | Non-atomic edits of GRUB/cmdline and no rollback | Fixed: atomic replace + `ERR` trap |
| H-06 | Low–Medium | Machine-specific backups stored inside the repository | Fixed: backups moved to `/var/backups/...`; legacy path ignored |
| H-07 | Low–Medium | CI actions referenced by mutable tags, credentials persisted | Fixed: SHA-pinned checkout, no third-party action, `persist-credentials: false` |
| H-08 | Low | Direct PCI config-space writes and unvalidated state file | Mitigated: fixed `PATH`, symlink rejection, validated `0`/`1`; behaviour documented above |
| — | Low | ANSI/argument injection in error output, unset `umask`, blind file removal | Fixed: `printf %q`, `umask 077`, ownership/reference checks |

The ACPI binary could not be cryptographically verified in the audit environment
(no shell access was available); this is why runtime verification and the
reproducible CI rebuild were added. A maintainer should still generate and commit
`ssdt11_patched.aml.sha256` after an independent `iasl -d` review.

## Hardening checklist for users

- [ ] Clone the repository into a private directory (for example `~/src/...`),
      never `/tmp` or a shared path.
- [ ] Review `install.sh` and `uninstall.sh`; run `bash ./verify-aml.sh`.
- [ ] Install `acpica-tools` so the ACPI table is rebuilt from the ASL source.
- [ ] Pin `ssdt11_patched.aml.sha256` if you want byte-level integrity checking.
- [ ] Keep `/boot` protected; do not disable Secure Boot for this fix.
- [ ] Redact identifiers before sharing `check-status.sh` output.
- [ ] Keep `/var/backups/lenovo-ideapad-power-fix` at mode `0700`, owned by root.
- [ ] After uninstalling, purge the backup directory if you no longer need it.

## Hardening checklist for maintainers

- [ ] Keep `actions/checkout` and any other action pinned to a full commit SHA.
- [ ] Keep the `acpi-integrity` CI job green; it rebuilds the table from the DSL.
- [ ] Generate and commit `ssdt11_patched.aml.sha256` after each intentional AML change.
- [ ] Sign release tags (`git tag -s`) and publish checksums for release archives.
- [ ] Enable branch protection and secret scanning; require review for workflow changes.
- [ ] Never accept a PR that adds network access, `eval`, or privileged writes
      that are not covered by `SECURITY.md` and the trust checks.
