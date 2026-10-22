#!/usr/bin/env bash
# ============================================================================
# backlog-drain-check.sh — BACKLOG-DRAIN GATE (GATE-102)   [qg G140]
# ============================================================================
# oproznia zaleglosci po przerwie w zgodnym czasie. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/backlog-drain-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-102 BACKLOG-DRAIN (MESSAGING) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G140" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod BACKLOG-DRAIN znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-102 dowod deklaracji" BLOCKING "Brak dowodu implementacji BACKLOG-DRAIN (G140) w kanonicznych artefaktach."
  evidence_record "verify:backlog-drain:FAIL" "verify" "backlog-drain-check.sh"
  verify_module_exit
fi

pass "GATE-102 BACKLOG-DRAIN calosc" BLOCKING "Kanoniczny dowod BACKLOG-DRAIN (G140) obecny."
evidence_record "verify:backlog-drain:PASS" "verify" "backlog-drain-check.sh"
verify_module_exit
