#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# tools/gates/parallelism-validate.sh — GATE: parallelism-validate
# Deklaracja (config/canonical/gates.yaml): "Verify N tasks per wave does not
# exceed available slots or limit 8", threshold: 8.
#
# Wejście: plan fal (YAML/JSON) — argument, $AIGON_WAVE_PLAN albo
#          config/canonical/wave-plan.yaml, jeśli istnieje.
# Reguła: parallel > limit  → FAIL. limit = min(threshold=8, slots).
# Brak planu = SKIP (PASS z informacją) — nie ma czego walidować.
# Kontrakt hook-runner: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
THRESHOLD="${AIGON_PARALLEL_THRESHOLD:-8}"
SLOTS="${AIGON_SLOTS:-$THRESHOLD}"
LIMIT=$(( SLOTS < THRESHOLD ? SLOTS : THRESHOLD ))

check_plan() {
  python3 - "$1" "$LIMIT" <<'PY'
import sys, os, json, yaml
path, limit = sys.argv[1], int(sys.argv[2])
data = yaml.safe_load(open(path, encoding='utf-8'))
waves = data.get('waves') if isinstance(data, dict) else data
if not isinstance(waves, list) or not waves:
    print('SKIP: plan bez sekcji waves'); sys.exit(0)
bad = 0
for i, w in enumerate(waves, 1):
    if not isinstance(w, dict): continue
    par = w.get('parallel', w.get('tasks_parallel', w.get('tasks')))
    if isinstance(par, list): par = len(par)
    if not isinstance(par, int): continue
    status = 'PASS' if par <= limit else 'FAIL'
    print(f'[%s] wave-{i} parallel=%d limit=%d' % (status, par, limit))
    if par > limit: bad += 1
print(f'waves={len(waves)} limit={limit} naruszenia={bad}')
sys.exit(1 if bad else 0)
PY
}

if [ "${1:-}" = "--selftest" ]; then
  td="$(mktemp -d)"; trap 'rm -rf "$td"' EXIT
  printf 'waves:\n  - {name: good, parallel: 4}\n' > "$td/good.yaml"
  printf 'waves:\n  - {name: bad, parallel: 16}\n'  > "$td/bad.yaml"
  check_plan "$td/good.yaml" >/dev/null 2>&1; g=$?
  check_plan "$td/bad.yaml"  >/dev/null 2>&1; b=$?
  fail=0
  [ "$g" -eq 0 ] && echo "[SELFTEST PASS] plan w limicie = PASS" || { echo "[SELFTEST FAIL] poprawny plan odrzucony"; fail=1; }
  [ "$b" -eq 1 ] && echo "[SELFTEST PASS] przekroczenie limitu = FAIL" || { echo "[SELFTEST FAIL] sabotaż niewykryty"; fail=1; }
  if [ "$fail" -eq 0 ]; then echo "=== RESULT === SELFTEST PASS"; exit 0; fi
  echo "=== RESULT === SELFTEST FAIL"; exit 1
fi

PLAN="${1:-${AIGON_WAVE_PLAN:-}}"
[ -z "$PLAN" ] && [ -f /opt/PROD/config/canonical/wave-plan.yaml ] && PLAN=/opt/PROD/config/canonical/wave-plan.yaml
if [ -z "$PLAN" ] || [ ! -f "$PLAN" ]; then
  echo "SKIP: brak planu fal (argument / AIGON_WAVE_PLAN / config/canonical/wave-plan.yaml)"
  echo "=== RESULT === PASS (skip)"
  exit 0
fi
echo "parallelism-validate: $PLAN (limit=$LIMIT)"
check_plan "$PLAN"
rc=$?
[ "$rc" -eq 0 ] && echo "=== RESULT === PASS" || echo "=== RESULT === FAIL — fala szersza niż limit"
exit "$rc"
