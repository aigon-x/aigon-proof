#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/no-latest-prod.sh — gate no-latest-prod (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  Delegacja do scripts/hooks/git-pre-commit.sh --gate no-latest-prod:
#  image :latest w configach produkcyjnych = blokada.
#
#  Kontrakt: exit 0 = PASS, exit 1 = FAIL (:latest w prod).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

OUT=$(bash "$ROOT/scripts/hooks/git-pre-commit.sh" --gate no-latest-prod 2>&1)
RC=$?
if [ $RC -eq 0 ]; then
  echo "no-latest-prod: PASS"
  exit 0
fi
echo "no-latest-prod: FAIL ($(echo "$OUT" | tail -1))"
exit 1
