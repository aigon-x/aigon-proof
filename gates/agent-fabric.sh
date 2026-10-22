#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/agent-fabric.sh — gate agent-fabric (hook-runner)
#
#  KANON 2026-09-03: agenty (qwen/hermes/claude/aigon-code/grok) = JEDEN
#  organizm — jeden SSOT (agent-models.yaml), jeden prompt (AGENTS.md),
#  te same trasy :38080/:38090, wspólna wiedza (skille), sync idempotentny.
#  Test: scripts/test_agent_fabric.py (10 niezmienników).
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS
#    exit 1 = FAIL (rozjazd organizmu — blokada push)
#    exit 2 = WARN (brak dostępu do /home/sniegul — gate cykliczny jako aigon)
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

OUT=$(cd "$ROOT" && python3 -m pytest scripts/test_agent_fabric.py -q 2>&1)
RC=$?
if [ $RC -eq 0 ]; then
  echo "PASS agent-fabric ($(echo "$OUT" | tail -1))"
  exit 0
fi
if echo "$OUT" | grep -q 'brak dostępu do /home/sniegul'; then
  echo "WARN agent-fabric (gate cykliczny jako user aigon — brak /home/sniegul; egzekucja przy pre-push)"
  exit 2
fi
echo "FAIL agent-fabric ($(echo "$OUT" | grep -E '^(FAILED|E )' | head -3))"
exit 1
