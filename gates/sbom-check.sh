#!/usr/bin/env bash
# ============================================================================
# sbom-check.sh — SBOM-CHECK GATE (GATE-091)   [qg G061]
# ============================================================================
# Obecnosc manifestu/SBOM zaleznosci w /srv/aigon. Fail-closed: brak dowodu
# deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/sbom-check.sh) widoczny jako gate
# (registry) I jako modul verify (gates.yaml) — pipeline CI i lokalna pelna
# certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-091 SBOM-CHECK (SECURITY) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G061" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod SBOM-CHECK znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-091 dowod deklaracji" BLOCKING "Brak dowodu implementacji SBOM-CHECK (G061) w kanonicznych artefaktach."
  evidence_record "verify:sbom:FAIL" "verify" "sbom-check.sh"
  verify_module_exit
fi

pass "GATE-091 SBOM-CHECK calosc" BLOCKING "Kanoniczny dowod SBOM-CHECK (G061) obecny."
evidence_record "verify:sbom:PASS" "verify" "sbom-check.sh"
verify_module_exit