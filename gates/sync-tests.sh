#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/sync-tests.sh — gate sync-tests (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  pytest testów sync-agent-models — sync to krytyczny propagator configów
#  agentów; regresja w nim = rozjazd modeli na całym meshu.
#
#  Kontrakt: exit 0 = PASS, exit 1 = FAIL.
#  Zmienne env: AIGON_ST_TEST (plik testu, default test_sync_agent_models.py).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST="${AIGON_ST_TEST:-$ROOT/scripts/test_sync_agent_models.py}"

OUT=$(cd "$ROOT" && python3 -m pytest "$TEST" -q 2>&1 | tail -1)
RC=${PIPESTATUS[0]}
if [ $RC -eq 0 ]; then
  echo "sync-tests: PASS ($OUT)"
  exit 0
fi
echo "sync-tests: FAIL ($OUT)"
exit 1
