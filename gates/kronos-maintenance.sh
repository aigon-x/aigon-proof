#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/kronos-maintenance.sh — adapter osi A (hook-runner / GATE-143)
#
#  Kontrakt hook-runner.sh: uruchamia bramki WYŁĄCZNIE jako tools/gates/<id>.sh.
#  Ten plik to cienki SHIM — zero duplikacji logiki: kanoniczna implementacja
#  żyje w tools/verify/gates/domains/kronos-maintenance.sh.
#
#  DLACZEGO POWSTAŁ (defekt zmierzony 2026-10-01):
#    hooks.yaml (cyclic:6h) wpinał bramkę `kronos-maintenance` (GATE-143) i wpis
#    był w gate-registry.yaml, ale tools/gates/<id>.sh NIE ISTNIAŁ — dokładnie ta
#    sama klasa defektu co GATE-140 `skill-distribution` (shim brak → hook-runner
#    zwraca WARN, bramka NIGDY nie mierzona). Wykryte przez reconcile-gate-wiring
#    (bez_wrappera=1).
#
#  Kontrakt: exit 0 = PASS/WARN, exit 1 = FAIL, exit 2 = DEFER/DEFEKT-POMIARU.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/gates/domains/kronos-maintenance.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL kronos-maintenance (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
