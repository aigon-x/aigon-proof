#!/usr/bin/env bash
# law-green-lies.sh — LAW-NO-GREEN-LIES (S9-T4, rozszerza LAW-HEALTH-1)
#  (a) /health runtime: health_snapshot_age_seconds/ttl/fresh obecne;
#      age > ttl przy fresh=true = FAIL (fałszywy zielony).
#  (b) strażnik crona (timer systemd) żyje: last_check młodszy niż 300 s.
#  (c) adapter bramki NIE zwraca rc=0 przy CERTIFICATION: FAIL.
# Brak telemetrii = UNKNOWN (rc=1), nigdy PASS. Read-only; klucz runtime
# czytany ze środowiska i NIGDY nie wypisywany.
# Wejścia: HEALTH_JSON_FILE (fixture zamiast /health), CRON_PROM_FILE,
#          GREEN_LIE_GATES (lista ścieżek adapterów, spacje).
set -uo pipefail
ROOT="${AIGON_ROOT:-/opt/PROD}"
CRON_PROM_FILE="${CRON_PROM_FILE:-/var/lib/node_exporter/textfile_collector/aigon-cron-liveness.prom}"
GREEN_LIE_GATES="${GREEN_LIE_GATES-$ROOT/tools/gates/obs-slo.sh $ROOT/tools/gates/obs-alerts.sh $ROOT/tools/gates/dlq-process-check.sh}"
CRON_MAX_AGE="${CRON_MAX_AGE:-300}"
fail=0; unknown=0

# (a) health snapshot
if [ -n "${HEALTH_JSON_FILE:-}" ]; then
  hj="$(cat "$HEALTH_JSON_FILE" 2>/dev/null)"
else
  key="${AIGON_RUNTIME_SHARED_SECRET:-${AIGON_RUNTIME_API_KEY:-${RUNTIME_API_KEY:-}}}"
  # nagłówek przez stdin — klucz nie trafia do argv (ps)
  hj="$(printf 'X-API-Key: %s\n' "$key" | curl -sk --max-time 8 -H @- https://127.0.0.1:7000/health 2>/dev/null)"
  unset key
fi
hres="$(printf '%s' "$hj" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("UNKNOWN brak/niepoprawny /health"); sys.exit()
a,t,f=d.get("health_snapshot_age_seconds"),d.get("health_snapshot_ttl_seconds"),d.get("health_snapshot_fresh")
if a is None or t is None or f is None: print("FAIL /health bez age/ttl/fresh (LAW-HEALTH-1)")
elif f and a>t: print(f"FAIL fresh=true przy age={a}s > ttl={t}s — fałszywy zielony")
elif not f and a<=t: print(f"FAIL fresh=false przy age={a}s <= ttl={t}s — niespójny snapshot")
else: print(f"PASS age={a}s ttl={t}s fresh={f}")' 2>/dev/null)"
echo "[${hres%% *}] health snapshot: ${hres#* }"
case "$hres" in PASS*) ;; FAIL*) fail=$((fail+1)) ;; *) unknown=$((unknown+1)) ;; esac

# (b) strażnik crona
lc="$(sed -n 's/^aigon_cron_liveness_last_check_timestamp //p' "$CRON_PROM_FILE" 2>/dev/null | tail -1)"
hung="$(sed -n 's/^aigon_cron_liveness_hung //p' "$CRON_PROM_FILE" 2>/dev/null | tail -1)"
if [[ "$lc" =~ ^[0-9]+$ ]]; then
  age=$(( $(date +%s) - lc ))
  if [ "$age" -gt "$CRON_MAX_AGE" ]; then echo "[FAIL] cron-liveness-guard martwy: last_check ${age}s > ${CRON_MAX_AGE}s (CronLivenessGuardDead)"; fail=$((fail+1))
  elif [ "${hung:-0}" = "1" ]; then echo "[FAIL] cron zawieszony (aigon_cron_liveness_hung=1, CronDaemonHung)"; fail=$((fail+1))
  else echo "[PASS] cron-liveness-guard żywy (last_check ${age}s temu, hung=${hung:-?})"; fi
else
  echo "[UNKNOWN] brak aigon_cron_liveness_last_check_timestamp w $CRON_PROM_FILE"; unknown=$((unknown+1))
fi

# (c) green lie adaptera: rc=0 przy CERTIFICATION: FAIL
for g in $GREEN_LIE_GATES; do
  [ -r "$g" ] || { echo "[UNKNOWN] brak adaptera $g"; unknown=$((unknown+1)); continue; }
  out="$(cd "$ROOT" && timeout 15 bash "$g" 2>&1)"; grc=$?
  cert="$(printf '%s\n' "$out" | sed -n 's/^CERTIFICATION: *//p' | tail -1)"
  if [ "$grc" -eq 0 ] && [ "$cert" = "FAIL" ]; then
    echo "[FAIL] green lie: $(basename "$g") rc=0 przy CERTIFICATION: FAIL"; fail=$((fail+1))
  else
    echo "[PASS] $(basename "$g"): rc=$grc CERTIFICATION=${cert:-n/a} spójne"
  fi
done

if [ $fail -gt 0 ]; then echo "STATUS: FAIL (fail=$fail unknown=$unknown)"; exit 1
elif [ $unknown -gt 0 ]; then echo "STATUS: UNKNOWN (unknown=$unknown)"; exit 1
else echo "STATUS: PASS"; exit 0; fi
