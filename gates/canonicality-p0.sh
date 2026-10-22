#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/canonicality-p0.sh — gate canonicality-p0 (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  Wrapper na scripts/canonicality-gate.sh z mapowaniem kodów:
#    0 = CANONICAL → PASS (0)
#    1 = DRIFT P1  → WARN (2) — rozjazd, ale NIE utrata autorytetu
#    2 = CRITICAL  → FAIL (1) — P0: sekrety w repo / autorytet poza PROD
#
#  Kontrakt: exit 0 = PASS, exit 1 = FAIL (P0), exit 2 = WARN (drift P1).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

OUT=$(cd "$ROOT" && ./scripts/canonicality-gate.sh 2>&1)
RC=$?
RESULT=$(echo "$OUT" | grep -E 'WYNIK' | head -1 | sed 's/\x1b\[[0-9;]*m//g')
case $RC in
  0) echo "canonicality-p0: PASS ($RESULT)"; exit 0 ;;
  1) echo "canonicality-p0: WARN (drift P1, P0=0 — $RESULT)"; exit 2 ;;
  *) echo "canonicality-p0: FAIL (P0 — $RESULT)"; exit 1 ;;
esac
