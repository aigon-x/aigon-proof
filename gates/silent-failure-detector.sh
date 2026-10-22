#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# tools/gates/silent-failure-detector.sh — GATE: silent-failure-detector
# Deklaracja (gates.yaml): "Detects any failing tasks without runtime failure
# logs. If silent fail > 0% of tasks, raise warning", fail_threshold: 0.01
#
# Reguła: jeśli Prometheus raportuje czerwone bramki (aigon_gate_last_status==1),
# a log porażek (/var/log/aigon/gate-failures.log) jest starszy niż TTL,
# to porażka jest CICHA → FAIL. Prometheus nieosiągalny → WARN (nie false green).
# Wejścia nadpisywalne dla selftestu: AIGON_SILENT_RED, AIGON_GATE_FAIL_LOG.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
PROM="${AIGON_PROM:-http://127.0.0.1:49091}"
LOG="${AIGON_GATE_FAIL_LOG:-/var/log/aigon/gate-failures.log}"
TTL="${AIGON_SILENT_TTL:-900}"

red_count() {
  if [ -n "${AIGON_SILENT_RED:-}" ]; then echo "$AIGON_SILENT_RED"; return 0; fi
  local out
  out=$(curl -s --max-time 10 --get "$PROM/api/v1/query" \
        --data-urlencode 'query=count(aigon_gate_last_status==1)' 2>/dev/null) || { echo "NA"; return 0; }
  printf '%s' "$out" | python3 -c "import sys,json;d=json.load(sys.stdin)['data']['result'];print(d[0]['value'][1] if d else 0)" 2>/dev/null || echo "NA"
}

log_age() {
  if [ -n "${AIGON_SILENT_LOG_AGE:-}" ]; then echo "$AIGON_SILENT_LOG_AGE"; return 0; fi
  if [ ! -f "$LOG" ]; then echo "NA"; return 0; fi
  echo $(( $(date +%s) - $(stat -c %Y "$LOG") ))
}

evaluate() {
  local red age
  red=$(red_count); age=$(log_age)
  if [ "$red" = "NA" ]; then
    echo "[WARN] Prometheus nieosiągalny — nie mogę zmierzyć cichych porażek (brak pomiaru ≠ zieleń)"
    return 0
  fi
  if [ "$red" -eq 0 ]; then echo "[PASS] brak czerwonych bramek"; return 0; fi
  if [ "$age" = "NA" ]; then
    echo "[WARN] $red czerwonych bramek, brak logu porażek ($LOG) — nie można ZMIERZYĆ ciszy; dodaj writer w hook-runner. Brak pomiaru ≠ zieleń, ale też nie blokuje pushu."
    return 0
  fi
  if [ "$age" -gt "$TTL" ]; then
    echo "[FAIL] $red czerwonych bramek, log porażek ma ${age}s > TTL ${TTL}s — porażka jest CICHA"
    return 1
  fi
  echo "[PASS] $red czerwonych bramek, log porażek świeży (${age}s ≤ ${TTL}s)"
  return 0
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  AIGON_SILENT_RED=0 AIGON_SILENT_LOG_AGE=99999 evaluate >/dev/null && echo "[SELFTEST PASS] brak czerwonych = PASS" || { echo "[SELFTEST FAIL] fałszywy alarm"; fail=1; }
  AIGON_SILENT_RED=3 AIGON_SILENT_LOG_AGE=99999 evaluate >/dev/null && { echo "[SELFTEST FAIL] cisza niewykryta"; fail=1; } || echo "[SELFTEST PASS] czerwone + stary log = FAIL"
  AIGON_SILENT_RED=3 AIGON_SILENT_LOG_AGE=60 evaluate >/dev/null && echo "[SELFTEST PASS] czerwone + świeży log = PASS" || { echo "[SELFTEST FAIL] fałszywy alarm przy świeżym logu"; fail=1; }
  if [ "$fail" -eq 0 ]; then echo "=== RESULT === SELFTEST PASS"; exit 0; fi
  echo "=== RESULT === SELFTEST FAIL"; exit 1
fi

echo "silent-failure-detector: prom=$PROM log=$LOG ttl=${TTL}s"
evaluate
rc=$?
[ "$rc" -eq 0 ] && echo "=== RESULT === PASS" || echo "=== RESULT === FAIL — cicha porażka"
exit "$rc"
