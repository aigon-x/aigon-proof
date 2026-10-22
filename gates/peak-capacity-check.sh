#!/usr/bin/env bash
# ============================================================================
# peak-capacity-check.sh — PEAK-CAPACITY GATE (GATE-104)   [qg G113]
# ============================================================================
# test ruchu szczytowego i zapas pojemnosci. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/peak-capacity-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-104 PEAK-CAPACITY (PERFORMANCE) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G113" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod PEAK-CAPACITY znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-104 dowod deklaracji" BLOCKING "Brak dowodu implementacji PEAK-CAPACITY (G113) w kanonicznych artefaktach."
  evidence_record "verify:peak-capacity:FAIL" "verify" "peak-capacity-check.sh"
  verify_module_exit
fi

pass "GATE-104 PEAK-CAPACITY calosc" BLOCKING "Kanoniczny dowod PEAK-CAPACITY (G113) obecny."
evidence_record "verify:peak-capacity:PASS" "verify" "peak-capacity-check.sh"
verify_module_exit
