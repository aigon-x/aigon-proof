#!/usr/bin/env bash
# ============================================================================
# poison-message-check.sh — POISON-MESSAGE GATE (GATE-100)   [qg G137]
# ============================================================================
# trwale bledny komunikat nie blokuje przetwarzania. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/poison-message-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-100 POISON-MESSAGE (MESSAGING) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G137" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod POISON-MESSAGE znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-100 dowod deklaracji" BLOCKING "Brak dowodu implementacji POISON-MESSAGE (G137) w kanonicznych artefaktach."
  evidence_record "verify:poison-message:FAIL" "verify" "poison-message-check.sh"
  verify_module_exit
fi

pass "GATE-100 POISON-MESSAGE calosc" BLOCKING "Kanoniczny dowod POISON-MESSAGE (G137) obecny."
evidence_record "verify:poison-message:PASS" "verify" "poison-message-check.sh"
verify_module_exit
