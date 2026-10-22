#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/cert-renewal.sh — adapter osi A (hook-runner / moduł gates.yaml "cert-renewal")
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja modułu
#  "cert-renewal" (config/canonical/gates.yaml) żyje w tools/verify/cert-renewal-check.sh.
#  Ten plik przekazuje sterowanie do kanonicznego źródła — JEDNA implementacja.
#
#  PO CO: moduł "cert-renewal" był SIEROTĄ (brak triggera w hooks.yaml/cron.yaml):
#  napisany, ale NIGDY niewołany (defekt klasy „napisane bez wpięcia").
#  Wpięty na osi A przez config/canonical/hooks.yaml (trigger cyclic:daily).
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/cert-renewal-check.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL cert-renewal (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
