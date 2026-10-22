#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/mesh-peers.sh — gate mesh-peers (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  Liczba peerów w mesh-nodes.yaml >= 8 (kanon: 8 nodów mesha).
#
#  Kontrakt: exit 0 = PASS (>=8), exit 1 = FAIL (<8).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

N=$(grep -cE '^\s*ip:' "$ROOT/config/mesh-nodes.yaml" 2>/dev/null || echo 0)
if [ "$N" -ge 8 ]; then
  echo "mesh-peers: PASS ($N nodów)"
  exit 0
fi
echo "mesh-peers: FAIL ($N<8 w mesh-nodes.yaml)"
exit 1
