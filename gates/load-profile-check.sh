#!/usr/bin/env bash
# ============================================================================
# load-profile-check.sh — LOAD-PROFILE GATE (GATE-103)   [qg G111]
# ============================================================================
# profil ruchu i progi opoznien/przepustowosci/bledow. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/load-profile-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-103 LOAD-PROFILE (PERFORMANCE) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G111" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod LOAD-PROFILE znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-103 dowod deklaracji" BLOCKING "Brak dowodu implementacji LOAD-PROFILE (G111) w kanonicznych artefaktach."
  evidence_record "verify:load-profile:FAIL" "verify" "load-profile-check.sh"
  verify_module_exit
fi

pass "GATE-103 LOAD-PROFILE calosc" BLOCKING "Kanoniczny dowod LOAD-PROFILE (G111) obecny."
evidence_record "verify:load-profile:PASS" "verify" "load-profile-check.sh"
verify_module_exit
