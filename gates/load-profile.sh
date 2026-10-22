#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/load-profile.sh — adapter osi A (hook-runner / moduł gates.yaml "load-profile")
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja modułu
#  "load-profile" (config/canonical/gates.yaml) żyje w tools/verify/load-profile-check.sh.
#  Ten plik przekazuje sterowanie do kanonicznego źródła — JEDNA implementacja.
#
#  PO CO: moduł "load-profile" był SIEROTĄ (brak triggera w hooks.yaml/cron.yaml):
#  napisany, ale NIGDY niewołany (defekt klasy „napisane bez wpięcia").
#  Wpięty na osi A przez config/canonical/hooks.yaml (trigger cyclic:daily).
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/load-profile-check.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL load-profile (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
