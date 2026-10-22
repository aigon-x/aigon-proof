#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/law-metric-independence.sh — S4-T6 (brak cichej degradacji
#  kognitywnej; rozszerza LAW-74, wnosi LAW-METRIC-INDEPENDENCE do rejestru)
#
#  PRAWO (AGENTS.md, 2026-10-03): metryka „kognitywna", która NIE spada po
#  wyłączeniu mechanizmu, który ją generuje, jest fasadą. Ablacja naturalna:
#  AIGON_COGNITION_TICK_ENABLED=0.
#
#  POMIAR (read-only):
#    (1) prawo jest w REJESTRZE (constitution.generated.yaml) — prawo tylko
#        w prozie AGENTS.md nie ma egzekutora i nie wchodzi do fitness-map;
#    (2) dowód ablacji: artifacts/drills/ablation-*.json < 30 dni.
#        Brak = UNKNOWN (informacyjnie) — bramka NIE wyłącza ticku na żywym
#        runtime.
#  Override: LAW_MI_REGISTRY, LAW_MI_ROOT. exit 0 = PASS, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="${LAW_MI_ROOT:-/opt/PROD}"
REG="${LAW_MI_REGISTRY:-$ROOT/config/canonical/constitution.generated.yaml}"
fail=0
if grep -qE 'METRIC-INDEPENDENCE' "$REG" 2>/dev/null; then
  echo "[PASS] LAW-METRIC-INDEPENDENCE w rejestrze $REG"
else
  echo "[FAIL] LAW-METRIC-INDEPENDENCE poza rejestrem — prawo tylko w prozie AGENTS.md, bez egzekutora"; fail=1
fi
a=$(find "$ROOT/artifacts/drills" -maxdepth 1 -name 'ablation-*.json' -mtime -30 2>/dev/null | head -1)
if [ -n "$a" ]; then echo "[INFO] ablacja: dowód $a"
else echo "[INFO] ablacja: UNKNOWN — brak artifacts/drills/ablation-*.json < 30 dni (drill AIGON_COGNITION_TICK_ENABLED=0 poza zakresem bramki)"; fi
[ $fail -eq 0 ] && { echo "law-metric-independence: PASS"; exit 0; }
echo "law-metric-independence: FAIL"; exit 1
