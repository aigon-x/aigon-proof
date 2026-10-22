#!/usr/bin/env bash
# ============================================================================
# cert-renewal-check.sh — CERT-RENEWAL GATE (GATE-094)   [qg G163]
# ============================================================================
# odnowienie certyfikatow TLS/ACME przetestowane i monitorowane. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/cert-renewal-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-094 CERT-RENEWAL (SECURITY) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G163" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod CERT-RENEWAL znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-094 dowod deklaracji" BLOCKING "Brak dowodu implementacji CERT-RENEWAL (G163) w kanonicznych artefaktach."
  evidence_record "verify:cert-renewal:FAIL" "verify" "cert-renewal-check.sh"
  verify_module_exit
fi

pass "GATE-094 CERT-RENEWAL calosc" BLOCKING "Kanoniczny dowod CERT-RENEWAL (G163) obecny."
evidence_record "verify:cert-renewal:PASS" "verify" "cert-renewal-check.sh"
verify_module_exit
