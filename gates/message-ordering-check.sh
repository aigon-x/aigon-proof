#!/usr/bin/env bash
# ============================================================================
# message-ordering-check.sh — MESSAGE-ORDERING GATE (GATE-096)   [qg G107]
# ============================================================================
# obsluga zdarzen spoznionych/poza kolejnoscia. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/message-ordering-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-096 MESSAGE-ORDERING (MESSAGING) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G107" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod MESSAGE-ORDERING znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-096 dowod deklaracji" BLOCKING "Brak dowodu implementacji MESSAGE-ORDERING (G107) w kanonicznych artefaktach."
  evidence_record "verify:message-ordering:FAIL" "verify" "message-ordering-check.sh"
  verify_module_exit
fi

pass "GATE-096 MESSAGE-ORDERING calosc" BLOCKING "Kanoniczny dowod MESSAGE-ORDERING (G107) obecny."
evidence_record "verify:message-ordering:PASS" "verify" "message-ordering-check.sh"
verify_module_exit
