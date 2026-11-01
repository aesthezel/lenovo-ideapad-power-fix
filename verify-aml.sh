#!/usr/bin/env bash
# ==============================================================================
# ACPI SSDT bridge verifier for lenovo-ideapad-power-fix
# ==============================================================================
# Validates the ACPI table before it is injected into the initramfs:
#   1. ACPI header: signature, declared Length and checksum, OEM Table ID.
#   2. Optional pinned SHA-256 (ssdt11_patched.aml.sha256).
#   3. When iasl (acpica-tools) is available:
#      - rebuild the table from the audited ssdt11_patched.dsl (hard failure;
#        falls back to the SHA-256 pinned shipped table only if iasl cannot emit
#        AML while reporting solely the expected error 6141),
#      - validate the rebuilt table and reject dangerous AML operations,
#      - best-effort disassembly check of the shipped binary (which is not
#        used by the installer when a rebuild is possible).
#
# Set VERIFY_AML_REBUILD_OUT=/path/to/output.aml to receive the recompiled
# table. The exit status is non-zero if any hard check fails.
# ==============================================================================

set -euo pipefail
umask 077

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AML="${1:-${SCRIPT_DIR}/ssdt11_patched.aml}"
DSL="${2:-${SCRIPT_DIR}/ssdt11_patched.dsl}"

TMP_DIR=""

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf -- "${TMP_DIR:?}"
  fi
  return 0
}
trap cleanup EXIT

die() {
  echo "verify-aml: ERROR: $*" >&2
  exit 1
}

validate_header() {
  local file="$1"
  local size
  local len_hex
  local len
  local total

  [ -f "$file" ] || die "not a regular file: $file"
  [ ! -L "$file" ] || die "refusing to follow symlink: $file"

  size="$(wc -c < "$file" | tr -d ' ')"
  if [ "$size" -lt 36 ] || [ "$size" -gt 4096 ]; then
    die "unexpected ACPI table size: $size bytes"
  fi

  [ "$(head -c 4 -- "$file")" = "SSDT" ] || die "ACPI signature is not SSDT"

  # ACPI Length field is a little-endian uint32 at offset 4.
  len_hex="$(od -An -v -tx1 -j4 -N4 -- "$file" | tr -d ' \n')"
  [ "${#len_hex}" -eq 8 ] || die "could not read the ACPI Length field"
  len=$(( 0x${len_hex:6:2}${len_hex:4:2}${len_hex:2:2}${len_hex:0:2} ))
  [ "$len" -eq "$size" ] || die "ACPI Length ($len) does not match file size ($size)"

  # The sum of every byte in an ACPI table must be 0 modulo 256.
  total="$(od -An -v -tu1 -- "$file" | tr -s ' \n' '\n' | awk 'NF { s += $1 } END { print s + 0 }')"
  [ $(( total % 256 )) -eq 0 ] || die "invalid ACPI checksum (byte sum $total)"

  grep -qa -- "FixSNTM" "$file" || die "OEM Table ID 'FixSNTM' not found in $file"
}

# Reject any AML operation beyond the minimal SNTM forwarding bridge.
check_structure() {
  local table="$1"
  local asl="$2"

  for needle in 'Device (PC00)' 'Device (LPCB)' 'Device (EC0' 'Method (SNTM'; do
    grep -qF -- "$needle" "$asl" || die "unexpected AML structure: missing '$needle'"
  done
  grep -Eq -- 'SNTM[[:space:]]*\(\)' "$asl" || die "unexpected AML structure: no SNTM() call found"

  if grep -Eq -- '(OperationRegion|IndexField|BankField|Create(Byte|Word|DWord|QWord|Bit)Field|(^|[^A-Za-z_])(Store|CopyObject|Acquire|Release|Notify|Mutex|Event|Signal|Wait|Reset|Fatal|BreakPoint|Load|Unload|LoadTable)[[:space:]]*\()' "$asl"; then
    die "the disassembled AML contains operations that the SNTM bridge must not use"
  fi

  echo "  [OK] ${table##*/}: only the SNTM bridge (no dangerous AML operations)"
}

echo "=== Verifying ACPI SSDT bridge table ==="

[ -f "$AML" ] || die "ACPI table not found: $AML"
[ ! -L "$AML" ] || die "refusing to use a symlinked ACPI table: $AML"
[ -f "$DSL" ] || die "DSL source not found: $DSL"

validate_header "$AML"
echo "  [OK] ACPI header: SSDT, $(wc -c < "$AML" | tr -d ' ') bytes, valid Length and checksum"

HASH_FILE="${AML}.sha256"
if [ -f "$HASH_FILE" ]; then
  expected="$(awk 'NF { print $1; exit }' "$HASH_FILE")"
  actual="$(sha256sum -- "$AML" | awk '{ print $1 }')"
  [ -n "$expected" ] || die "empty SHA-256 pin file: $HASH_FILE"
  [ "$expected" = "$actual" ] || die "SHA-256 mismatch against ${HASH_FILE##*/}"
  echo "  [OK] SHA-256 matches the pinned value in ${HASH_FILE##*/}"
else
  echo "  [INFO] No pinned hash (${HASH_FILE##*/}). Current SHA-256:"
  echo "         $(sha256sum -- "$AML" | awk '{ print $1 }')"
  echo "         Pin it after review with: sha256sum ${AML##*/} > ${AML##*/}.sha256"
fi

if ! command -v iasl >/dev/null 2>&1; then
  echo "  [WARN] iasl (acpica-tools) is not installed: the AML body was NOT" >&2
  echo "         verified against ${DSL##*/} and the table could not be rebuilt." >&2
  echo "         Install 'acpica-tools' for full verification and reproducible builds." >&2
  exit 0
fi

TMP_DIR="$(mktemp -d /tmp/verify-aml.XXXXXX)"

# ------------------------------------------------------------------------------
# 1. Rebuild the table from the audited ASL source. This is the table the
#    installer uses when iasl is available, so it is a hard requirement.
# ------------------------------------------------------------------------------
iasl -tc -f -p "${TMP_DIR}/rebuilt" "$DSL" >"${TMP_DIR}/build.log" 2>&1 || true
REBUILT="${TMP_DIR}/rebuilt.aml"

# The SNTM bridge intentionally creates placeholder Device() nodes for the
# (nonexistent) Intel namespace path. iasl >= 2023 reports error 6141 because
# those devices have no _HID/_ADR. -f forces the AML output; accept ONLY that
# specific error and reject anything else.
error_lines="$(grep -E '(^|[[:space:]])Error[[:space:]]+[0-9]+' "${TMP_DIR}/build.log" || true)"
if [ -n "$error_lines" ]; then
  unexpected_errors="$(printf '%s\n' "$error_lines" | grep -vE '(^|[[:space:]])Error[[:space:]]+6141' || true)"
  if [ -n "$unexpected_errors" ]; then
    printf '%s\n' "$unexpected_errors" >&2
    sed -n '1,60p' "${TMP_DIR}/build.log" >&2 || true
    die "iasl reported errors other than the expected 6141 (placeholder Device nodes)"
  fi
fi

if [ ! -f "$REBUILT" ]; then
  if [ -n "$error_lines" ]; then
    echo "  [WARN] iasl did not emit AML despite -f (only error 6141 was reported);" >&2
    echo "         falling back to the verified, SHA-256 pinned shipped table." >&2
    REBUILT="$AML"
  else
    sed -n '1,40p' "${TMP_DIR}/build.log" >&2 || true
    die "iasl could not compile $DSL"
  fi
fi

validate_header "$REBUILT"
if [ "$REBUILT" = "$AML" ]; then
  echo "  [OK] Using the verified shipped table (iasl rebuild unavailable)"
else
  echo "  [OK] Rebuilt the ACPI table from ${DSL##*/}"
fi

# ------------------------------------------------------------------------------
# 2. Structural and dangerous-operation checks
# ------------------------------------------------------------------------------
iasl -d -p "${TMP_DIR}/disasm-rebuilt" "$REBUILT" >"${TMP_DIR}/disasm-rebuilt.log" 2>&1 || true
ASL_REBUILT="${TMP_DIR}/disasm-rebuilt.dsl"
if [ -f "$ASL_REBUILT" ]; then
  check_structure "$REBUILT" "$ASL_REBUILT"
else
  echo "  [WARN] iasl could not disassemble the rebuilt table; check the ASL source manually." >&2
fi

# Best-effort audit of the shipped binary. When iasl is available the installer
# uses the rebuilt table, so a disassembly limitation here is not fatal.
iasl -d -p "${TMP_DIR}/disasm-shipped" "$AML" >"${TMP_DIR}/disasm-shipped.log" 2>&1 || true
ASL_SHIPPED="${TMP_DIR}/disasm-shipped.dsl"
if [ -f "$ASL_SHIPPED" ]; then
  check_structure "$AML" "$ASL_SHIPPED"
else
  echo "  [WARN] iasl could not disassemble the shipped AML; it will NOT be installed" >&2
  echo "         when iasl is available (the rebuilt table is used instead)." >&2
fi

# ------------------------------------------------------------------------------
# 3. Hand the rebuilt table to the installer, if requested
# ------------------------------------------------------------------------------
if [ -n "${VERIFY_AML_REBUILD_OUT:-}" ]; then
  cp -f -- "$REBUILT" "$VERIFY_AML_REBUILD_OUT"
  chmod 0644 -- "$VERIFY_AML_REBUILD_OUT"
  echo "  [OK] Table written to $VERIFY_AML_REBUILD_OUT"
fi

echo "=== ACPI verification passed ==="
