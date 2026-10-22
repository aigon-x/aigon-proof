#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/system-twin.sh — gate system-twin (hook-runner / GATE-021)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja GATE-021
#  żyje w tools/verify/gates/domains/system-twin.sh. Ten plik przekazuje
#  sterowanie do kanonicznego źródła, więc istnieje JEDNA implementacja.
#
#  PO CO: GATE-021 (SYSTEM-TWIN, critical, blocking) był osiągalny tylko
#  przez `verify.sh gates` (GitHub Actions) — nie odpalał się ani z hooków
#  git, ani z crona. Wpięcie w cyclic:hourly daje kontrolę stanu grafu
#  co godzinę na LOCAL, a nie wyłącznie przy pushu do CI.
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/gates/domains/system-twin.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL system-twin (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
