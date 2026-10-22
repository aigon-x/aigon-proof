#!/usr/bin/env bash
# law-alert-actionability.sh — LAW-ALERT-ACTIONABLE (S9-T2)
# Każda reguła `alert:` w ŻYWYM rules.yml ma owner (labels/annotations),
# runbook (annotations.runbook|runbook_url) i labels.severity. Dodatkowo
# CERTIFICATION z obs-alerts.sh musi być PASS — parsowana z wyjścia, bo
# adapter verify zwraca rc=0 nawet przy FAIL. Read-only.
# Wejścia: RULES_FILE, OBS_ALERTS_GATE (pusty = pomiń wrapper, np. w teście).
set -uo pipefail
ROOT="${AIGON_ROOT:-/srv/aigon}"
RULES_FILE="${RULES_FILE:-$ROOT/observability/prometheus/rules.yml}"
OBS_ALERTS_GATE="${OBS_ALERTS_GATE-$ROOT/tools/gates/obs-alerts.sh}"
rc=0

if [ -n "$OBS_ALERTS_GATE" ]; then
  cert="$(cd "$ROOT" && timeout 25 bash "$OBS_ALERTS_GATE" 2>&1 | sed -n 's/^CERTIFICATION: *//p' | tail -1)"
  if [ "$cert" = "PASS" ]; then echo "[PASS] obs-alerts CERTIFICATION: PASS"
  else echo "[FAIL] obs-alerts CERTIFICATION: ${cert:-BRAK} (executor ERROR = UNKNOWN, nie PASS)"; rc=1; fi
fi

[ -r "$RULES_FILE" ] || { echo "[UNKNOWN] brak $RULES_FILE"; echo "STATUS: UNKNOWN"; exit 1; }
RULES_FILE="$RULES_FILE" timeout 25 python3 - <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["RULES_FILE"])) or {}
tot = no_owner = no_runbook = no_sev = 0; sample = []
for g in d.get("groups", []) or []:
    for r in g.get("rules", []) or []:
        if "alert" not in r: continue
        tot += 1
        lab, ann = r.get("labels") or {}, r.get("annotations") or {}
        o = bool(lab.get("owner") or ann.get("owner"))
        rb = bool(ann.get("runbook") or ann.get("runbook_url") or lab.get("runbook"))
        sv = bool(lab.get("severity"))
        no_owner += not o; no_runbook += not rb; no_sev += not sv
        if (not o or not rb) and len(sample) < 5: sample.append(r["alert"])
print(f"alertów={tot} bez_owner={no_owner} bez_runbook={no_runbook} bez_severity={no_sev}")
if sample: print("przykłady:", ", ".join(sample))
if tot == 0: print("[UNKNOWN] 0 reguł alert"); sys.exit(2)
sys.exit(1 if (no_owner or no_runbook or no_sev) else 0)
PY
prc=$?
case $prc in
  0) echo "[PASS] rules.yml: każdy alert ma owner+runbook+severity" ;;
  2) rc=1 ;;
  *) echo "[FAIL] rules.yml: alerty bez owner/runbook/severity — nieakcjonowalne"; rc=1 ;;
esac
[ $rc -eq 0 ] && echo "STATUS: PASS" || echo "STATUS: FAIL"
exit $rc
