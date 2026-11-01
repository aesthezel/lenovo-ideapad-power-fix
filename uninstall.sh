#!/usr/bin/env bash
# ==============================================================================
# Lenovo IdeaPad AMD Linux Power, Suspend (S0i3) & Keyboard Fix - Uninstaller
# ==============================================================================
# Reverts all suspend, ACPI, bootloader, udev, and keyboard changes back to the
# original state backed up in /var/backups/lenovo-ideapad-power-fix.
#
# SECURITY NOTES:
#   * Backups are verified against a root-owned SHA-256 manifest before being
#     installed back into the system. Unverified backups are never restored.
#   * Symlinks and non-regular backup files are rejected.
#   * Legacy backups inside the repository (./backups) are NOT used by default
#     because they live in a user-writable location; use
#     --trust-legacy-backups only after reviewing them manually.
#   * See SECURITY.md for the threat model and residual risks.
# ==============================================================================

set -Eeuo pipefail
umask 077

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SYSTEM_BACKUP_DIR="/var/backups/lenovo-ideapad-power-fix"
LEGACY_BACKUP_DIR="${SCRIPT_DIR}/backups"
BACKUP_DIR="$SYSTEM_BACKUP_DIR"
MANIFEST="${BACKUP_DIR}/manifest.sha256"

TRUST_LEGACY=0
HAD_ERRORS=0

usage() {
  cat <<EOF
Usage: sudo ./uninstall.sh [OPTIONS]

Options:
  --trust-legacy-backups  Use the legacy ./backups directory inside the
                          repository WITHOUT integrity verification.
                          Only use it after reviewing every file manually.
  -h, --help              Show this help message
EOF
}

for arg in "$@"; do
  case "$arg" in
    --trust-legacy-backups) TRUST_LEGACY=1 ;;
    -h|--help)              usage; exit 0 ;;
    *)
      printf 'Unknown option: %q\n' "$arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: Please run this uninstaller as root:" >&2
  printf '  sudo %q' "$0" >&2
  if [ "$#" -gt 0 ]; then
    printf ' %q' "$@" >&2
  fi
  printf '\n' >&2
  exit 1
fi

echo "=== Reverting Lenovo IdeaPad AMD Power, S0i3 Suspend & Keyboard Fixes ==="

if [ "$TRUST_LEGACY" -eq 1 ]; then
  BACKUP_DIR="$LEGACY_BACKUP_DIR"
  MANIFEST=""
  echo "" >&2
  echo "WARNING: --trust-legacy-backups was requested." >&2
  echo "         Using ${BACKUP_DIR} WITHOUT integrity verification." >&2
  echo "         Anyone with write access to this checkout could have modified" >&2
  echo "         those files, and they will be restored as root." >&2
  echo "" >&2
fi

if [ ! -d "$BACKUP_DIR" ]; then
  echo "Warning: no backup directory found at $BACKUP_DIR." >&2
  echo "         Only the parameters added by this tool will be removed." >&2
fi

if [ "$TRUST_LEGACY" -eq 0 ] && [ -d "$LEGACY_BACKUP_DIR" ] &&
   [ -n "$(ls -A -- "$LEGACY_BACKUP_DIR" 2>/dev/null || true)" ]; then
  echo "Warning: legacy backups detected in ${LEGACY_BACKUP_DIR}; NOT used." >&2
  echo "         If they were created by an older version of this tool, review" >&2
  echo "         them first, then re-run with --trust-legacy-backups." >&2
fi

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
verify_backup() {
  local backup="$1"
  local base
  local expected
  local actual

  if [ ! -e "$backup" ] && [ ! -L "$backup" ]; then
    return 1
  fi

  if [ -L "$backup" ] || [ ! -f "$backup" ]; then
    echo "  !! Rejected (not a regular file): $backup" >&2
    return 1
  fi

  if [ "$TRUST_LEGACY" -eq 1 ]; then
    echo "  !! Using legacy backup WITHOUT verification: $backup" >&2
    return 0
  fi

  if [ ! -f "$MANIFEST" ]; then
    echo "  !! Missing manifest ($MANIFEST); refusing to restore $backup" >&2
    return 1
  fi

  base="$(basename -- "$backup")"
  expected="$(awk -v f="$base" '{ if ($2 == f) { print $1; exit } }' "$MANIFEST")"
  actual="$(sha256sum -- "$backup" | awk '{ print $1 }')"

  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "  !! SHA-256 mismatch or missing manifest entry: $backup" >&2
    return 1
  fi

  return 0
}

restore_or_remove() {
  local backup="$1"
  local target="$2"
  local mode="${3:-644}"
  local reference="${4:-}"

  if [ -e "$backup" ] || [ -L "$backup" ]; then
    if verify_backup "$backup"; then
      install -d -m 0755 -- "$(dirname -- "$target")"
      install -m "$mode" -- "$backup" "$target"
      echo "  -> Restored $target"
    else
      echo "  -> NOT restoring $target (backup could not be verified)." >&2
      HAD_ERRORS=1
    fi
  elif [ -n "$reference" ] && [ -e "$target" ] && ! cmp -s -- "$reference" "$target"; then
    echo "  -> Keeping $target (it was not installed by this tool)."
  else
    rm -f -- "$target"
    echo "  -> Removed $target"
  fi
}

# ------------------------------------------------------------------------------
# 1. Restore or remove sleep hook, modprobe config, udev rules & ACPI override
# ------------------------------------------------------------------------------
echo "[1/5] Restoring/removing sleep hook, udev rules, modprobe config, and ACPI override..."

# systemd-sleep hook (restore to the directory present on this system)
if [ -e "${BACKUP_DIR}/99-ideapad-kbd-fn-resume.sh.bak" ] || [ -L "${BACKUP_DIR}/99-ideapad-kbd-fn-resume.sh.bak" ]; then
  if [ -d /usr/lib/systemd/system-sleep ] || [ ! -d /lib/systemd/system-sleep ]; then
    HOOK_TARGET="/usr/lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh"
  else
    HOOK_TARGET="/lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh"
  fi
  restore_or_remove "${BACKUP_DIR}/99-ideapad-kbd-fn-resume.sh.bak" "$HOOK_TARGET" 755
else
  for hook_path in /usr/lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh \
                   /lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh; do
    if [ -f "$hook_path" ] && grep -q "Systemd Sleep Hook for Lenovo IdeaPad AMD Laptops" "$hook_path" 2>/dev/null; then
      rm -f -- "$hook_path"
    elif [ -e "$hook_path" ]; then
      echo "  -> Keeping $hook_path (not recognised as ours)."
    fi
  done
fi

restore_or_remove "${BACKUP_DIR}/ideapad-laptop.conf.bak" /etc/modprobe.d/ideapad-laptop.conf 644 "${SCRIPT_DIR}/ideapad-laptop.conf"
restore_or_remove "${BACKUP_DIR}/99-ideapad-power-save.rules.bak" /etc/udev/rules.d/99-ideapad-power-save.rules 644 "${SCRIPT_DIR}/99-ideapad-power-save.rules"
restore_or_remove "${BACKUP_DIR}/99-ideapad-acpi-override.conf.bak" /etc/dracut.conf.d/99-ideapad-acpi-override.conf 644 "${SCRIPT_DIR}/99-ideapad-acpi-override.conf"

# Early-initrd archive: restore the verified backup, or only remove an archive
# that contains our FixSNTM table.
if [ -e "${BACKUP_DIR}/acpi_override.cpio.bak" ] || [ -L "${BACKUP_DIR}/acpi_override.cpio.bak" ]; then
  restore_or_remove "${BACKUP_DIR}/acpi_override.cpio.bak" /boot/acpi_override.cpio 644
elif [ -f /boot/acpi_override.cpio ] && grep -qa -- "FixSNTM" /boot/acpi_override.cpio 2>/dev/null; then
  rm -f -- /boot/acpi_override.cpio
  echo "  -> Removed /boot/acpi_override.cpio"
elif [ -e /boot/acpi_override.cpio ]; then
  echo "  -> Keeping /boot/acpi_override.cpio (not recognised as ours)."
fi

# ACPI table: restore the verified backup, or only remove a table that is
# recognisably ours (OEM Table ID "FixSNTM").
if [ -e "${BACKUP_DIR}/ssdt11.aml.bak" ] || [ -L "${BACKUP_DIR}/ssdt11.aml.bak" ]; then
  restore_or_remove "${BACKUP_DIR}/ssdt11.aml.bak" /etc/acpi/tables/ssdt11.aml 644
elif [ -f /etc/acpi/tables/ssdt11.aml ] && grep -qa -- "FixSNTM" /etc/acpi/tables/ssdt11.aml; then
  rm -f -- /etc/acpi/tables/ssdt11.aml
  echo "  -> Removed /etc/acpi/tables/ssdt11.aml"
elif [ -e /etc/acpi/tables/ssdt11.aml ]; then
  echo "  -> Keeping /etc/acpi/tables/ssdt11.aml (not recognised as ours)."
fi

# ------------------------------------------------------------------------------
# 2. Restore or remove lenovo-battery.service and thermald.service
# ------------------------------------------------------------------------------
echo "[2/5] Restoring systemd services..."
if [ -f "${BACKUP_DIR}/lenovo-battery.service.bak" ]; then
  if verify_backup "${BACKUP_DIR}/lenovo-battery.service.bak"; then
    install -m 644 -- "${BACKUP_DIR}/lenovo-battery.service.bak" /etc/systemd/system/lenovo-battery.service
    echo "  -> Restored /etc/systemd/system/lenovo-battery.service"
    systemctl daemon-reload || true
    if [ -f "${BACKUP_DIR}/lenovo-battery.was_enabled" ]; then
      systemctl enable --now lenovo-battery.service || true
      rm -f -- "${BACKUP_DIR}/lenovo-battery.was_enabled"
    fi
  else
    echo "  -> NOT restoring lenovo-battery.service (backup could not be verified)." >&2
    HAD_ERRORS=1
  fi
else
  systemctl disable --now lenovo-battery.service 2>/dev/null || true
  rm -f -- /etc/systemd/system/lenovo-battery.service
  rm -f -- "${BACKUP_DIR}/lenovo-battery.was_enabled"
  systemctl daemon-reload || true
  echo "  -> Removed /etc/systemd/system/lenovo-battery.service"
fi

if [ -f "${BACKUP_DIR}/thermald.was_enabled" ]; then
  systemctl enable --now thermald.service 2>/dev/null || true
  rm -f -- "${BACKUP_DIR}/thermald.was_enabled"
fi

# ------------------------------------------------------------------------------
# 3. Restore bootloader configuration and kernel parameters
# ------------------------------------------------------------------------------
echo "[3/5] Restoring bootloader configuration and kernel parameters..."
RESTORE_PPFEATUREMASK=0
GRUB_RESTORED=0

if [ -f "${BACKUP_DIR}/grub.bak" ]; then
  if verify_backup "${BACKUP_DIR}/grub.bak"; then
    if grep -q -- "amdgpu.ppfeaturemask=0xffffbfff" "${BACKUP_DIR}/grub.bak"; then
      RESTORE_PPFEATUREMASK=1
    fi
    install -m 644 -- "${BACKUP_DIR}/grub.bak" /etc/default/grub
    GRUB_RESTORED=1
    echo "  -> Restored /etc/default/grub"
  else
    echo "  -> /etc/default/grub backup could not be verified; only the added parameters will be removed." >&2
    HAD_ERRORS=1
  fi
fi

if [ "$GRUB_RESTORED" -eq 0 ] && [ -f /etc/default/grub ] && command -v python3 >/dev/null 2>&1; then
  python3 - /etc/default/grub <<'PYEOF'
import os
import re
import stat
import sys
import tempfile

grub_path = sys.argv[1]
with open(grub_path, "r", encoding="utf-8") as f:
    content = f.read()

def write_atomic(target, text):
    directory = os.path.dirname(os.path.abspath(target))
    mode = stat.S_IMODE(os.stat(target).st_mode)
    fd, tmp = tempfile.mkstemp(prefix=".grub-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

remove_args = {"i8042.nomux=1", "i8042.reset=1", "atkbd.reset=1"}

def clean_cmdline(match):
    key, quote, val = match.group(1), match.group(2), match.group(3)
    tokens = [t for t in val.split() if t not in remove_args]
    return f'{key}={quote}{" ".join(tokens)}{quote}'

content = re.sub(
    r'^(GRUB_CMDLINE_LINUX(?:_DEFAULT)?)=([\'"])(.*?)\2',
    clean_cmdline,
    content,
    flags=re.M,
)

m = re.search(r'^GRUB_EARLY_INITRD_LINUX_CUSTOM=(?:"([^"]*)"|\'([^\']*)\'|(\S*))', content, flags=re.M)
if m:
    value = next(g for g in m.groups() if g is not None)
    tokens = [t for t in value.split() if t != "acpi_override.cpio"]
    if tokens:
        replacement = 'GRUB_EARLY_INITRD_LINUX_CUSTOM="' + " ".join(tokens) + '"'
        content = content[:m.start()] + replacement + content[m.end():]
    else:
        line_end = content.find("\n", m.end())
        if line_end == -1:
            content = content[:m.start()].rstrip("\n") + "\n"
        else:
            content = content[:m.start()] + content[line_end + 1:]

write_atomic(grub_path, content)
PYEOF
fi

CMDLINE_RESTORED=0
if [ -f "${BACKUP_DIR}/cmdline.bak" ]; then
  if verify_backup "${BACKUP_DIR}/cmdline.bak"; then
    if grep -q -- "amdgpu.ppfeaturemask=0xffffbfff" "${BACKUP_DIR}/cmdline.bak"; then
      RESTORE_PPFEATUREMASK=1
    fi
    install -m 644 -- "${BACKUP_DIR}/cmdline.bak" /etc/kernel/cmdline
    CMDLINE_RESTORED=1
    echo "  -> Restored /etc/kernel/cmdline"
  else
    echo "  -> /etc/kernel/cmdline backup could not be verified; only the added parameters will be removed." >&2
    HAD_ERRORS=1
  fi
fi

if [ "$CMDLINE_RESTORED" -eq 0 ] && [ -f /etc/kernel/cmdline ] && command -v python3 >/dev/null 2>&1; then
  python3 - /etc/kernel/cmdline <<'PYEOF'
import os
import stat
import sys
import tempfile

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

def write_atomic(target, text):
    directory = os.path.dirname(os.path.abspath(target))
    mode = stat.S_IMODE(os.stat(target).st_mode)
    fd, tmp = tempfile.mkstemp(prefix=".cmdline-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

remove_args = {"i8042.nomux=1", "i8042.reset=1", "atkbd.reset=1"}
tokens = [t for t in content.split() if t not in remove_args]

write_atomic(path, " ".join(tokens) + "\n")
PYEOF
fi

if command -v grubby >/dev/null 2>&1; then
  if [ "$RESTORE_PPFEATUREMASK" -eq 1 ]; then
    if ! grubby --update-kernel=ALL \
      --remove-args="i8042.nomux=1 i8042.reset=1 atkbd.reset=1" \
      --args="amdgpu.ppfeaturemask=0xffffbfff"; then
      echo "  -> Warning: grubby could not update BLS entries; GRUB configuration will still be regenerated."
    fi
  else
    if ! grubby --update-kernel=ALL \
      --remove-args="i8042.nomux=1 i8042.reset=1 atkbd.reset=1"; then
      echo "  -> Warning: grubby could not update BLS entries; GRUB configuration will still be regenerated."
    fi
  fi
fi

if command -v kernelstub >/dev/null 2>&1; then
  kernelstub -d "i8042.nomux=1" >/dev/null 2>&1 || true
  kernelstub -d "i8042.reset=1" >/dev/null 2>&1 || true
  kernelstub -d "atkbd.reset=1" >/dev/null 2>&1 || true
fi

if command -v update-grub >/dev/null 2>&1; then
  update-grub
elif command -v grub2-mkconfig >/dev/null 2>&1; then
  if [ -f /boot/grub2/grub.cfg ]; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
  elif [ -f /boot/efi/EFI/fedora/grub.cfg ]; then
    grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
  fi
elif command -v grub-mkconfig >/dev/null 2>&1 && [ -f /boot/grub/grub.cfg ]; then
  grub-mkconfig -o /boot/grub/grub.cfg
fi

# ------------------------------------------------------------------------------
# 4. Reload udev rules and ideapad_laptop module
# ------------------------------------------------------------------------------
echo "[4/5] Reloading udev rules and ideapad_laptop module..."
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=pci --subsystem-match=usb || true
else
  echo "  -> Warning: udevadm not found; rules will be applied on next boot." >&2
fi
modprobe -r ideapad_laptop 2>/dev/null || true
modprobe ideapad_laptop 2>/dev/null || true

# ------------------------------------------------------------------------------
# 5. Rebuild initramfs without the ACPI override
# ------------------------------------------------------------------------------
echo "[5/5] Rebuilding initramfs..."
if command -v dracut >/dev/null 2>&1; then
  dracut -f
elif command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u
elif command -v mkinitcpio >/dev/null 2>&1; then
  mkinitcpio -P
fi

if [ "$HAD_ERRORS" -ne 0 ]; then
  echo "=== Uninstallation completed with warnings: some files were not restored (see above). ===" >&2
  exit 1
fi

echo "=== Uninstallation complete! Please reboot your laptop to apply boot changes. ==="
