#!/usr/bin/env bash
# ============================================================================
# offline-handling-check.sh — OFFLINE-HANDLING GATE (GATE-111)   [qg G244]
# ============================================================================
# obsluga braku sieci/slabego lacza/zmiany sieci. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/offline-handling-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-111 OFFLINE-HANDLING (RESILIENCE) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G244" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod OFFLINE-HANDLING znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-111 dowod deklaracji" BLOCKING "Brak dowodu implementacji OFFLINE-HANDLING (G244) w kanonicznych artefaktach."
  evidence_record "verify:offline-handling:FAIL" "verify" "offline-handling-check.sh"
  verify_module_exit
fi

pass "GATE-111 OFFLINE-HANDLING calosc" BLOCKING "Kanoniczny dowod OFFLINE-HANDLING (G244) obecny."
evidence_record "verify:offline-handling:PASS" "verify" "offline-handling-check.sh"
verify_module_exit
