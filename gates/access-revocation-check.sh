#!/usr/bin/env bash
# ============================================================================
# access-revocation-check.sh — ACCESS-REVOCATION GATE (GATE-093)   [qg G059]
# ============================================================================
# deklaracja procesu cofania uprawnien/blokady konta. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/access-revocation-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-093 ACCESS-REVOCATION (SECURITY) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G059" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod ACCESS-REVOCATION znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-093 dowod deklaracji" BLOCKING "Brak dowodu implementacji ACCESS-REVOCATION (G059) w kanonicznych artefaktach."
  evidence_record "verify:access-revocation:FAIL" "verify" "access-revocation-check.sh"
  verify_module_exit
fi

pass "GATE-093 ACCESS-REVOCATION calosc" BLOCKING "Kanoniczny dowod ACCESS-REVOCATION (G059) obecny."
evidence_record "verify:access-revocation:PASS" "verify" "access-revocation-check.sh"
verify_module_exit
