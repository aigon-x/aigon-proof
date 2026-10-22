#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/runtime-lock-discipline.sh — delegat triggera GATE-145
#
#  PO CO: hook-runner.sh uruchamia bramki WYŁĄCZNIE jako tools/gates/<id>.sh,
#  gdzie <id> = NAZWA KOMENDY z gate-registry.yaml bez .sh (tak liczy
#  gate-reachability). Kanoniczna implementacja żyje na osi verify:
#  tools/verify/gates/domains/runtime-lock-discipline.sh.
#  Ten plik to CIENKI SHIM — zero duplikacji logiki.
#
#  GATE-145 (2026-10-03, ROZKAZ SUWERENA „defekty z sesji muszą być bramkami”):
#  (A) WZORZEC w kodzie: write lock trzymany przez await I/O bez timeout,
#  (B) ŻYWE metryki: aigon_lock_write_hold_seconds{tick_max/acquire_max},
#      aigon_tick_wedged_total, aigon_metrics_snapshot_age_seconds,
#  (C) ŚWIEŻOŚĆ snapshotu /health (defekt #2: stale snapshot przy write locku).
#
#  Kontrakt (zgodny z hook-runner.sh): 0 = PASS, 1 = FAIL, 2 = WARN.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMPL="$ROOT/tools/verify/gates/domains/runtime-lock-discipline.sh"

if [ ! -f "$IMPL" ]; then
  echo "runtime-lock-discipline: brak implementacji $IMPL (FAIL — brak dowodu nie jest PASS)" >&2
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$IMPL" "$@"
