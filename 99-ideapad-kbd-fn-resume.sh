#!/usr/bin/env bash
# ==============================================================================
# Systemd Sleep Hook for Lenovo IdeaPad AMD Laptops
# ==============================================================================
# 1. Pre-suspend (pre):
#    - Saves the current FnLock state from the ideapad_laptop ACPI device
#      (VPC2004:*).
#    - Forces any unbound AMD Audio Coprocessor (PCI 1022:15e2) into D3hot
#      so it does not block the AMD SMU idlemask from reaching deep S0i3 sleep.
# 2. Post-resume (post):
#    - Waits briefly (0.5s) for the Embedded Controller (EC0_) to exit ECMO=1
#      (low-power keyboard matrix state).
#    - Cleanly reconnects the PS/2 keyboard driver (atkbd on i8042/serio*)
#      because Linux's i8042_pm_resume() skips hardware reset during s2idle.
#    - Restores the saved FnLock state and LED indicator.
# ==============================================================================

STATE_FILE="/run/ideapad_fn_lock.state"

case "$1" in
  pre)
    # 1. Save current FnLock state across all matching VPC2004 platform devices
    for fn_sysfs in /sys/bus/platform/devices/VPC2004:*/fn_lock; do
      if [ -r "$fn_sysfs" ]; then
        cat "$fn_sysfs" > "$STATE_FILE" 2>/dev/null || true
        break
      fi
    done

    # 2. Transition any unbound AMD Audio Coprocessor (1022:15e2) to D3hot
    #    so the AMD SMU can enter hardware S0i3 residency
    if command -v python3 >/dev/null 2>&1; then
      python3 -c '
import glob, os

for dev_dir in glob.glob("/sys/bus/pci/devices/*"):
    try:
        with open(os.path.join(dev_dir, "vendor")) as vf, open(os.path.join(dev_dir, "device")) as df:
            vendor = vf.read().strip().lower()
            device = df.read().strip().lower()
        if vendor == "0x1022" and device == "0x15e2" and not os.path.exists(os.path.join(dev_dir, "driver")):
            cfg_path = os.path.join(dev_dir, "config")
            with open(cfg_path, "r+b") as f:
                f.seek(0x04)
                cmd = int.from_bytes(f.read(2), "little")
                f.seek(0x04)
                f.write((cmd & ~0x07).to_bytes(2, "little"))
                f.seek(0x54)
                pmcsr = int.from_bytes(f.read(2), "little")
                f.seek(0x54)
                f.write(((pmcsr & ~0x03) | 0x03).to_bytes(2, "little"))
    except Exception:
        pass
' 2>/dev/null || true
    fi
    ;;

  post)
    # Wait briefly for the Embedded Controller (EC0_) to return to ECMO=0
    sleep 0.5

    # Reconnect the i8042 PS/2 keyboard port(s) bound to atkbd (or serio0 fallback)
    reconnected=0
    for serio_dir in /sys/devices/platform/i8042/serio*; do
      [ -d "$serio_dir" ] || continue
      if [ -w "$serio_dir/drvctl" ]; then
        if grep -q "DRIVER=atkbd" "$serio_dir/uevent" 2>/dev/null || [ "$(basename "$serio_dir")" = "serio0" ]; then
          echo -n reconnect > "$serio_dir/drvctl" 2>/dev/null || true
          reconnected=1
        fi
      fi
    done
    if [ "$reconnected" -eq 0 ] && [ -w "/sys/devices/platform/i8042/serio0/drvctl" ]; then
      echo -n reconnect > "/sys/devices/platform/i8042/serio0/drvctl" 2>/dev/null || true
    fi

    # Restore saved FnLock state on VPC2004:*
    if [ -f "$STATE_FILE" ]; then
      for fn_sysfs in /sys/bus/platform/devices/VPC2004:*/fn_lock; do
        if [ -w "$fn_sysfs" ]; then
          cat "$STATE_FILE" > "$fn_sysfs" 2>/dev/null || true
        fi
      done
    fi
    ;;
esac

exit 0
