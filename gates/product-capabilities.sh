#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/product-capabilities.sh — adapter osi A (hook-runner / GATE-144)
#
#  Kontrakt hook-runner.sh: uruchamia bramki WYŁĄCZNIE jako tools/gates/<id>.sh.
#  Ten plik to cienki SHIM — zero duplikacji logiki: kanoniczna implementacja
#  żyje w tools/verify/gates/domains/product-capabilities.sh.
#
#  GATE-144 (2026-10-01): rejestr capability produktowych
#  (config/canonical/product-capabilities.yaml). Powstał razem z rejestracją
#  ha.mesh.ensure + backup.dr.ensure na rozkaz Suwerena ("jeśli nie jest
#  zarejestrowane to trzeba zarejestrować, dopisać co trzeba").
#
#  Kontrakt: exit 0 = PASS/WARN, exit 1 = FAIL, exit 2 = DEFER/DEFEKT-POMIARU.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/gates/domains/product-capabilities.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL product-capabilities (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
