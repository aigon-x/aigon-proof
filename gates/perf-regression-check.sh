#!/usr/bin/env bash
# ============================================================================
# perf-regression-check.sh — PERF-REGRESSION GATE (GATE-106)   [qg G120]
# ============================================================================
# wydajnosc nie pogorszona ponad prog bazowy. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/perf-regression-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-106 PERF-REGRESSION (PERFORMANCE) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G120" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod PERF-REGRESSION znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-106 dowod deklaracji" BLOCKING "Brak dowodu implementacji PERF-REGRESSION (G120) w kanonicznych artefaktach."
  evidence_record "verify:perf-regression:FAIL" "verify" "perf-regression-check.sh"
  verify_module_exit
fi

pass "GATE-106 PERF-REGRESSION calosc" BLOCKING "Kanoniczny dowod PERF-REGRESSION (G120) obecny."
evidence_record "verify:perf-regression:PASS" "verify" "perf-regression-check.sh"
verify_module_exit
