#!/usr/bin/env bash
# ============================================================================
# power-loss-update-check.sh — POWER-LOSS-UPDATE GATE (GATE-113)   [qg G295]
# ============================================================================
# przerwanie zasilania podczas aktualizacji. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/power-loss-update-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-113 POWER-LOSS-UPDATE (RESILIENCE) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G295" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod POWER-LOSS-UPDATE znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-113 dowod deklaracji" BLOCKING "Brak dowodu implementacji POWER-LOSS-UPDATE (G295) w kanonicznych artefaktach."
  evidence_record "verify:power-loss-update:FAIL" "verify" "power-loss-update-check.sh"
  verify_module_exit
fi

pass "GATE-113 POWER-LOSS-UPDATE calosc" BLOCKING "Kanoniczny dowod POWER-LOSS-UPDATE (G295) obecny."
evidence_record "verify:power-loss-update:PASS" "verify" "power-loss-update-check.sh"
verify_module_exit
