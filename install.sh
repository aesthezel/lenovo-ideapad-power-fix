#!/usr/bin/env bash
# ==============================================================================
# Lenovo IdeaPad AMD Linux Power, Suspend (S0i3) & Keyboard Fix - Installer
# ==============================================================================
# Applies S0i3 Modern Standby optimizations, ACPI SSDT SNTM bridge override,
# i8042/atkbd PS/2 keyboard + Fn/FnLock resume recovery hook, PCI runtime PM
# rules, and Lenovo Battery Conservation Mode across Linux distributions.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"

SKIP_ACPI=0
SKIP_BATTERY=0
SKIP_BOOTLOADER=0
FORCE=0

usage() {
  cat <<EOF
Usage: sudo ./install.sh [OPTIONS]

Options:
  --skip-acpi        Skip installing the ACPI SSDT SNTM bridge table override
  --skip-battery     Skip installing the Lenovo 80% battery conservation service
  --skip-bootloader  Skip updating kernel command-line parameters in GRUB/bootloader
  --force            Apply changes even if hardware/firmware compatibility checks fail
  -h, --help         Show this help message
EOF
}

for arg in "$@"; do
  case "$arg" in
    --skip-acpi)       SKIP_ACPI=1 ;;
    --skip-battery)    SKIP_BATTERY=1 ;;
    --skip-bootloader) SKIP_BOOTLOADER=1 ;;
    --force)           FORCE=1 ;;
    -h|--help)         usage; exit 0 ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: Please run this installer as root:" >&2
  echo "  sudo $0 $*" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# Hardware sanity check (Lenovo IdeaPad with AMD Ryzen APU)
# ------------------------------------------------------------------------------
DMI_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
DMI_PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
CPU_VENDOR="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"

if [ "$FORCE" -eq 0 ] && [ -n "$DMI_VENDOR" ] && [[ "$DMI_VENDOR" != *[Ll][Ee][Nn][Oo][Vv][Oo]* ]]; then
  echo "Error: This fix targets Lenovo IdeaPad laptops, but the detected system vendor is '$DMI_VENDOR'." >&2
  echo "       Use '--force' to apply the changes anyway." >&2
  exit 1
fi

if [ "$FORCE" -eq 0 ] && [ -n "$CPU_VENDOR" ] && [ "$CPU_VENDOR" != "AuthenticAMD" ]; then
  echo "Warning: Detected CPU vendor '$CPU_VENDOR' (not AMD). The S0i3/GFXOFF fixes target AMD APUs."
  if [ "$SKIP_ACPI" -eq 0 ]; then
    echo "         Skipping the ACPI SSDT override to avoid conflicting with existing Intel ACPI paths."
    SKIP_ACPI=1
  fi
fi

echo "=== Installing Lenovo IdeaPad AMD Power, S0i3 Suspend & Keyboard Fixes ==="
if [ -n "$DMI_PRODUCT" ]; then
  echo "    Detected model: ${DMI_VENDOR} ${DMI_PRODUCT}"
fi

# ------------------------------------------------------------------------------
# 0. Back up original system configuration files (once, preserving initial state)
# ------------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"

# Back up a system file only once, unless it is byte-identical to our repo copy
backup_once() {
  local src="$1" dest="$2" reference="${3:-}"
  [ -e "$src" ] || return 0
  [ -e "$dest" ] && return 0
  if [ -n "$reference" ] && [ -f "$reference" ] && cmp -s "$src" "$reference"; then
    return 0
  fi
  cp -a "$src" "$dest"
  echo "  -> Backed up $src to backups/$(basename "$dest")"
}

backup_once /etc/default/grub "${BACKUP_DIR}/grub.bak"
backup_once /etc/kernel/cmdline "${BACKUP_DIR}/cmdline.bak"
backup_once /etc/systemd/system/lenovo-battery.service "${BACKUP_DIR}/lenovo-battery.service.bak" "${SCRIPT_DIR}/lenovo-battery.service"
backup_once /etc/acpi/tables/ssdt11.aml "${BACKUP_DIR}/ssdt11.aml.bak" "${SCRIPT_DIR}/ssdt11_patched.aml"
backup_once /etc/dracut.conf.d/99-ideapad-acpi-override.conf "${BACKUP_DIR}/99-ideapad-acpi-override.conf.bak" "${SCRIPT_DIR}/99-ideapad-acpi-override.conf"
backup_once /usr/lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh "${BACKUP_DIR}/99-ideapad-kbd-fn-resume.sh.bak" "${SCRIPT_DIR}/99-ideapad-kbd-fn-resume.sh"
backup_once /lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh "${BACKUP_DIR}/99-ideapad-kbd-fn-resume.sh.bak" "${SCRIPT_DIR}/99-ideapad-kbd-fn-resume.sh"
backup_once /etc/modprobe.d/ideapad-laptop.conf "${BACKUP_DIR}/ideapad-laptop.conf.bak" "${SCRIPT_DIR}/ideapad-laptop.conf"
backup_once /etc/udev/rules.d/99-ideapad-power-save.rules "${BACKUP_DIR}/99-ideapad-power-save.rules.bak" "${SCRIPT_DIR}/99-ideapad-power-save.rules"
backup_once /boot/acpi_override.cpio "${BACKUP_DIR}/acpi_override.cpio.bak"

# ------------------------------------------------------------------------------
# 1. Install ACPI SSDT SNTM bridge table override
# ------------------------------------------------------------------------------
# Only install the bridge if the firmware actually contains the broken Intel
# ACPI path. This keeps the fix safe on models whose BIOS does not need it.
if [ "$SKIP_ACPI" -eq 0 ] && [ "$FORCE" -eq 0 ] && [ -d /sys/firmware/acpi/tables ]; then
  if grep -qa "PC00LPCBEC0_SNTM" /sys/firmware/acpi/tables/* 2>/dev/null; then
    :
  else
    grep_rc=$?
    if [ "$grep_rc" -eq 1 ]; then
      echo "  -> Firmware does not contain the erroneous PC00.LPCB.EC0.SNTM reference; skipping ACPI override."
      SKIP_ACPI=1
    fi
  fi
fi

if [ "$SKIP_ACPI" -eq 0 ]; then
  echo "[1/6] Installing ACPI SSDT SNTM bridge table override..."
  mkdir -p /etc/acpi/tables
  install -m 644 "${SCRIPT_DIR}/ssdt11_patched.aml" /etc/acpi/tables/ssdt11.aml

  if command -v dracut >/dev/null 2>&1; then
    mkdir -p /etc/dracut.conf.d
    install -m 644 "${SCRIPT_DIR}/99-ideapad-acpi-override.conf" /etc/dracut.conf.d/99-ideapad-acpi-override.conf
  elif command -v python3 >/dev/null 2>&1; then
    # For non-dracut systems (e.g., Debian/Ubuntu initramfs-tools or Arch mkinitcpio),
    # build a standard uncompressed early-initrd CPIO archive at /boot/acpi_override.cpio
    python3 - "${SCRIPT_DIR}/ssdt11_patched.aml" "/boot/acpi_override.cpio" <<'PYEOF'
import os, sys

aml_path, out_path = sys.argv[1], sys.argv[2]
with open(aml_path, "rb") as f:
    aml_data = f.read()

def cpio_entry(name, data, mode=0o100644, ino=1):
    name_b = name.encode("ascii") + b"\x00"
    hdr = (
        "070701"
        f"{ino:08x}{mode:08x}{0:08x}{0:08x}{1:08x}{0:08x}"
        f"{len(data):08x}{0:08x}{0:08x}{0:08x}{0:08x}"
        f"{len(name_b):08x}{0:08x}"
    ).encode("ascii")
    buf = bytearray(hdr + name_b)
    while len(buf) % 4 != 0:
        buf.append(0)
    buf.extend(data)
    while len(buf) % 4 != 0:
        buf.append(0)
    return bytes(buf)

archive = bytearray()
archive.extend(cpio_entry("kernel", b"", mode=0o040755, ino=1))
archive.extend(cpio_entry("kernel/firmware", b"", mode=0o040755, ino=2))
archive.extend(cpio_entry("kernel/firmware/acpi", b"", mode=0o040755, ino=3))
archive.extend(cpio_entry("kernel/firmware/acpi/ssdt11.aml", aml_data, mode=0o100644, ino=4))
archive.extend(cpio_entry("TRAILER!!!", b"", mode=0, ino=0))
while len(archive) % 512 != 0:
    archive.append(0)

with open(out_path, "wb") as out:
    out.write(archive)
PYEOF
    chmod 644 /boot/acpi_override.cpio
    if [ -f /etc/default/grub ] && command -v python3 >/dev/null 2>&1; then
      python3 - /etc/default/grub <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

m = re.search(r'^GRUB_EARLY_INITRD_LINUX_CUSTOM=(?:"([^"]*)"|\'([^\']*)\'|(\S*))', content, flags=re.M)
if m:
    value = next(g for g in m.groups() if g is not None)
    tokens = value.split()
    if "acpi_override.cpio" not in tokens:
        tokens.append("acpi_override.cpio")
    replacement = 'GRUB_EARLY_INITRD_LINUX_CUSTOM="' + " ".join(tokens) + '"'
    content = content[:m.start()] + replacement + content[m.end():]
else:
    content = content.rstrip("\n") + '\nGRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.cpio"\n'

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
    fi
  fi
else
  echo "[1/6] Skipping ACPI SSDT override."
fi

# ------------------------------------------------------------------------------
# 2. Install ideapad_laptop modprobe config & systemd-sleep keyboard/Fn hook
# ------------------------------------------------------------------------------
echo "[2/6] Configuring ideapad_laptop module and systemd-sleep keyboard/Fn hook..."
mkdir -p /etc/modprobe.d
install -m 644 "${SCRIPT_DIR}/ideapad-laptop.conf" /etc/modprobe.d/ideapad-laptop.conf

SLEEP_HOOK_DIR="/usr/lib/systemd/system-sleep"
if [ ! -d "$SLEEP_HOOK_DIR" ] && [ -d "/lib/systemd/system-sleep" ]; then
  SLEEP_HOOK_DIR="/lib/systemd/system-sleep"
fi
mkdir -p "$SLEEP_HOOK_DIR"
install -m 755 "${SCRIPT_DIR}/99-ideapad-kbd-fn-resume.sh" "${SLEEP_HOOK_DIR}/99-ideapad-kbd-fn-resume.sh"

# ------------------------------------------------------------------------------
# 3. Install PCI runtime power management & USB wakeup udev rules
# ------------------------------------------------------------------------------
echo "[3/6] Installing udev power saving and wakeup rules..."
mkdir -p /etc/udev/rules.d
install -m 644 "${SCRIPT_DIR}/99-ideapad-power-save.rules" /etc/udev/rules.d/99-ideapad-power-save.rules
udevadm control --reload-rules
udevadm trigger --subsystem-match=pci --subsystem-match=usb || true

# ------------------------------------------------------------------------------
# 4. Configure systemd services (Battery Conservation Mode & Intel thermald)
# ------------------------------------------------------------------------------
echo "[4/6] Configuring systemd services..."
if [ "$SKIP_BATTERY" -eq 0 ]; then
  install -m 644 "${SCRIPT_DIR}/lenovo-battery.service" /etc/systemd/system/lenovo-battery.service
  systemctl daemon-reload
  systemctl enable --now lenovo-battery.service
else
  echo "  -> Skipping lenovo-battery.service (--skip-battery)."
fi

# Disable thermald on AMD CPUs (thermald is exclusively for Intel processors)
if grep -qi "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
  if systemctl is-enabled thermald.service >/dev/null 2>&1; then
    touch "${BACKUP_DIR}/thermald.was_enabled"
    systemctl disable --now thermald.service 2>/dev/null || true
    echo "  -> Disabled Intel-only thermald.service on AMD system."
  fi
fi

# ------------------------------------------------------------------------------
# 5. Update kernel command-line parameters safely (preserving user UUIDs)
# ------------------------------------------------------------------------------
if [ "$SKIP_BOOTLOADER" -eq 0 ]; then
  echo "[5/6] Updating kernel parameters (enabling AMD GFXOFF/S0i3 & clean i8042 reset)..."

  # Safely update /etc/default/grub in-place without overwriting user UUIDs
  if [ -f /etc/default/grub ] && command -v python3 >/dev/null 2>&1; then
    python3 - /etc/default/grub <<'PYEOF'
import re, sys

grub_path = sys.argv[1]
with open(grub_path, "r", encoding="utf-8") as f:
    content = f.read()

remove_args = {"amdgpu.ppfeaturemask=0xffffbfff", "i8042.dumbkbd=1", "i8042.nopnp=1"}
add_args = ["i8042.nomux=1", "i8042.reset=1", "atkbd.reset=1"]

target_key = "GRUB_CMDLINE_LINUX"
if re.search(r"^GRUB_CMDLINE_LINUX_DEFAULT=", content, flags=re.M) and not re.search(r"^GRUB_CMDLINE_LINUX=", content, flags=re.M):
    target_key = "GRUB_CMDLINE_LINUX_DEFAULT"

def transform_cmdline(match):
    key, quote, val = match.group(1), match.group(2), match.group(3)
    tokens = [t for t in val.split() if t not in remove_args]
    if key == target_key:
        for a in add_args:
            if a not in tokens:
                tokens.append(a)
    return f'{key}={quote}{" ".join(tokens)}{quote}'

content = re.sub(
    r'^(GRUB_CMDLINE_LINUX(?:_DEFAULT)?)=([\'"])(.*?)\2',
    transform_cmdline,
    content,
    flags=re.M,
)

with open(grub_path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
  fi

  # Update /etc/kernel/cmdline when present (systemd-boot / Unified Kernel Images)
  if [ -f /etc/kernel/cmdline ] && command -v python3 >/dev/null 2>&1; then
    python3 - /etc/kernel/cmdline <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

remove_args = {"amdgpu.ppfeaturemask=0xffffbfff", "i8042.dumbkbd=1", "i8042.nopnp=1"}
add_args = ["i8042.nomux=1", "i8042.reset=1", "atkbd.reset=1"]

tokens = [t for t in content.split() if t not in remove_args]
for a in add_args:
    if a not in tokens:
        tokens.append(a)

with open(path, "w", encoding="utf-8") as f:
    f.write(" ".join(tokens) + "\n")
PYEOF
  fi

  # Update BLS entries if grubby is present (Fedora, RHEL, CentOS, Alma, Rocky)
  if command -v grubby >/dev/null 2>&1; then
    if ! grubby --update-kernel=ALL \
      --remove-args="amdgpu.ppfeaturemask=0xffffbfff i8042.dumbkbd=1 i8042.nopnp=1" \
      --args="i8042.nomux=1 i8042.reset=1 atkbd.reset=1"; then
      echo "  -> Warning: grubby could not update BLS entries; GRUB configuration will still be regenerated."
    fi
  fi

  # Update kernelstub if present (Pop!_OS)
  if command -v kernelstub >/dev/null 2>&1; then
    kernelstub -d "amdgpu.ppfeaturemask=0xffffbfff" >/dev/null 2>&1 || true
    kernelstub -d "i8042.dumbkbd=1" >/dev/null 2>&1 || true
    kernelstub -d "i8042.nopnp=1" >/dev/null 2>&1 || true
    kernelstub -a "i8042.nomux=1" >/dev/null 2>&1 || true
    kernelstub -a "i8042.reset=1" >/dev/null 2>&1 || true
    kernelstub -a "atkbd.reset=1" >/dev/null 2>&1 || true
  fi

  # Regenerate GRUB configuration across distributions
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
else
  echo "[5/6] Skipping bootloader update (--skip-bootloader)."
fi

# ------------------------------------------------------------------------------
# 6. Reload ideapad_laptop kernel module & rebuild initramfs
# ------------------------------------------------------------------------------
echo "[6/6] Reloading ideapad_laptop module and rebuilding initramfs..."
modprobe -r ideapad_laptop 2>/dev/null || true
modprobe ideapad_laptop 2>/dev/null || true

if command -v dracut >/dev/null 2>&1; then
  dracut -f
elif command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u
elif command -v mkinitcpio >/dev/null 2>&1; then
  mkinitcpio -P
fi

echo "=== Installation complete! Please reboot your laptop to activate GFXOFF/S0i3 and the ACPI override. ==="
