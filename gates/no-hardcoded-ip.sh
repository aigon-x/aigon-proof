#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/no-hardcoded-ip.sh — gate no-hardcoded-ip (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  Delegacja do scripts/hooks/git-pre-commit.sh --gate no-hardcoded-ip:
#  IP poza topologią mesh w configach = blokada.
#
#  Kontrakt: exit 0 = PASS, exit 1 = FAIL (hardcoded IP poza topologią).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

OUT=$(bash "$ROOT/scripts/hooks/git-pre-commit.sh" --gate no-hardcoded-ip 2>&1)
RC=$?
if [ $RC -eq 0 ]; then
  echo "no-hardcoded-ip: PASS"
  exit 0
fi
echo "no-hardcoded-ip: FAIL ($(echo "$OUT" | tail -1))"
exit 1
