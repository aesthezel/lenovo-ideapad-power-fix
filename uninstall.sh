#!/usr/bin/env bash
# ==============================================================================
# Lenovo IdeaPad AMD Linux Power, Suspend (S0i3) & Keyboard Fix - Uninstaller
# ==============================================================================
# Reverts all suspend, ACPI, bootloader, udev, and keyboard changes back to the
# original state backed up in ./backups/ (or clean system defaults).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: Please run this uninstaller as root:" >&2
  echo "  sudo $0" >&2
  exit 1
fi

echo "=== Reverting Lenovo IdeaPad AMD Power, S0i3 Suspend & Keyboard Fixes ==="

# ------------------------------------------------------------------------------
# 1. Restore or remove sleep hook, modprobe config, udev rules & ACPI override
# ------------------------------------------------------------------------------
echo "[1/5] Restoring/removing sleep hook, udev rules, modprobe config, and ACPI override..."

restore_or_remove() {
  local backup="$1" target="$2" mode="${3:-644}"
  if [ -f "$backup" ]; then
    mkdir -p "$(dirname "$target")"
    install -m "$mode" "$backup" "$target"
    echo "  -> Restored $target"
  else
    rm -f "$target"
  fi
}

# systemd-sleep hook (restore to the directory present on this system)
if [ -f "${BACKUP_DIR}/99-ideapad-kbd-fn-resume.sh.bak" ]; then
  if [ -d /usr/lib/systemd/system-sleep ] || [ ! -d /lib/systemd/system-sleep ]; then
    HOOK_TARGET="/usr/lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh"
  else
    HOOK_TARGET="/lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh"
  fi
  restore_or_remove "${BACKUP_DIR}/99-ideapad-kbd-fn-resume.sh.bak" "$HOOK_TARGET" 755
else
  rm -f /usr/lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh
  rm -f /lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh
fi

restore_or_remove "${BACKUP_DIR}/ideapad-laptop.conf.bak" /etc/modprobe.d/ideapad-laptop.conf
restore_or_remove "${BACKUP_DIR}/99-ideapad-power-save.rules.bak" /etc/udev/rules.d/99-ideapad-power-save.rules
restore_or_remove "${BACKUP_DIR}/99-ideapad-acpi-override.conf.bak" /etc/dracut.conf.d/99-ideapad-acpi-override.conf
restore_or_remove "${BACKUP_DIR}/ssdt11.aml.bak" /etc/acpi/tables/ssdt11.aml
restore_or_remove "${BACKUP_DIR}/acpi_override.cpio.bak" /boot/acpi_override.cpio

# ------------------------------------------------------------------------------
# 2. Restore or remove lenovo-battery.service and thermald.service
# ------------------------------------------------------------------------------
echo "[2/5] Restoring systemd services..."
if [ -f "${BACKUP_DIR}/lenovo-battery.service.bak" ]; then
  install -m 644 "${BACKUP_DIR}/lenovo-battery.service.bak" /etc/systemd/system/lenovo-battery.service
  systemctl daemon-reload
  systemctl enable --now lenovo-battery.service || true
else
  systemctl disable --now lenovo-battery.service 2>/dev/null || true
  rm -f /etc/systemd/system/lenovo-battery.service
  systemctl daemon-reload
fi

if [ -f "${BACKUP_DIR}/thermald.was_enabled" ]; then
  systemctl enable --now thermald.service 2>/dev/null || true
  rm -f "${BACKUP_DIR}/thermald.was_enabled"
fi

# ------------------------------------------------------------------------------
# 3. Restore bootloader configuration and kernel parameters
# ------------------------------------------------------------------------------
echo "[3/5] Restoring bootloader configuration and kernel parameters..."
RESTORE_PPFEATUREMASK=0
if [ -f "${BACKUP_DIR}/grub.bak" ]; then
  if grep -q "amdgpu.ppfeaturemask=0xffffbfff" "${BACKUP_DIR}/grub.bak"; then
    RESTORE_PPFEATUREMASK=1
  fi
  install -m 644 "${BACKUP_DIR}/grub.bak" /etc/default/grub
elif [ -f /etc/default/grub ] && command -v python3 >/dev/null 2>&1; then
  python3 - /etc/default/grub <<'PYEOF'
import re, sys

grub_path = sys.argv[1]
with open(grub_path, "r", encoding="utf-8") as f:
    content = f.read()

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

with open(grub_path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
fi

if [ -f "${BACKUP_DIR}/cmdline.bak" ]; then
  if grep -q "amdgpu.ppfeaturemask=0xffffbfff" "${BACKUP_DIR}/cmdline.bak"; then
    RESTORE_PPFEATUREMASK=1
  fi
  install -m 644 "${BACKUP_DIR}/cmdline.bak" /etc/kernel/cmdline
elif [ -f /etc/kernel/cmdline ] && command -v python3 >/dev/null 2>&1; then
  python3 - /etc/kernel/cmdline <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

remove_args = {"i8042.nomux=1", "i8042.reset=1", "atkbd.reset=1"}
tokens = [t for t in content.split() if t not in remove_args]

with open(path, "w", encoding="utf-8") as f:
    f.write(" ".join(tokens) + "\n")
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
udevadm control --reload-rules
udevadm trigger --subsystem-match=pci --subsystem-match=usb || true
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

echo "=== Uninstallation complete! Please reboot your laptop to apply boot changes. ==="
