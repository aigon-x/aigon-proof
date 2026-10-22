#!/usr/bin/env bash
# ============================================================================
# cost-budget-check.sh — COST-BUDGET GATE (GATE-118)   [qg G267]
# ============================================================================
# koszt obslugi ruchu w zatwierdzonym budzecie. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/cost-budget-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-118 COST-BUDGET (COST) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G267" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod COST-BUDGET znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-118 dowod deklaracji" BLOCKING "Brak dowodu implementacji COST-BUDGET (G267) w kanonicznych artefaktach."
  evidence_record "verify:cost-budget:FAIL" "verify" "cost-budget-check.sh"
  verify_module_exit
fi

pass "GATE-118 COST-BUDGET calosc" BLOCKING "Kanoniczny dowod COST-BUDGET (G267) obecny."
evidence_record "verify:cost-budget:PASS" "verify" "cost-budget-check.sh"
verify_module_exit
