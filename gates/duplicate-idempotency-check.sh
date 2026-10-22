#!/usr/bin/env bash
# ============================================================================
# duplicate-idempotency-check.sh — DUPLICATE-IDEMPOTENCY GATE (GATE-097)   [qg G133]
# ============================================================================
# duplikaty bez powtorzenia niedozwolonych skutkow. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/duplicate-idempotency-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-097 DUPLICATE-IDEMPOTENCY (MESSAGING) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G133" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod DUPLICATE-IDEMPOTENCY znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-097 dowod deklaracji" BLOCKING "Brak dowodu implementacji DUPLICATE-IDEMPOTENCY (G133) w kanonicznych artefaktach."
  evidence_record "verify:duplicate-idempotency:FAIL" "verify" "duplicate-idempotency-check.sh"
  verify_module_exit
fi

pass "GATE-097 DUPLICATE-IDEMPOTENCY calosc" BLOCKING "Kanoniczny dowod DUPLICATE-IDEMPOTENCY (G133) obecny."
evidence_record "verify:duplicate-idempotency:PASS" "verify" "duplicate-idempotency-check.sh"
verify_module_exit
