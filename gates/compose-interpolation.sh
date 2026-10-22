#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/compose-interpolation.sh — gate compose-interpolation
#
#  Runtime:deploy — docker compose config parses bez błędów
#  interpolacji/typowania (wykrywa ${VAR} bez wartości, typy portów itd.).
#  Wymaga docker (deploy = root). Brak docker = FAIL (fail-closed).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "FAIL compose-interpolation: docker niedostępny"
  exit 1
fi

OUT=$(cd "$ROOT" && docker compose config --quiet 2>&1); RC=$?
if [ $RC -eq 0 ]; then
  echo "PASS compose-interpolation: docker compose config --quiet OK"
  exit 0
fi
echo "FAIL compose-interpolation: $(echo "$OUT" | head -5 | tr '\n' ' ')"
exit 1
