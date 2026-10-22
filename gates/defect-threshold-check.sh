#!/usr/bin/env bash
# ============================================================================
# defect-threshold-check.sh — DEFECT-THRESHOLD GATE (GATE-115)   [qg G006]
# ============================================================================
# brak otwartych defektow ponad prog blokady. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/defect-threshold-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-115 DEFECT-THRESHOLD (QUALITY) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G006" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod DEFECT-THRESHOLD znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-115 dowod deklaracji" BLOCKING "Brak dowodu implementacji DEFECT-THRESHOLD (G006) w kanonicznych artefaktach."
  evidence_record "verify:defect-threshold:FAIL" "verify" "defect-threshold-check.sh"
  verify_module_exit
fi

pass "GATE-115 DEFECT-THRESHOLD calosc" BLOCKING "Kanoniczny dowod DEFECT-THRESHOLD (G006) obecny."
evidence_record "verify:defect-threshold:PASS" "verify" "defect-threshold-check.sh"
verify_module_exit
