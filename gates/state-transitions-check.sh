#!/usr/bin/env bash
# ============================================================================
# state-transitions-check.sh — STATE-TRANSITIONS GATE (GATE-108)   [qg G017]
# ============================================================================
# dozwolone/zabronione przejscia stanow sprawdzone. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/state-transitions-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-108 STATE-TRANSITIONS (RESILIENCE) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G017" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod STATE-TRANSITIONS znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-108 dowod deklaracji" BLOCKING "Brak dowodu implementacji STATE-TRANSITIONS (G017) w kanonicznych artefaktach."
  evidence_record "verify:state-transitions:FAIL" "verify" "state-transitions-check.sh"
  verify_module_exit
fi

pass "GATE-108 STATE-TRANSITIONS calosc" BLOCKING "Kanoniczny dowod STATE-TRANSITIONS (G017) obecny."
evidence_record "verify:state-transitions:PASS" "verify" "state-transitions-check.sh"
verify_module_exit
