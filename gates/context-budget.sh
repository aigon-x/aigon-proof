#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/context-budget.sh — gate budżetu kontekstu agentów
#
#  POWÓD ISTNIENIA (2026-09-04): cała warstwa subagentów padła, bo prompt
#  urósł do 61694-66798 tokenów przy oknie 32768. Żadna z 21 istniejących
#  bramek tego nie mierzyła — pilnują obrazów, portów, compose, env, ticków,
#  scatteru, SSOT, GPU. Powierzchni runtime'u agenta nie pilnował nikt.
#
#  Cięcie promptu naprawia DZIŚ. Ta bramka pilnuje JUTRA.
#
#  SSOT progów: config/agent-models.yaml -> context_budget:
#  Test: scripts/test_context_budget.py
#
#  Kontrakt z hook-runner.sh (identyczny jak agent-fabric.sh):
#    exit 0 = PASS
#    exit 1 = FAIL (budżet przekroczony / dryf deklaracji)
#    exit 2 = WARN (brak dostępu do /home/sniegul — gate cykliczny jako aigon)
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

OUT=$(cd "$ROOT" && python3 -m pytest scripts/test_context_budget.py -q 2>&1)
RC=$?
if [ $RC -eq 0 ]; then
  echo "PASS context-budget ($(echo "$OUT" | tail -1))"
  exit 0
fi
if echo "$OUT" | grep -q 'brak dostępu do /home/sniegul'; then
  echo "WARN context-budget (gate cykliczny jako user aigon — brak /home/sniegul; egzekucja przy pre-push)"
  exit 2
fi
echo "FAIL context-budget ($(echo "$OUT" | grep -E '^(FAILED|E )' | head -3))"
exit 1
