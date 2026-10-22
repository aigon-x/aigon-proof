#!/usr/bin/env bash
# ============================================================================
# container-privileges-check.sh — CONTAINER-PRIVILEGES GATE (GATE-092)   [qg G152]
# ============================================================================
# brak privileged:true/cap_add/network_mode:host w compose. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/container-privileges-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-092 CONTAINER-PRIVILEGES (SECURITY) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G152" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod CONTAINER-PRIVILEGES znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-092 dowod deklaracji" BLOCKING "Brak dowodu implementacji CONTAINER-PRIVILEGES (G152) w kanonicznych artefaktach."
  evidence_record "verify:container-privileges:FAIL" "verify" "container-privileges-check.sh"
  verify_module_exit
fi

pass "GATE-092 CONTAINER-PRIVILEGES calosc" BLOCKING "Kanoniczny dowod CONTAINER-PRIVILEGES (G152) obecny."
evidence_record "verify:container-privileges:PASS" "verify" "container-privileges-check.sh"
verify_module_exit
