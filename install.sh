#!/usr/bin/env bash
# ==============================================================================
# Lenovo IdeaPad AMD Linux Power, Suspend (S0i3) & Keyboard Fix - Installer
# ==============================================================================
# Applies S0i3 Modern Standby optimizations, ACPI SSDT SNTM bridge override,
# i8042/atkbd PS/2 keyboard + Fn/FnLock resume recovery hook, PCI runtime PM
# rules, and Lenovo Battery Conservation Mode across Linux distributions.
#
# SECURITY NOTES:
#   * Must be run as root from a checkout you trust. The installer refuses to
#     run from a tree that is writable by group/others (e.g. /tmp or a shared
#     path), because it executes files from that tree as root.
#   * System-file backups are stored in /var/backups/lenovo-ideapad-power-fix
#     (root-owned, mode 0700) together with a SHA-256 manifest that
#     uninstall.sh verifies before restoring anything.
#   * The ACPI SSDT is rebuilt from ssdt11_patched.dsl with iasl when
#     acpica-tools is installed. Otherwise the shipped AML is validated
#     (header, Length, checksum, optional pinned hash) before installation.
#   * /etc/default/grub and /etc/kernel/cmdline are edited atomically, and an
#     ERR trap restores the original boot configuration if a later step fails.
#   * See SECURITY.md for the threat model and residual risks.
# ==============================================================================

set -Eeuo pipefail
umask 077

# Never resolve privileged tools through a user-controlled PATH.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BACKUP_DIR="/var/backups/lenovo-ideapad-power-fix"
MANIFEST="${BACKUP_DIR}/manifest.sha256"
LEGACY_BACKUP_DIR="${SCRIPT_DIR}/backups"

TMP_DIR=""
GRUB_TOUCHED=0
CMDLINE_TOUCHED=0
AML_TO_INSTALL="${SCRIPT_DIR}/ssdt11_patched.aml"

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
  --force            Apply changes even if hardware/integrity checks fail
                     (also bypasses ACPI table verification; NOT recommended)
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
      printf 'Unknown option: %q\n' "$arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: Please run this installer as root:" >&2
  printf '  sudo %q' "$0" >&2
  if [ "$#" -gt 0 ]; then
    printf ' %q' "$@" >&2
  fi
  printf '\n' >&2
  exit 1
fi

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf -- "${TMP_DIR:?}"
  fi
  return 0
}
trap cleanup EXIT

on_error() {
  local rc=$?
  trap - ERR
  echo "" >&2
  echo "ERROR: installation failed (exit code $rc)." >&2
  if [ "$GRUB_TOUCHED" -eq 1 ] && [ -f "${BACKUP_DIR}/grub.bak" ]; then
    if install -m 644 -- "${BACKUP_DIR}/grub.bak" /etc/default/grub; then
      echo "  -> Restored /etc/default/grub from the verified backup." >&2
    fi
  fi
  if [ "$CMDLINE_TOUCHED" -eq 1 ] && [ -f "${BACKUP_DIR}/cmdline.bak" ]; then
    if install -m 644 -- "${BACKUP_DIR}/cmdline.bak" /etc/kernel/cmdline; then
      echo "  -> Restored /etc/kernel/cmdline from the verified backup." >&2
    fi
  fi
  echo "  -> Review the state and run 'sudo ./uninstall.sh' if needed." >&2
  exit "$rc"
}
trap on_error ERR

# ------------------------------------------------------------------------------
# 0. Trust checks: source tree, hardware identification
# ------------------------------------------------------------------------------
if [ "$FORCE" -eq 0 ]; then
  unsafe_path="$(find "$SCRIPT_DIR" -maxdepth 1 \( -type f -o -type d \) -perm /022 -print -quit 2>/dev/null || true)"
  if [ -n "$unsafe_path" ]; then
    echo "Error: this checkout is writable by group/others:" >&2
    echo "       $unsafe_path" >&2
    echo "       Move the repository to a private directory (never /tmp or a shared path)" >&2
    echo "       or fix the permissions with: chmod -R go-w ." >&2
    echo "       Use --force only if you fully trust every file in this tree." >&2
    exit 1
  fi
fi

for src in \
  install.sh uninstall.sh check-status.sh verify-aml.sh \
  ssdt11_patched.aml ssdt11_patched.dsl \
  99-ideapad-kbd-fn-resume.sh 99-ideapad-power-save.rules \
  99-ideapad-acpi-override.conf ideapad-laptop.conf lenovo-battery.service; do
  if [ -L "${SCRIPT_DIR}/${src}" ]; then
    echo "Error: ${SCRIPT_DIR}/${src} is a symlink; refusing to use it." >&2
    exit 1
  fi
  if [ ! -e "${SCRIPT_DIR}/${src}" ]; then
    echo "Error: required repository file is missing: ${SCRIPT_DIR}/${src}" >&2
    exit 1
  fi
done

DMI_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
DMI_PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
CPU_VENDOR="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"

if [ "$FORCE" -eq 0 ] && [ -z "$DMI_VENDOR" ]; then
  echo "Error: could not read /sys/class/dmi/id/sys_vendor." >&2
  echo "       Cannot confirm that this machine is a Lenovo. Refusing to continue (fail-safe)." >&2
  echo "       Use --force only for testing (e.g. in a VM)." >&2
  exit 1
fi

if [ "$FORCE" -eq 0 ] && [ -n "$DMI_VENDOR" ] && [[ "$DMI_VENDOR" != *[Ll][Ee][Nn][Oo][Vv][Oo]* ]]; then
  echo "Error: This fix targets Lenovo IdeaPad laptops, but the detected system vendor is '$DMI_VENDOR'." >&2
  echo "       Use '--force' to apply the changes anyway." >&2
  exit 1
fi

if [ "$FORCE" -eq 0 ] && [ -z "$CPU_VENDOR" ]; then
  echo "Warning: could not determine the CPU vendor; skipping the ACPI override (fail-safe)." >&2
  SKIP_ACPI=1
elif [ "$FORCE" -eq 0 ] && [ "$CPU_VENDOR" != "AuthenticAMD" ]; then
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
# 0b. Create a root-owned backup directory outside the repository
# ------------------------------------------------------------------------------
if [ -L "$BACKUP_DIR" ]; then
  echo "Error: $BACKUP_DIR is a symlink; refusing to continue." >&2
  exit 1
fi
if [ ! -d /var/backups ]; then
  install -d -m 0755 -- /var/backups
fi
install -d -m 0700 -- "$BACKUP_DIR"
chmod 0700 -- "$BACKUP_DIR"
backup_uid="$(stat -c '%u' -- "$BACKUP_DIR" 2>/dev/null || true)"
if [ -z "$backup_uid" ] || [ "$backup_uid" != "0" ]; then
  echo "Error: could not verify that $BACKUP_DIR is owned by root; refusing to continue." >&2
  exit 1
fi

if [ -d "$LEGACY_BACKUP_DIR" ] && [ -n "$(ls -A -- "$LEGACY_BACKUP_DIR" 2>/dev/null || true)" ]; then
  echo "Warning: legacy backups detected in ${LEGACY_BACKUP_DIR}." >&2
  echo "         They are NOT used or trusted (anyone with write access to the" >&2
  echo "         checkout could have modified them). See uninstall.sh --trust-legacy-backups." >&2
fi

# Back up a system file only once, unless it is byte-identical to our repo copy.
# A *.absent marker records that the original file did not exist, so later
# reinstalls never mistake our own installed artifact for the original file.
backup_once() {
  local src="$1"
  local dest="$2"
  local reference="${3:-}"
  local marker
  marker="${BACKUP_DIR}/$(basename -- "$dest").absent"

  if [ -f "$marker" ]; then
    if [ -z "$reference" ] || [ ! -e "$src" ] || cmp -s -- "$src" "$reference"; then
      return 0
    fi
  fi

  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    : > "$marker"
    chmod 0600 -- "$marker"
    return 0
  fi

  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ ! -f "$dest" ] || [ -L "$dest" ]; then
      echo "Error: unsafe backup entry (not a regular file): $dest" >&2
      exit 1
    fi
    return 0
  fi

  if [ -n "$reference" ] && [ -f "$reference" ] && cmp -s -- "$src" "$reference"; then
    return 0
  fi

  # -L dereferences a symlinked source; -p preserves mode and timestamps.
  cp -Lp -- "$src" "$dest"
  echo "  -> Backed up $src to $BACKUP_DIR/$(basename -- "$dest")"
}

backup_once /etc/default/grub "${BACKUP_DIR}/grub.bak"
backup_once /etc/kernel/cmdline "${BACKUP_DIR}/cmdline.bak"
backup_once /etc/systemd/system/lenovo-battery.service "${BACKUP_DIR}/lenovo-battery.service.bak" "${SCRIPT_DIR}/lenovo-battery.service"

# Our own ACPI artifacts must never be mistaken for the original configuration.
if [ -e /etc/acpi/tables/ssdt11.aml ] && grep -qa -- "FixSNTM" /etc/acpi/tables/ssdt11.aml 2>/dev/null; then
  :
else
  backup_once /etc/acpi/tables/ssdt11.aml "${BACKUP_DIR}/ssdt11.aml.bak" "${SCRIPT_DIR}/ssdt11_patched.aml"
fi

backup_once /etc/dracut.conf.d/99-ideapad-acpi-override.conf "${BACKUP_DIR}/99-ideapad-acpi-override.conf.bak" "${SCRIPT_DIR}/99-ideapad-acpi-override.conf"
backup_once /usr/lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh "${BACKUP_DIR}/99-ideapad-kbd-fn-resume.sh.bak" "${SCRIPT_DIR}/99-ideapad-kbd-fn-resume.sh"
backup_once /lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh "${BACKUP_DIR}/99-ideapad-kbd-fn-resume.sh.bak" "${SCRIPT_DIR}/99-ideapad-kbd-fn-resume.sh"
backup_once /etc/modprobe.d/ideapad-laptop.conf "${BACKUP_DIR}/ideapad-laptop.conf.bak" "${SCRIPT_DIR}/ideapad-laptop.conf"
backup_once /etc/udev/rules.d/99-ideapad-power-save.rules "${BACKUP_DIR}/99-ideapad-power-save.rules.bak" "${SCRIPT_DIR}/99-ideapad-power-save.rules"

if [ -e /boot/acpi_override.cpio ] && grep -qa -- "FixSNTM" /boot/acpi_override.cpio 2>/dev/null; then
  :
else
  backup_once /boot/acpi_override.cpio "${BACKUP_DIR}/acpi_override.cpio.bak"
fi

# Record the SHA-256 of every backup so uninstall.sh can verify integrity
# before restoring a file as root.
write_manifest() {
  local out="${MANIFEST}.new"
  local f

  : > "$out"
  while IFS= read -r -d '' f; do
    printf '%s  %s\n' "$(sha256sum -- "$f" | awk '{ print $1 }')" "$(basename -- "$f")"
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.bak' -print0) >> "$out"
  chmod 0600 -- "$out"
  mv -f -- "$out" "$MANIFEST"
}

write_manifest

# Record whether the battery unit was already enabled before we install ours.
BATTERY_WAS_ENABLED=0
if [ -f /etc/systemd/system/lenovo-battery.service ] &&
   command -v systemctl >/dev/null 2>&1 &&
   systemctl is-enabled --quiet lenovo-battery.service 2>/dev/null; then
  BATTERY_WAS_ENABLED=1
fi

# Verify the ACPI table and, when possible, rebuild it from the audited DSL.
verify_acpi_table() {
  if [ "$FORCE" -eq 1 ]; then
    echo "  !! --force: skipping ACPI table integrity verification." >&2
    return 0
  fi

  TMP_DIR="$(mktemp -d /tmp/lenovo-ideapad-power-fix.XXXXXX)"
  local rebuilt="${TMP_DIR}/ssdt11.aml"

  if ! VERIFY_AML_REBUILD_OUT="$rebuilt" bash "${SCRIPT_DIR}/verify-aml.sh"; then
    echo "Error: ACPI table verification failed. No ACPI changes were applied." >&2
    echo "       Install 'acpica-tools', review ssdt11_patched.aml, or use --force (not recommended)." >&2
    exit 1
  fi

  if [ -s "$rebuilt" ]; then
    AML_TO_INSTALL="$rebuilt"
    echo "  -> Using the ACPI table rebuilt from ssdt11_patched.dsl."
  fi
}

# ------------------------------------------------------------------------------
# 1. Install ACPI SSDT SNTM bridge table override
# ------------------------------------------------------------------------------
# Only install the bridge if the firmware actually contains the broken Intel
# ACPI path. Any detection failure means "not found" (fail-safe).
if [ "$SKIP_ACPI" -eq 0 ] && [ "$FORCE" -eq 0 ] && [ -d /sys/firmware/acpi/tables ]; then
  acpi_bug_found=0
  while IFS= read -r -d '' tbl; do
    if grep -qa -- "PC00LPCBEC0_SNTM" "$tbl" 2>/dev/null; then
      acpi_bug_found=1
      break
    fi
  done < <(find /sys/firmware/acpi/tables -maxdepth 1 -type f -print0 2>/dev/null)

  if [ "$acpi_bug_found" -ne 1 ]; then
    echo "  -> The firmware does not expose the erroneous PC00.LPCB.EC0.SNTM reference; skipping ACPI override."
    echo "     (Use --force only if you have independently confirmed that your model needs it.)"
    SKIP_ACPI=1
  fi
fi

if [ "$SKIP_ACPI" -eq 0 ]; then
  verify_acpi_table
  echo "[1/6] Installing ACPI SSDT SNTM bridge table override..."
  install -d -m 0755 -- /etc/acpi/tables
  install -m 644 -- "$AML_TO_INSTALL" /etc/acpi/tables/ssdt11.aml

  if command -v dracut >/dev/null 2>&1; then
    install -d -m 0755 -- /etc/dracut.conf.d
    install -m 644 -- "${SCRIPT_DIR}/99-ideapad-acpi-override.conf" /etc/dracut.conf.d/99-ideapad-acpi-override.conf
  elif command -v python3 >/dev/null 2>&1; then
    # For non-dracut systems (e.g., Debian/Ubuntu initramfs-tools or Arch mkinitcpio),
    # build a standard uncompressed early-initrd CPIO archive at /boot/acpi_override.cpio
    python3 - "$AML_TO_INSTALL" "/boot/acpi_override.cpio" <<'PYEOF'
import sys

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
    if [ -f /etc/default/grub ]; then
      GRUB_TOUCHED=1
      python3 - /etc/default/grub <<'PYEOF'
import os
import re
import stat
import sys
import tempfile

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
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

write_atomic(path, content)
PYEOF
    fi
  else
    echo "Warning: neither dracut nor python3 is available; the ACPI table was" >&2
    echo "         installed but no boot-time loader was configured for it." >&2
  fi
else
  echo "[1/6] Skipping ACPI SSDT override."
fi

# ------------------------------------------------------------------------------
# 2. Install ideapad_laptop modprobe config & systemd-sleep keyboard/Fn hook
# ------------------------------------------------------------------------------
echo "[2/6] Configuring ideapad_laptop module and systemd-sleep keyboard/Fn hook..."
install -d -m 0755 -- /etc/modprobe.d
install -m 644 -- "${SCRIPT_DIR}/ideapad-laptop.conf" /etc/modprobe.d/ideapad-laptop.conf

SLEEP_HOOK_DIR="/usr/lib/systemd/system-sleep"
if [ ! -d "$SLEEP_HOOK_DIR" ] && [ -d "/lib/systemd/system-sleep" ]; then
  SLEEP_HOOK_DIR="/lib/systemd/system-sleep"
fi
install -d -m 0755 -- "$SLEEP_HOOK_DIR"
install -m 755 -- "${SCRIPT_DIR}/99-ideapad-kbd-fn-resume.sh" "${SLEEP_HOOK_DIR}/99-ideapad-kbd-fn-resume.sh"

# ------------------------------------------------------------------------------
# 3. Install PCI runtime power management & USB wakeup udev rules
# ------------------------------------------------------------------------------
echo "[3/6] Installing udev power saving and wakeup rules..."
install -d -m 0755 -- /etc/udev/rules.d
install -m 644 -- "${SCRIPT_DIR}/99-ideapad-power-save.rules" /etc/udev/rules.d/99-ideapad-power-save.rules
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=pci --subsystem-match=usb || true
else
  echo "  -> Warning: udevadm not found; rules will be applied on next boot." >&2
fi

# ------------------------------------------------------------------------------
# 4. Configure systemd services (Battery Conservation Mode & Intel thermald)
# ------------------------------------------------------------------------------
echo "[4/6] Configuring systemd services..."
if [ "$SKIP_BATTERY" -eq 0 ]; then
  if [ "$BATTERY_WAS_ENABLED" -eq 1 ]; then
    : > "${BACKUP_DIR}/lenovo-battery.was_enabled"
    chmod 0600 -- "${BACKUP_DIR}/lenovo-battery.was_enabled"
  fi
  install -m 644 -- "${SCRIPT_DIR}/lenovo-battery.service" /etc/systemd/system/lenovo-battery.service
  systemctl daemon-reload
  systemctl enable --now lenovo-battery.service
else
  echo "  -> Skipping lenovo-battery.service (--skip-battery)."
fi

# Disable thermald on AMD CPUs (thermald is exclusively for Intel processors)
if grep -qi "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
  if systemctl is-enabled thermald.service >/dev/null 2>&1; then
    : > "${BACKUP_DIR}/thermald.was_enabled"
    chmod 0600 -- "${BACKUP_DIR}/thermald.was_enabled"
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
  if [ -f /etc/default/grub ]; then
    if command -v python3 >/dev/null 2>&1; then
      GRUB_TOUCHED=1
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

write_atomic(grub_path, content)
PYEOF
    else
      echo "  -> Warning: python3 not found; /etc/default/grub was not modified." >&2
    fi
  fi

  # Update /etc/kernel/cmdline when present (systemd-boot / Unified Kernel Images)
  if [ -f /etc/kernel/cmdline ]; then
    if command -v python3 >/dev/null 2>&1; then
      CMDLINE_TOUCHED=1
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

remove_args = {"amdgpu.ppfeaturemask=0xffffbfff", "i8042.dumbkbd=1", "i8042.nopnp=1"}
add_args = ["i8042.nomux=1", "i8042.reset=1", "atkbd.reset=1"]

tokens = [t for t in content.split() if t not in remove_args]
for a in add_args:
    if a not in tokens:
        tokens.append(a)

write_atomic(path, " ".join(tokens) + "\n")
PYEOF
    else
      echo "  -> Warning: python3 not found; /etc/kernel/cmdline was not modified." >&2
    fi
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
