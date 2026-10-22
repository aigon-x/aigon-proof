#!/usr/bin/env bash
# Test negatywny law-alert-actionability.sh (S9-T2) — fixture rules.yml w mktemp -d.
set -uo pipefail
G="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
expect() { local want=$1 name=$2; shift 2; "$@" >"$T/out" 2>&1; local rc=$?
  if [ "$rc" = "$want" ]; then echo "[OK] $name (rc=$rc)"; else echo "[BAD] $name: rc=$rc, oczekiwano $want"; sed "s/^/    /" "$T/out" | tail -5; fails=$((fails+1)); fi; }
cat >"$T/ok.yml" <<EOF
groups:
- name: g
  rules:
  - alert: A
    expr: up == 0
    labels: {severity: critical, owner: mesh}
    annotations: {runbook: docs/runbooks/a.md}
EOF
cat >"$T/noowner.yml" <<EOF
groups:
- name: g
  rules:
  - alert: A
    expr: up == 0
    labels: {severity: critical}
    annotations: {runbook: docs/runbooks/a.md}
EOF
cat >"$T/norunbook.yml" <<EOF
groups:
- name: g
  rules:
  - alert: A
    expr: up == 0
    labels: {severity: critical, owner: mesh}
EOF
expect 0 "alert z owner+runbook+severity -> PASS" env OBS_ALERTS_GATE= RULES_FILE="$T/ok.yml" bash "$G/law-alert-actionability.sh"
expect 1 "alert bez owner -> FAIL" env OBS_ALERTS_GATE= RULES_FILE="$T/noowner.yml" bash "$G/law-alert-actionability.sh"
expect 1 "alert bez runbook -> FAIL" env OBS_ALERTS_GATE= RULES_FILE="$T/norunbook.yml" bash "$G/law-alert-actionability.sh"
expect 1 "brak rules.yml -> UNKNOWN" env OBS_ALERTS_GATE= RULES_FILE="$T/nie-ma.yml" bash "$G/law-alert-actionability.sh"
[ $fails -eq 0 ] && { echo "NEGATIVE TEST: PASS"; exit 0; }; echo "NEGATIVE TEST: FAIL ($fails)"; exit 1
