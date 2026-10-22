#!/usr/bin/env bash
# ============================================================================
# legal-current-check.sh — LEGAL-CURRENT GATE (GATE-117)   [qg G217]
# ============================================================================
# regulaminy/ToS/komunikaty prawne aktualne. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/legal-current-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-117 LEGAL-CURRENT (COMPLIANCE) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G217" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod LEGAL-CURRENT znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-117 dowod deklaracji" BLOCKING "Brak dowodu implementacji LEGAL-CURRENT (G217) w kanonicznych artefaktach."
  evidence_record "verify:legal-current:FAIL" "verify" "legal-current-check.sh"
  verify_module_exit
fi

pass "GATE-117 LEGAL-CURRENT calosc" BLOCKING "Kanoniczny dowod LEGAL-CURRENT (G217) obecny."
evidence_record "verify:legal-current:PASS" "verify" "legal-current-check.sh"
verify_module_exit
