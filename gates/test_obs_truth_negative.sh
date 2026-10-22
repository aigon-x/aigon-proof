#!/usr/bin/env bash
# Test negatywny law-obs-truth.sh (S9-T1) — fixture zamiast Prometheusa, kopia w mktemp -d.
set -uo pipefail
G="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
expect() { local want=$1 name=$2; shift 2; "$@" >"$T/out" 2>&1; local rc=$?
  if [ "$rc" = "$want" ]; then echo "[OK] $name (rc=$rc)"; else echo "[BAD] $name: rc=$rc, oczekiwano $want"; sed "s/^/    /" "$T/out" | tail -5; fails=$((fails+1)); fi; }
echo "{\"aigon_cron_liveness_last_check_timestamp\":14,\"aigon_cron_liveness_last_cmd_timestamp\":13,\"aigon_mesh_duty_last_run_timestamp_seconds\":12}" >"$T/ok.json"
echo "{\"aigon_cron_liveness_last_check_timestamp\":0,\"aigon_cron_liveness_last_cmd_timestamp\":13,\"aigon_mesh_duty_last_run_timestamp_seconds\":12}" >"$T/frozen.json"
echo "{\"aigon_cron_liveness_last_check_timestamp\":null,\"aigon_cron_liveness_last_cmd_timestamp\":13,\"aigon_mesh_duty_last_run_timestamp_seconds\":12}" >"$T/missing.json"
expect 0 "wszystkie serie ruchome -> PASS" env LAW_PROM_FIXTURE="$T/ok.json" bash "$G/law-obs-truth.sh"
expect 1 "seria zamrozona (changes=0) -> FAIL" env LAW_PROM_FIXTURE="$T/frozen.json" bash "$G/law-obs-truth.sh"
expect 1 "brak serii -> UNKNOWN (nie PASS)" env LAW_PROM_FIXTURE="$T/missing.json" bash "$G/law-obs-truth.sh"
grep -q "STATUS: UNKNOWN" "$T/out" || { echo "[BAD] brak serii nie dal STATUS: UNKNOWN"; fails=$((fails+1)); }
[ $fails -eq 0 ] && { echo "NEGATIVE TEST: PASS"; exit 0; }; echo "NEGATIVE TEST: FAIL ($fails)"; exit 1
