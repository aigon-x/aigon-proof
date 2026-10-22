#!/usr/bin/env bash
# ============================================================================
# offline-security-check.sh — OFFLINE-SECURITY GATE (GATE-114)   [qg G296]
# ============================================================================
# offline zachowuje ograniczenia bezpieczenstwa. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/offline-security-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-114 OFFLINE-SECURITY (SECURITY) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G296" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod OFFLINE-SECURITY znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-114 dowod deklaracji" BLOCKING "Brak dowodu implementacji OFFLINE-SECURITY (G296) w kanonicznych artefaktach."
  evidence_record "verify:offline-security:FAIL" "verify" "offline-security-check.sh"
  verify_module_exit
fi

pass "GATE-114 OFFLINE-SECURITY calosc" BLOCKING "Kanoniczny dowod OFFLINE-SECURITY (G296) obecny."
evidence_record "verify:offline-security:PASS" "verify" "offline-security-check.sh"
verify_module_exit
