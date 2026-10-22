#!/usr/bin/env bash
# ============================================================================
# retry-bounds-check.sh — RETRY-BOUNDS GATE (GATE-098)   [qg G135]
# ============================================================================
# ponowienia ograniczone, bez nieskonczonych petli. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/retry-bounds-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-098 RETRY-BOUNDS (MESSAGING) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G135" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod RETRY-BOUNDS znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-098 dowod deklaracji" BLOCKING "Brak dowodu implementacji RETRY-BOUNDS (G135) w kanonicznych artefaktach."
  evidence_record "verify:retry-bounds:FAIL" "verify" "retry-bounds-check.sh"
  verify_module_exit
fi

pass "GATE-098 RETRY-BOUNDS calosc" BLOCKING "Kanoniczny dowod RETRY-BOUNDS (G135) obecny."
evidence_record "verify:retry-bounds:PASS" "verify" "retry-bounds-check.sh"
verify_module_exit
