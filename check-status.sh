#!/usr/bin/env bash
# ==============================================================================
# Lenovo IdeaPad AMD Linux Power, Suspend (S0i3) & Keyboard Fix - Status Check
# ==============================================================================
# Inspects the runtime state of kernel parameters, ACPI SSDT override, internal
# keyboard (i8042/atkbd), Fn/FnLock hotkeys (ideapad_laptop), PCI runtime PM,
# battery conservation mode, and AMD PMC S0i3 hardware sleep residency.
# ==============================================================================

echo "======================================================================"
echo " LENOVO IDEAPAD AMD - POWER, SUSPEND (S0i3) & KEYBOARD STATUS CHECK"
echo "======================================================================"

echo ""
echo "1. RUNNING KERNEL PARAMETERS (/proc/cmdline):"
cat /proc/cmdline
if grep -q "amdgpu.ppfeaturemask=0xffffbfff" /proc/cmdline; then
  echo "   [WARN] 'amdgpu.ppfeaturemask=0xffffbfff' is still active in the running session."
  echo "          Please REBOOT your laptop so AMD GFXOFF and S0i3 can activate."
else
  echo "   [OK] AMD GFXOFF is enabled (no blocking ppfeaturemask)."
fi
if grep -q "i8042.reset=1" /proc/cmdline && grep -q "atkbd.reset=1" /proc/cmdline; then
  echo "   [OK] Clean i8042/atkbd reset parameters are active."
else
  echo "   [WARN] 'i8042.reset=1 atkbd.reset=1' not found in running /proc/cmdline (reboot required if just installed)."
fi

echo ""
echo "2. CONFIGURED NEXT-BOOT PARAMETERS:"
if command -v grubby >/dev/null 2>&1; then
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    grubby --info=DEFAULT | grep -E "kernel=|args=" || true
  else
    echo "   (Run with sudo to inspect 'grubby --info=DEFAULT')"
  fi
elif [ -f /etc/default/grub ]; then
  grep -E "^GRUB_CMDLINE_LINUX" /etc/default/grub || true
fi

echo ""
echo "3. INTERNAL KEYBOARD (i8042/atkbd) & FN KEYS (ideapad_laptop):"
SERIO_DIR=""
for d in /sys/devices/platform/i8042/serio*; do
  [ -d "$d" ] || continue
  if grep -q "DRIVER=atkbd" "$d/uevent" 2>/dev/null; then
    SERIO_DIR="$d"
    break
  fi
  [ -z "$SERIO_DIR" ] && SERIO_DIR="$d"
done
[ -z "$SERIO_DIR" ] && SERIO_DIR="/sys/devices/platform/i8042/serio0"

SERIO_DRIVER="$(grep "DRIVER=" "$SERIO_DIR/uevent" 2>/dev/null | cut -d= -f2 || echo "N/A")"
SERIO_ERR="$(cat "$SERIO_DIR/err_count" 2>/dev/null || echo "N/A")"
SERIO_WAKEUP="$(cat "$SERIO_DIR/power/wakeup" 2>/dev/null || echo "N/A")"
FN_LED_PARAM="$(cat /sys/module/ideapad_laptop/parameters/set_fn_lock_led 2>/dev/null || echo "N/A")"
FN_LOCK_VAL="N/A"
for f in /sys/bus/platform/devices/VPC2004:*/fn_lock; do
  if [ -r "$f" ]; then
    FN_LOCK_VAL="$(cat "$f") ($f)"
    break
  fi
done
HOOK_INSTALLED="NO"
if [ -x /usr/lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh ] || [ -x /lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh ]; then
  HOOK_INSTALLED="YES (OK)"
fi

echo "   - Keyboard port:                ${SERIO_DIR}"
echo "   - Keyboard driver:              ${SERIO_DRIVER}"
echo "   - PS/2 frame errors (err_count): ${SERIO_ERR}"
echo "   - Internal keyboard wakeup:     ${SERIO_WAKEUP}"
echo "   - ideapad set_fn_lock_led:      ${FN_LED_PARAM}"
echo "   - Current FnLock state:         ${FN_LOCK_VAL}"
echo "   - Systemd sleep hook installed: ${HOOK_INSTALLED}"
echo "   - ACPI SSDT override file:      $([ -f /etc/acpi/tables/ssdt11.aml ] && echo 'INSTALLED (/etc/acpi/tables/ssdt11.aml)' || echo 'NOT INSTALLED')"

echo ""
echo "4. PCI RUNTIME POWER MANAGEMENT & BATTERY CONSERVATION:"
# Find AMD Audio Coprocessor (1022:15e2) dynamically
ACP_FOUND=0
for dev in /sys/bus/pci/devices/*; do
  [ -d "$dev" ] || continue
  v="$(cat "$dev/vendor" 2>/dev/null || true)"
  d="$(cat "$dev/device" 2>/dev/null || true)"
  if [ "$v" = "0x1022" ] && [ "$d" = "0x15e2" ]; then
    ACP_FOUND=1
    echo "   - AMD Audio Coprocessor ($(basename "$dev")) power/control: $(cat "$dev/power/control" 2>/dev/null || echo N/A)"
  elif [ "$v" = "0x17a0" ]; then
    echo "   - Genesys SD Reader ($(basename "$dev")) power/control:     $(cat "$dev/power/control" 2>/dev/null || echo N/A)"
  fi
done
if [ "$ACP_FOUND" -eq 0 ]; then
  echo "   - AMD Audio Coprocessor (1022:15e2): Not present on this model"
fi

if [ -e /sys/bus/pci/devices/0000:00:02.1/power/wakeup ]; then
  echo "   - PCIe GPP Bridge (0000:00:02.1) wakeup:        $(cat /sys/bus/pci/devices/0000:00:02.1/power/wakeup 2>/dev/null)"
fi

for bat in /sys/class/power_supply/BAT*; do
  [ -d "$bat" ] || continue
  if [ -r "$bat/charge_types" ]; then
    echo "   - Battery charge mode ($(basename "$bat")/charge_types):   $(cat "$bat/charge_types" 2>/dev/null)"
  fi
done
for cm in /sys/bus/platform/devices/VPC2004:*/conservation_mode; do
  [ -r "$cm" ] || continue
  echo "   - Battery conservation_mode ($(basename "$(dirname "$cm")")): $(cat "$cm" 2>/dev/null)"
done

echo ""
echo "5. AMD PMC S0i3 HARDWARE SLEEP STATISTICS (requires sudo):"
if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -r /sys/kernel/debug/amd_pmc/s0ix_stats ]; then
  cat /sys/kernel/debug/amd_pmc/s0ix_stats
  if [ -r /sys/kernel/debug/amd_pmc/smu_fw_info ]; then
    cat /sys/kernel/debug/amd_pmc/smu_fw_info
  fi
else
  echo "   (Run 'sudo $0' to read /sys/kernel/debug/amd_pmc/s0ix_stats)"
fi
echo "======================================================================"
