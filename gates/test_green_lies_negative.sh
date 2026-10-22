#!/usr/bin/env bash
# Test negatywny law-green-lies.sh (S9-T4) — fixture /health, .prom i adaptery w mktemp -d.
set -uo pipefail
G="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
expect() { local want=$1 name=$2; shift 2; "$@" >"$T/out" 2>&1; local rc=$?
  if [ "$rc" = "$want" ]; then echo "[OK] $name (rc=$rc)"; else echo "[BAD] $name: rc=$rc, oczekiwano $want"; sed "s/^/    /" "$T/out" | tail -5; fails=$((fails+1)); fi; }
now=$(date +%s)
printf "aigon_cron_liveness_last_check_timestamp %s\naigon_cron_liveness_hung 0\n" "$now" >"$T/cron.prom"
printf "aigon_cron_liveness_last_check_timestamp %s\naigon_cron_liveness_hung 0\n" "$((now-3600))" >"$T/cron-dead.prom"
echo "{\"health_snapshot_age_seconds\":5,\"health_snapshot_ttl_seconds\":30,\"health_snapshot_fresh\":true}" >"$T/h-ok.json"
echo "{\"health_snapshot_age_seconds\":95,\"health_snapshot_ttl_seconds\":30,\"health_snapshot_fresh\":true}" >"$T/h-lie.json"
echo "{\"status\":\"ok\"}" >"$T/h-noage.json"
printf "echo CERTIFICATION: PASS\nexit 0\n" >"$T/good.sh"
printf "echo CERTIFICATION: FAIL\nexit 0\n" >"$T/liar.sh"
run() { env HEALTH_JSON_FILE="$1" CRON_PROM_FILE="$2" GREEN_LIE_GATES="$3" bash "$G/law-green-lies.sh"; }
expect 0 "swiezy snapshot + zywy straznik + spojny adapter -> PASS" run "$T/h-ok.json" "$T/cron.prom" "$T/good.sh"
expect 1 "fresh=true przy age>ttl -> FAIL" run "$T/h-lie.json" "$T/cron.prom" "$T/good.sh"
expect 1 "/health bez age/ttl -> FAIL" run "$T/h-noage.json" "$T/cron.prom" "$T/good.sh"
expect 1 "straznik crona martwy (1h) -> FAIL" run "$T/h-ok.json" "$T/cron-dead.prom" "$T/good.sh"
expect 1 "adapter rc=0 przy CERTIFICATION FAIL -> FAIL" run "$T/h-ok.json" "$T/cron.prom" "$T/liar.sh"
expect 1 "brak .prom straznika -> UNKNOWN" run "$T/h-ok.json" "$T/nie-ma.prom" "$T/good.sh"
[ $fails -eq 0 ] && { echo "NEGATIVE TEST: PASS"; exit 0; }; echo "NEGATIVE TEST: FAIL ($fails)"; exit 1
