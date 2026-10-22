#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/law-action-budget.sh — S3-T1 / S3-T6 (rozszerza LAW-71, LAW-50)
#
#  PRAWO: każdy przebieg agenta ma SKOŃCZONY budżet akcji (tury/iteracje).
#  LAW-71 mówi „operacja bez budżetu → odrzucona", ale mierzył tylko koszt
#  w tokenach/$ — pętla agenta bez limitu tur pali GPU tak samo, za 0 $.
#
#  CO MIERZY (read-only, w źródle, nie w opisie):
#    qwen       settings.json  model.maxSessionTurns  > 0   (brak/-1 = bez limitu)
#    hermes     config.yaml    max_turns / max_iterations  skończone > 0
#    aigon-code SubagentTool   MAX_MAX_ITERATIONS          skończone > 0
#    automaty   alert-automation-policy.yaml max_actions_per_hour > 0
#  Override ścieżek przez env LAW_AB_* (testy negatywne na kopii).
#  exit 0 = PASS, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="${LAW_AB_ROOT:-/srv/aigon}"
QWEN="${LAW_AB_QWEN:-$HOME/.qwen/settings.json}"
HERMES="${LAW_AB_HERMES:-$HOME/.hermes/config.yaml}"
SUB="${LAW_AB_SUBAGENT:-$ROOT/products/aigon-code/cli/src/tools/SubagentTool/index.ts}"
AAP="${LAW_AB_AAP:-$ROOT/config/alert-automation-policy.yaml}"

fail=0
row() { printf '[%s] %-12s %s\n' "$1" "$2" "$3"; [ "$1" = FAIL ] && fail=1; return 0; }

v=$(python3 - "$QWEN" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("ERR"); sys.exit()
m=d.get("model") if isinstance(d.get("model"),dict) else {}
print(m.get("maxSessionTurns", d.get("maxSessionTurns","MISSING")))
PY
)
if [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 )); then row PASS qwen "maxSessionTurns=$v"
else row FAIL qwen "maxSessionTurns=${v:-MISSING} — sesja bez limitu tur ($QWEN)"; fi

if [ -f "$HERMES" ]; then
  bad=$(grep -E '^\s*(max_turns|max_iterations):' "$HERMES" | awk -F: '{gsub(/[ \t]/,"",$2); if ($2 !~ /^[0-9]+$/ || $2+0<=0) print $0}')
  n=$(grep -cE '^\s*(max_turns|max_iterations):' "$HERMES")
  if (( n > 0 )) && [ -z "$bad" ]; then row PASS hermes "$n limitów tur, wszystkie skończone"
  else row FAIL hermes "brak limitu albo nieskończony: ${bad:-0 wpisów}"; fi
else row FAIL hermes "brak $HERMES"; fi

v=$(grep -oE 'MAX_MAX_ITERATIONS\s*=\s*[0-9]+' "$SUB" 2>/dev/null | grep -oE '[0-9]+$')
if [[ "${v:-}" =~ ^[0-9]+$ ]] && (( v > 0 )); then row PASS aigon-code "MAX_MAX_ITERATIONS=$v"
else row FAIL aigon-code "brak MAX_MAX_ITERATIONS w $SUB"; fi

v=$(grep -oE '^\s*max_actions_per_hour:\s*[0-9]+' "$AAP" 2>/dev/null | grep -oE '[0-9]+$')
if [[ "${v:-}" =~ ^[0-9]+$ ]] && (( v > 0 )); then row PASS automaty "max_actions_per_hour=$v"
else row FAIL automaty "brak max_actions_per_hour w $AAP"; fi

[ $fail -eq 0 ] && { echo "law-action-budget: PASS"; exit 0; }
echo "law-action-budget: FAIL (harness bez skończonego budżetu akcji)"; exit 1
