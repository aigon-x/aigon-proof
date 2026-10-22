#!/usr/bin/env bash
# Test negatywny law-slo.sh (S9-T3) — fixture slo.yaml + rules.yml w mktemp -d.
set -uo pipefail
G="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
expect() { local want=$1 name=$2; shift 2; "$@" >"$T/out" 2>&1; local rc=$?
  if [ "$rc" = "$want" ]; then echo "[OK] $name (rc=$rc)"; else echo "[BAD] $name: rc=$rc, oczekiwano $want"; sed "s/^/    /" "$T/out" | tail -5; fails=$((fails+1)); fi; }
printf "groups:\n- name: g\n  rules:\n  - alert: ChatDown\n    expr: up==0\n" >"$T/rules.yml"
gen() { { echo "slo:"; for s in chat scatter cron monitoring deploy; do printf "  - {service: %s, sli: availability, target: 0.99, window: 30d, owner: ops, error_budget_policy: freeze, alert_ref: %s}\n" "$s" "$1"; done; } >"$T/$2"; }
gen ChatDown ok.yaml; gen BrakAlertu badref.yaml
printf "slo:\n  - {service: template, sli: a, target: 0.99, window: 30d, alert_ref: ChatDown}\n" >"$T/tpl.yaml"
grep -v deploy "$T/ok.yaml" >"$T/missing.yaml"
expect 0 "5 przeplywow z kompletnym SLO -> PASS" env OBS_SLO_GATE= SLO_FILE="$T/ok.yaml" RULES_FILE="$T/rules.yml" bash "$G/law-slo.sh"
expect 1 "alert_ref do nieistniejacego alertu -> FAIL" env OBS_SLO_GATE= SLO_FILE="$T/badref.yaml" RULES_FILE="$T/rules.yml" bash "$G/law-slo.sh"
expect 1 "service=template bez owner -> FAIL" env OBS_SLO_GATE= SLO_FILE="$T/tpl.yaml" RULES_FILE="$T/rules.yml" bash "$G/law-slo.sh"
expect 1 "brak SLO dla deploy -> FAIL" env OBS_SLO_GATE= SLO_FILE="$T/missing.yaml" RULES_FILE="$T/rules.yml" bash "$G/law-slo.sh"
[ $fails -eq 0 ] && { echo "NEGATIVE TEST: PASS"; exit 0; }; echo "NEGATIVE TEST: FAIL ($fails)"; exit 1
