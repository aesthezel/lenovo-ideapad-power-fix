# Lenovo IdeaPad AMD Linux Power, Suspend (`S0i3`) & Keyboard Fix

A portable, distribution-agnostic fix and optimization suite for **Lenovo IdeaPad AMD Ryzen** laptops running Linux (originally engineered and verified on the **Lenovo IdeaPad Slim 3 15ABR8 / `82XM`**).

It resolves high battery drain during Modern Standby (`s2idle` / `S0i3`), ACPI BIOS symbol errors on suspend/resume, unresponsive internal PS/2 keyboards (`i8042`/`atkbd`), broken or desynchronized `Fn` / `FnLock` hotkeys (`ideapad_laptop` / `VPC2004:00`), and enables Lenovo's 80% Battery Conservation Mode (`Long_Life`).

---

## Reference Hardware & Environment

* **Laptop Model:** Lenovo IdeaPad Slim 3 15ABR8 (Machine Type: `82XM`, Motherboard: `LNVNB161216`) & compatible Lenovo IdeaPad AMD Ryzen laptops
* **BIOS / Firmware:** `KYCN40WW` (and earlier/later revisions sharing the same ACPI tables)
* **APU:** AMD Ryzen 7 5825U (*Barcelo* / Zen 3) with Radeon Graphics (also applicable to Ryzen 5000/6000/7000 U-series IdeaPads)
* **AMD PMC / SMU Firmware:** `AMDI0005:00`
* **Hardware Suspend Mode:** `s2idle` (*Modern Standby* / `S0i2 + S0i3`). Note: Lenovo's UEFI on these models does not expose legacy `S3 (deep)` sleep (`ACPI: PM: supports S0 S4 S5`). Ensure **`S0i2 + S0i3`** (or Modern Standby) is enabled in BIOS/UEFI to achieve `Last S0i3 Status: Success` (~99.95% hardware `S0i3` residency).
* **Supported Linux Distributions:**
  * **Fedora / RHEL / CentOS / AlmaLinux / Rocky Linux / openSUSE** (`dracut` + `grubby` / `grub2-mkconfig`)
  * **Ubuntu / Debian / Linux Mint / Pop!_OS** (`initramfs-tools` + `update-grub` / `kernelstub`)
  * **Arch Linux / Manjaro / EndeavourOS** (`mkinitcpio` or `dracut` + `grub-mkconfig`)

---

## Symptoms & Root Cause Analysis

### Issue A: High Battery Drain During Suspend (`Last suspend didn't reach deepest state`)
Without these fixes, the AMD Ryzen APU never enters the deep hardware **`S0i3`** low-power state (`Time in S0i3: 0`), staying in software idle due to **3 root causes**:

1. **`amdgpu.ppfeaturemask=0xffffbfff` in Kernel Parameters:**
   Some troubleshooting guides recommend this parameter, which clears bit `0x4000` (`PP_GFXOFF_MASK`) in the `amdgpu` driver and disables `GFXOFF` (`amdgpu: dpm has been disabled`). On AMD Ryzen APUs, `GFXOFF` is a strict prerequisite enforced by the SMU before authorizing `S0i3` entry.
2. **PCI Devices Stuck in `D0` (`power/control = on`) & Spurious Wakeups:**
   The AMD Audio Coprocessor (`1022:15e2`) is powered into `D0` during boot by `snd_rn_pci_acp3x` and then left unbound with `power/control = on` (because the internal audio/microphone on these laptops uses the Realtek ALC257 codec via `snd_hda_intel`), blocking the internal bus from entering `D3hot`/`D3cold`. Additionally, wireless USB mouse receivers and the SD card reader PCIe GPP bridge (`0000:00:02.1`) can trigger spurious wakeups.
3. **Lenovo BIOS ACPI Bug in `SSDT11` (`AE_NOT_FOUND` on `SNTM`):**
   Inside `\_SB.PEP_._DSM` (Function 4, screen/standby transition notification), Lenovo's BIOS mistakenly calls `\_SB.PC00.LPCB.EC0_.SNTM` (an Intel platform ACPI path) instead of `\_SB.PCI0.LPC0.EC0_.SNTM` (the actual Embedded Controller path on this AMD motherboard). This causes `_DSM` evaluation to abort with `ACPI BIOS Error (bug): Could not resolve symbol [\_SB.PC00.LPCB.EC0.SNTM], AE_NOT_FOUND` on every suspend/resume cycle.

---

### Issue B: Unresponsive Internal Keyboard & Broken `Fn` / `FnLock` Keys After Resume
On Lenovo IdeaPad laptops, the Embedded Controller (`EC0_`) splits keyboard handling across two subsystems:
* **Standard Keyboard Matrix (`AT Translated Set 2 keyboard`):** PS/2 controller `i8042` (`PNP0303:KBC0` / `IDEA0102`), port `serio0`, driver `atkbd`.
* **Function Hotkeys (`Ideapad extra buttons`):** ACPI device `VPC2004:00` (`\_SB.PCI0.LPC0.EC0_.VPC0`), driver `ideapad_laptop` + `lenovo_wmi_hotkey_utilities`.

**Why does it fail upon waking from `s2idle`?**
1. When entering `s2idle`, `atkbd_cleanup()` sends `0xF6` (*Reset and Disable Scanning*) to the PS/2 keyboard, and the ACPI method `\_SB.PEP_._DSM` (Function 7) writes `ECMO = 1` to the Embedded Controller (powering down the keyboard matrix and the `FnLock`/`NumLock`/`CapsLock` LED GPIOs).
2. Upon waking from `s2idle`, the EC returns to `ECMO = 0`. However, in the Linux kernel, `i8042_pm_resume()` checks whether the system suspended via legacy firmware `S3` (`PM_SUSPEND_FLAG_FW_SUSPEND`). Because `s2idle` is not `S3`, **`i8042_pm_resume()` exits immediately without reinitializing the `i8042` controller**.
3. Furthermore, aggressive kernel workarounds often suggested on forums—such as `i8042.dumbkbd=1` or `i8042.nopnp=1`—break the `IDEA0102`/`VPC2004:00` ACPI binding or block EC commands, breaking `Fn` hotkeys and `FnLock` LEDs.

---

## Repository Contents & What Gets Installed

| Repository File | Target System Path | Purpose |
| :--- | :--- | :--- |
| `install.sh` | *(Installer)* | Safely backs up existing configs to `./backups/` and applies all fixes without overwriting your system UUIDs. |
| `uninstall.sh` | *(Uninstaller)* | Reverts all changes and restores your original system configuration from `./backups/`. |
| `check-status.sh` | *(Diagnostics)* | Verifies kernel parameters, keyboard/`FnLock` state, PCI power states, battery mode, and AMD PMC `S0i3` residency. |
| `ssdt11_patched.aml` (`ssdt11_patched.dsl`) | `/etc/acpi/tables/ssdt11.aml` | Standalone 120-byte supplemental ACPI SSDT table (`FixSNTM`) that bridges `\_SB.PC00.LPCB.EC0_.SNTM` to `\_SB.PCI0.LPC0.EC0_.SNTM` across BIOS versions. |
| `99-ideapad-acpi-override.conf` | `/etc/dracut.conf.d/99-ideapad-acpi-override.conf` | Configures `dracut` to inject `/etc/acpi/tables/ssdt11.aml` into the initramfs early CPIO archive (non-dracut distros use `/boot/acpi_override.cpio`). |
| `99-ideapad-kbd-fn-resume.sh` | `/usr/lib/systemd/system-sleep/99-ideapad-kbd-fn-resume.sh` | Pre-suspend: saves `fn_lock` and transitions unbound AMD ACP (`1022:15e2`) to `D3hot`. Post-resume: waits `0.5s` for `ECMO=0`, triggers `reconnect` on `i8042/serio*`, and restores `fn_lock`. |
| `ideapad-laptop.conf` | `/etc/modprobe.d/ideapad-laptop.conf` | Sets `options ideapad_laptop set_fn_lock_led=1` and blacklists `snd_rn_pci_acp3x` so the unused ACP coprocessor isn't left in `D0`. |
| `99-ideapad-power-save.rules` | `/etc/udev/rules.d/99-ideapad-power-save.rules` | Sets `power/control="auto"` on AMD ACP (`1022:15e2`) & Genesys SD reader (`17a0:975*`), and disables spurious wakeups on PCIe bridge `0000:00:02.1` & Logitech USB receivers. |
| `lenovo-battery.service` | `/etc/systemd/system/lenovo-battery.service` | Enables Lenovo's ~80% Battery Conservation Mode at boot using either `/sys/class/power_supply/BAT*/charge_types` (`Long_Life`) or `VPC2004:*/conservation_mode`. |

---

## Requirements

* **Lenovo IdeaPad laptop with an AMD Ryzen APU** (the ACPI/`S0i3` fixes target AMD platforms; Intel models are detected automatically and the ACPI override is skipped).
* **Linux with systemd** (Fedora, RHEL, Ubuntu, Debian, Arch, openSUSE, etc.).
* **Root privileges** (`sudo`) to install kernel parameters, ACPI tables, udev rules, and systemd units.
* **Python 3** (used for safe config editing and non-dracut early-initrd generation; present by default on mainstream distributions).
* **Modern Standby (`S0i2` + `S0i3`) enabled in the UEFI/BIOS** for hardware deep-sleep residency.
* Standard kernel drivers: `amd_pmc`, `ideapad_laptop`, `i8042`, and `atkbd`.

> **Safety notice:** This project modifies ACPI tables, kernel command-line parameters, udev rules, and systemd services. Review the scripts before running them. The installer backs up every modified system file to `./backups/`, and `uninstall.sh` restores them. Use at your own risk.

---

## Quick Start & Usage

### 1. Clone the Repository
```bash
git clone https://github.com/aesthezel/lenovo-ideapad-power-fix.git
cd lenovo-ideapad-power-fix
```

### 2. Run the Installer
```bash
sudo ./install.sh
```
*(Optional flags: `--skip-acpi`, `--skip-battery`, `--skip-bootloader`, `--force`, `--help`)*

The installer validates the system vendor (Lenovo) and CPU vendor (AMD) before making changes. It also scans the firmware ACPI tables and only installs the `SNTM` bridge when the erroneous `PC00.LPCB.EC0.SNTM` reference is actually present. It backs up every system file it modifies to `./backups/` on the first run, edits existing kernel command-line UUIDs in place (it never overwrites your LUKS/root UUIDs), and auto-detects `dracut`, `initramfs-tools`, `mkinitcpio`, `grubby`, `kernelstub`, and `/etc/kernel/cmdline`.

Then **reboot your laptop** so the updated kernel parameters and early ACPI SSDT override take effect.

**Bootloader / initramfs notes:**
* **GRUB + `dracut`** (Fedora/RHEL/openSUSE): the ACPI table is injected automatically via `/etc/dracut.conf.d/99-ideapad-acpi-override.conf`.
* **GRUB + `initramfs-tools` or `mkinitcpio`** (Debian/Ubuntu/Arch): the installer generates `/boot/acpi_override.cpio` and sets `GRUB_EARLY_INITRD_LINUX_CUSTOM` so GRUB prepends it as an early initrd.
* **systemd-boot / UKI**: kernel parameters are updated in `/etc/kernel/cmdline`. If your bootloader does not load GRUB early initrds, add `/boot/acpi_override.cpio` as an additional initrd for your entry, or use `--skip-acpi` if your firmware does not expose the `SNTM` bug.

### 3. Verify System & `S0i3` Status
After rebooting, suspend your laptop for ~30 seconds, wake it up using the internal keyboard, and run:
```bash
sudo ./check-status.sh
```
Check section **5 (`AMD PMC S0i3 HARDWARE SLEEP STATISTICS`)**:
* `Last S0i3 Status` should report `Success` (or `Time (in us) in S0i3` > `0`).
* The `ACPI BIOS Error (bug): Could not resolve symbol [\_SB.PC00.LPCB.EC0.SNTM]` message will no longer appear in `dmesg`.
* Both the internal keyboard and `Fn` / `FnLock` keys will work immediately after waking.

### 4. Temporarily Toggle 80% Battery Conservation Mode
If you need to charge your battery to 100% before traveling, simply stop the service:
```bash
sudo systemctl stop lenovo-battery.service
```
To re-enable the 80% limit (`Long_Life`):
```bash
sudo systemctl start lenovo-battery.service
```

### 5. Uninstall / Rollback
To revert all changes and restore your original system files from `./backups/`:
```bash
sudo ./uninstall.sh
```

---

## Auditing or Rebuilding the ACPI SSDT Bridge (`ssdt11_patched.aml`)

Unlike full-table BIOS overrides that break when you update your BIOS, `ssdt11_patched.aml` is a tiny (120-byte) supplemental SSDT table (`OEM Table ID: FixSNTM`) that simply defines the missing `\_SB.PC00.LPCB.EC0_.SNTM` method and forwards calls to `\_SB.PCI0.LPC0.EC0_.SNTM`.

This bridge is only needed on firmware that contains the wrong `\_SB.PC00.LPCB.EC0_.SNTM` reference (such as BIOS `KYCN40WW` on the `82XM` platform). The installer scans the firmware ACPI tables and skips this component automatically when the reference is absent; you can also force it with `sudo ./install.sh --skip-acpi`.

The full human-readable ASL source is provided in [`ssdt11_patched.dsl`](./ssdt11_patched.dsl). If you wish to recompile it yourself using ACPICA's `iasl` compiler:
```bash
iasl -tc ssdt11_patched.dsl
```

---

## License

Released under the [MIT License](./LICENSE).

This project is unofficial and is not affiliated with, endorsed by, or sponsored by Lenovo. Lenovo and IdeaPad are trademarks of their respective owners.
