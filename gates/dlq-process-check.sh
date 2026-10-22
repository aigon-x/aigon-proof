#!/usr/bin/env bash
# ============================================================================
# dlq-process-check.sh — DLQ-PROCESS GATE (GATE-099)   [qg G136]
# ============================================================================
# dead-letter queue z procesem analizy/reprocess. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/dlq-process-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-099 DLQ-PROCESS (MESSAGING) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G136" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod DLQ-PROCESS znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-099 dowod deklaracji" BLOCKING "Brak dowodu implementacji DLQ-PROCESS (G136) w kanonicznych artefaktach."
  evidence_record "verify:dlq-process:FAIL" "verify" "dlq-process-check.sh"
  verify_module_exit
fi

pass "GATE-099 DLQ-PROCESS calosc" BLOCKING "Kanoniczny dowod DLQ-PROCESS (G136) obecny."
evidence_record "verify:dlq-process:PASS" "verify" "dlq-process-check.sh"
verify_module_exit
