#!/usr/bin/env bash
# ============================================================================
# spike-degradation-check.sh — SPIKE-DEGRADATION GATE (GATE-105)   [qg G114]
# ============================================================================
# skokowy wzrost ruchu bez niekontrolowanej degradacji. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/spike-degradation-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-105 SPIKE-DEGRADATION (PERFORMANCE) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G114" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod SPIKE-DEGRADATION znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-105 dowod deklaracji" BLOCKING "Brak dowodu implementacji SPIKE-DEGRADATION (G114) w kanonicznych artefaktach."
  evidence_record "verify:spike-degradation:FAIL" "verify" "spike-degradation-check.sh"
  verify_module_exit
fi

pass "GATE-105 SPIKE-DEGRADATION calosc" BLOCKING "Kanoniczny dowod SPIKE-DEGRADATION (G114) obecny."
evidence_record "verify:spike-degradation:PASS" "verify" "spike-degradation-check.sh"
verify_module_exit
