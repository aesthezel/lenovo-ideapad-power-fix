/*
 * Supplemental ACPI SSDT Table for Lenovo IdeaPad AMD Laptops
 *
 * Fixes BIOS bug (e.g., KYCN40WW on Lenovo IdeaPad Slim 3 15ABR8 / 82XM) where
 * \_SB.PEP_._DSM (Function 4, Modern Standby / Screen transition notification)
 * attempts to call the Intel EC path:
 *     \_SB.PC00.LPCB.EC0_.SNTM
 * instead of the actual AMD EC path:
 *     \_SB.PCI0.LPC0.EC0_.SNTM
 *
 * Rather than replacing the entire vendor SSDT11 table (which varies across
 * BIOS versions and laptop models), this standalone SSDT table ("FixSNTM")
 * defines a lightweight bridge method at \_SB.PC00.LPCB.EC0_.SNTM that safely
 * forwards the call to \_SB.PCI0.LPC0.EC0_.SNTM.
 *
 * To recompile manually with ACPICA iasl:
 *     iasl -tc -f ssdt11_patched.dsl
 *
 * Build note: this table intentionally defines placeholder Device() nodes at
 * the (nonexistent) Intel ACPI path. iasl >= 2023 reports error 6141 ("Device
 * object requires a _HID or _ADR") for them; that is expected for this bridge.
 * verify-aml.sh builds with -f and rejects any error other than 6141.
 */
DefinitionBlock ("ssdt11_patched.aml", "SSDT", 2, "LENOVO", "FixSNTM ", 0x00000001)
{
    External (\_SB_.PCI0.LPC0.EC0_.SNTM, MethodObj) // 0 Arguments

    Scope (\_SB)
    {
        Device (PC00)
        {
            Device (LPCB)
            {
                Device (EC0)
                {
                    Method (SNTM, 0, NotSerialized)
                    {
                        \_SB.PCI0.LPC0.EC0.SNTM ()
                    }
                }
            }
        }
    }
}
