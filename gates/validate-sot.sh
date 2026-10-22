#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/validate-sot.sh — gate validate-sot (hook-runner)
#
#  Delegacja do .git-hooks/validate-sot (Universal Project Template —
#  SSOT implementacji: single-owner SoT, brak hardcoded IP/node count,
#  brak sekretów, brak latest image w produkcji).
#
#  Exit: 0 = PASS, niezerowy = FAIL/WARN (hook-runner interpretuje).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMPL="$ROOT/.git-hooks/validate-sot"

if [ ! -x "$IMPL" ]; then
  echo "brak implementacji: $IMPL"
  exit 2
fi

exec bash "$IMPL"
