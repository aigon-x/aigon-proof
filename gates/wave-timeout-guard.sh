#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# tools/gates/wave-timeout-guard.sh — GATE: wave-timeout-guard
# Deklaracja (gates.yaml): "Timeout per wave: if cumulative runtime exceeds
# allocated budget. Failure threshold: 0.9 of budget leads to warning;
# > budget → BLOCKING", budget_factor: 0.9
#
# Wejście: plan fal z budget_s i measured_s (argument / $AIGON_WAVE_PLAN /
#          config/canonical/wave-plan.yaml).
# Reguła: measured > budget → FAIL; measured > 0.9*budget → WARN (exit 0).
# Brak planu = SKIP.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
FACTOR="${AIGON_WAVE_BUDGET_FACTOR:-0.9}"

check_plan() {
  python3 - "$1" "$FACTOR" <<'PY'
import sys, yaml
path, factor = sys.argv[1], float(sys.argv[2])
data = yaml.safe_load(open(path, encoding='utf-8'))
waves = data.get('waves') if isinstance(data, dict) else data
if not isinstance(waves, list) or not waves:
    print('SKIP: plan bez sekcji waves'); sys.exit(0)
fails = warns = 0
for i, w in enumerate(waves, 1):
    if not isinstance(w, dict): continue
    budget = w.get('budget_s'); measured = w.get('measured_s')
    if not isinstance(budget, (int, float)) or not isinstance(measured, (int, float)):
        continue
    if measured > budget:
        print(f'[FAIL] wave-{i} measured={measured}s > budget={budget}s'); fails += 1
    elif measured > factor * budget:
        print(f'[WARN] wave-{i} measured={measured}s > {factor:.0%} budget={budget}s'); warns += 1
    else:
        print(f'[PASS] wave-{i} measured={measured}s budget={budget}s')
print(f'waves={len(waves)} fail={fails} warn={warns}')
sys.exit(1 if fails else 0)
PY
}

if [ "${1:-}" = "--selftest" ]; then
  td="$(mktemp -d)"; trap 'rm -rf "$td"' EXIT
  printf 'waves:\n  - {name: ok, budget_s: 600, measured_s: 300}\n'   > "$td/ok.yaml"
  printf 'waves:\n  - {name: bad, budget_s: 600, measured_s: 900}\n'  > "$td/bad.yaml"
  printf 'waves:\n  - {name: warn, budget_s: 600, measured_s: 570}\n' > "$td/warn.yaml"
  check_plan "$td/ok.yaml"   >/dev/null 2>&1; o=$?
  check_plan "$td/bad.yaml"  >/dev/null 2>&1; b=$?
  out=$(check_plan "$td/warn.yaml" 2>&1); w=$?
  fail=0
  [ "$o" -eq 0 ] && echo "[SELFTEST PASS] w budżecie = PASS" || { echo "[SELFTEST FAIL] poprawna fala odrzucona"; fail=1; }
  [ "$b" -eq 1 ] && echo "[SELFTEST PASS] przekroczenie budżetu = FAIL" || { echo "[SELFTEST FAIL] sabotaż niewykryty"; fail=1; }
  [ "$w" -eq 0 ] && echo "$out" | grep -q WARN && echo "[SELFTEST PASS] >90% budżetu = WARN (nie FAIL)" || { echo "[SELFTEST FAIL] próg 0.9 nie działa"; fail=1; }
  if [ "$fail" -eq 0 ]; then echo "=== RESULT === SELFTEST PASS"; exit 0; fi
  echo "=== RESULT === SELFTEST FAIL"; exit 1
fi

PLAN="${1:-${AIGON_WAVE_PLAN:-}}"
[ -z "$PLAN" ] && [ -f /opt/PROD/config/canonical/wave-plan.yaml ] && PLAN=/opt/PROD/config/canonical/wave-plan.yaml
if [ -z "$PLAN" ] || [ ! -f "$PLAN" ]; then
  echo "SKIP: brak planu fal z budget_s/measured_s"
  echo "=== RESULT === PASS (skip)"
  exit 0
fi
echo "wave-timeout-guard: $PLAN (factor=$FACTOR)"
check_plan "$PLAN"
rc=$?
[ "$rc" -eq 0 ] && echo "=== RESULT === PASS" || echo "=== RESULT === FAIL — fala przekroczyła budżet"
exit "$rc"
