#!/usr/bin/env bash
# ============================================================================
# maintenance-comms-check.sh — MAINTENANCE-COMMS GATE (GATE-116)   [qg G259]
# ============================================================================
# komunikaty o planowanej niedostepnosci/incydencie. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/maintenance-comms-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-116 MAINTENANCE-COMMS (COMPLIANCE) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G259" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod MAINTENANCE-COMMS znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-116 dowod deklaracji" BLOCKING "Brak dowodu implementacji MAINTENANCE-COMMS (G259) w kanonicznych artefaktach."
  evidence_record "verify:maintenance-comms:FAIL" "verify" "maintenance-comms-check.sh"
  verify_module_exit
fi

pass "GATE-116 MAINTENANCE-COMMS calosc" BLOCKING "Kanoniczny dowod MAINTENANCE-COMMS (G259) obecny."
evidence_record "verify:maintenance-comms:PASS" "verify" "maintenance-comms-check.sh"
verify_module_exit
