#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/obs-health.sh — adapter osi A (hook-runner / moduł gates.yaml "obs-health")
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja modułu
#  "obs-health" (config/canonical/gates.yaml) żyje w tools/verify/obs-health-endpoints.sh.
#  Ten plik przekazuje sterowanie do kanonicznego źródła — JEDNA implementacja.
#
#  PO CO: moduł "obs-health" był SIEROTĄ (brak triggera w hooks.yaml/cron.yaml):
#  napisany, ale NIGDY niewołany (defekt klasy „napisane bez wpięcia").
#  Wpięty na osi A przez config/canonical/hooks.yaml (trigger cyclic:15m).
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/obs-health-endpoints.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL obs-health (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
