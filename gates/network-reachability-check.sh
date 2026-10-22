#!/usr/bin/env bash
# ============================================================================
# network-reachability-check.sh — NETWORK-REACHABILITY GATE (GATE-095)   [qg G170]
# ============================================================================
# deklaracja testow lacznosci z regionow/sieci. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/network-reachability-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-095 NETWORK-REACHABILITY (INFRA) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G170" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod NETWORK-REACHABILITY znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-095 dowod deklaracji" BLOCKING "Brak dowodu implementacji NETWORK-REACHABILITY (G170) w kanonicznych artefaktach."
  evidence_record "verify:network-reachability:FAIL" "verify" "network-reachability-check.sh"
  verify_module_exit
fi

pass "GATE-095 NETWORK-REACHABILITY calosc" BLOCKING "Kanoniczny dowod NETWORK-REACHABILITY (G170) obecny."
evidence_record "verify:network-reachability:PASS" "verify" "network-reachability-check.sh"
verify_module_exit
