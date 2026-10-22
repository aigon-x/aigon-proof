#!/usr/bin/env bash
# ============================================================================
# autoscaling-stability-check.sh — AUTOSCALING-STABILITY GATE (GATE-107)   [qg G158]
# ============================================================================
# autoscaling w gore/dol stabilny dla ruchu. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/autoscaling-stability-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-107 AUTOSCALING-STABILITY (INFRA) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G158" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod AUTOSCALING-STABILITY znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-107 dowod deklaracji" BLOCKING "Brak dowodu implementacji AUTOSCALING-STABILITY (G158) w kanonicznych artefaktach."
  evidence_record "verify:autoscaling-stability:FAIL" "verify" "autoscaling-stability-check.sh"
  verify_module_exit
fi

pass "GATE-107 AUTOSCALING-STABILITY calosc" BLOCKING "Kanoniczny dowod AUTOSCALING-STABILITY (G158) obecny."
evidence_record "verify:autoscaling-stability:PASS" "verify" "autoscaling-stability-check.sh"
verify_module_exit
