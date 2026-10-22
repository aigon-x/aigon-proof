#!/usr/bin/env bash
# ============================================================================
# interrupt-resume-check.sh — INTERRUPT-RESUME GATE (GATE-109)   [qg G018]
# ============================================================================
# przerwanie/wznowienie/ponowienie bez zlego stanu. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/interrupt-resume-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-109 INTERRUPT-RESUME (RESILIENCE) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G018" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod INTERRUPT-RESUME znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-109 dowod deklaracji" BLOCKING "Brak dowodu implementacji INTERRUPT-RESUME (G018) w kanonicznych artefaktach."
  evidence_record "verify:interrupt-resume:FAIL" "verify" "interrupt-resume-check.sh"
  verify_module_exit
fi

pass "GATE-109 INTERRUPT-RESUME calosc" BLOCKING "Kanoniczny dowod INTERRUPT-RESUME (G018) obecny."
evidence_record "verify:interrupt-resume:PASS" "verify" "interrupt-resume-check.sh"
verify_module_exit
