#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# tools/gates/revenue-gate.sh — GATE: revenue-gate (pieniądze)
# Cienki wrapper: kanoniczna implementacja żyje w tools/revenue/revenue_gate.py
# (jeden silnik, zero duplikacji logiki).
#
# Po co: przychód był jedyną metryką, której nikt nie mierzył (monai_revenue_usd
# = NaN). Ta bramka wymusza fail-closed: brak instrumentacji = FAIL/NULL,
# nigdy fałszywe zero.
#
# Użycie: revenue-gate.sh [--selftest|--json]
# Kontrakt hook-runner: exit 0 = PASS, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="/srv/aigon"
ENGINE="$ROOT/tools/revenue/revenue_gate.py"
SNAP="$ROOT/tools/revenue/snapshot-monai-20261018.json"
REG="$ROOT/tools/revenue/product-registry.json"

if [ ! -f "$ENGINE" ]; then
  echo "FAIL: brak silnika $ENGINE"
  echo "=== RESULT === FAIL"
  exit 1
fi

case "${1:-}" in
  --selftest)
    python3 "$ENGINE" --selftest
    rc=$?
    ;;
  --json)
    python3 "$ENGINE" --snapshot "$SNAP" --registry "$REG" --format json
    rc=$?
    ;;
  *)
    python3 "$ENGINE" --snapshot "$SNAP" --registry "$REG"
    rc=$?
    ;;
esac

if [ "$rc" -eq 0 ]; then echo "=== RESULT === PASS"; else echo "=== RESULT === FAIL — przychód nieinstrumentowany albo poniżej progu"; fi
exit "$rc"
