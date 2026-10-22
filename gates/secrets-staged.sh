#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/secrets-staged.sh — gate secrets-staged (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  Delegacja do scripts/hooks/git-pre-commit.sh --gate secrets-staged:
#  sekrety/.env/klucze w staged = blokada commita.
#
#  Kontrakt: exit 0 = PASS, exit 1 = FAIL (sekrety w staged).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

OUT=$(bash "$ROOT/scripts/hooks/git-pre-commit.sh" --gate secrets-staged 2>&1)
RC=$?
if [ $RC -eq 0 ]; then
  echo "secrets-staged: PASS"
  exit 0
fi
echo "secrets-staged: FAIL ($(echo "$OUT" | tail -1))"
exit 1
