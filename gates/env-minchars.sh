#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/env-minchars.sh — gate env-minchars
#
#  Runtime:deploy — kontener ma AIGON_OUTPUT_MIN_CHARS=1 (P0-fix:
#  bez tego modele myślące zwracają puste odpowiedzi / ucięte tool calle).
#  Wymaga docker (deploy = root). Brak docker = FAIL (fail-closed).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "FAIL env-minchars: docker niedostępny"
  exit 1
fi

if ! docker inspect aigon-core-runtime >/dev/null 2>&1; then
  echo "FAIL env-minchars: kontener aigon-core-runtime nie działa"
  exit 1
fi

ENVS=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' aigon-core-runtime 2>/dev/null)
if echo "$ENVS" | grep -qE '^AIGON_OUTPUT_MIN_CHARS=1$'; then
  echo "PASS env-minchars: AIGON_OUTPUT_MIN_CHARS=1 w kontenerze"
  exit 0
fi
echo "FAIL env-minchars: AIGON_OUTPUT_MIN_CHARS=1 BRAK w kontenerze (env: $(echo "$ENVS" | grep -c AIGON_OUTPUT || echo 0) wystąpień AIGON_OUTPUT*)"
exit 1
