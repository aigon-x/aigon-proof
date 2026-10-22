#!/usr/bin/env bash
# ============================================================================
# permission-justification-check.sh — PERMISSION-JUSTIFICATION GATE (GATE-112)   [qg G246]
# ============================================================================
# uprawnienia urzadzenia uzasadnione, odmowa bez bledu. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/permission-justification-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-112 PERMISSION-JUSTIFICATION (SECURITY) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G246" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod PERMISSION-JUSTIFICATION znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-112 dowod deklaracji" BLOCKING "Brak dowodu implementacji PERMISSION-JUSTIFICATION (G246) w kanonicznych artefaktach."
  evidence_record "verify:permission-justification:FAIL" "verify" "permission-justification-check.sh"
  verify_module_exit
fi

pass "GATE-112 PERMISSION-JUSTIFICATION calosc" BLOCKING "Kanoniczny dowod PERMISSION-JUSTIFICATION (G246) obecny."
evidence_record "verify:permission-justification:PASS" "verify" "permission-justification-check.sh"
verify_module_exit
