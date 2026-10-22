#!/usr/bin/env bash
# ============================================================================
# backpressure-check.sh — BACKPRESSURE GATE (GATE-101)   [qg G138]
# ============================================================================
# backpressure chroni konsumentow przed przeciazeniem. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/backpressure-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-101 BACKPRESSURE (MESSAGING) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G138" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod BACKPRESSURE znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-101 dowod deklaracji" BLOCKING "Brak dowodu implementacji BACKPRESSURE (G138) w kanonicznych artefaktach."
  evidence_record "verify:backpressure:FAIL" "verify" "backpressure-check.sh"
  verify_module_exit
fi

pass "GATE-101 BACKPRESSURE calosc" BLOCKING "Kanoniczny dowod BACKPRESSURE (G138) obecny."
evidence_record "verify:backpressure:PASS" "verify" "backpressure-check.sh"
verify_module_exit
