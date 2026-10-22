#!/usr/bin/env bash
# law-slo.sh — LAW-SLO-OWNED (S9-T3)
# Każdy przepływ krytyczny (required_slo_services z S9-observability.yaml) ma
# SLO: service != template, owner, target (0<t<=1), window, error_budget_policy,
# alert_ref wskazujący alert istniejący w rules.yml. CERTIFICATION obs-slo
# parsowana z wyjścia (adapter zwraca rc=0 przy FAIL). Read-only.
# Wejścia: SLO_FILE, RULES_FILE, LAW_DRAFT, OBS_SLO_GATE (pusty = pomiń).
set -uo pipefail
ROOT="${AIGON_ROOT:-/srv/aigon}"
SLO_FILE="${SLO_FILE:-$ROOT/config/canonical/slo.yaml}"
RULES_FILE="${RULES_FILE:-$ROOT/observability/prometheus/rules.yml}"
LAW_DRAFT="${LAW_DRAFT:-$ROOT/config/canonical/constitution-drafts/S9-observability.yaml}"
OBS_SLO_GATE="${OBS_SLO_GATE-$ROOT/tools/gates/obs-slo.sh}"
rc=0

if [ -n "$OBS_SLO_GATE" ]; then
  cert="$(cd "$ROOT" && timeout 25 bash "$OBS_SLO_GATE" 2>&1 | sed -n 's/^CERTIFICATION: *//p' | tail -1)"
  if [ "$cert" = "PASS" ]; then echo "[PASS] obs-slo CERTIFICATION: PASS"
  else echo "[FAIL] obs-slo CERTIFICATION: ${cert:-BRAK}"; rc=1; fi
fi

[ -r "$SLO_FILE" ] || { echo "[UNKNOWN] brak $SLO_FILE"; echo "STATUS: UNKNOWN"; exit 1; }
SLO_FILE="$SLO_FILE" RULES_FILE="$RULES_FILE" LAW_DRAFT="$LAW_DRAFT" timeout 25 python3 - <<'PY'
import os, sys, yaml
slo = (yaml.safe_load(open(os.environ["SLO_FILE"])) or {}).get("slo") or []
try:
    rules = yaml.safe_load(open(os.environ["RULES_FILE"])) or {}
    alerts = {r["alert"] for g in rules.get("groups", []) or [] for r in g.get("rules", []) or [] if "alert" in r}
except Exception:
    alerts = set()
draft = yaml.safe_load(open(os.environ["LAW_DRAFT"]))
req = next((l.get("required_slo_services") or [] for l in draft["laws"] if l.get("task_id") == "S9-T3"), [])
bad = 0; have = set()
for s in slo:
    name = s.get("service", "?"); errs = []
    if name in ("template", "", None): errs.append("service=template (placeholder)")
    for k in ("owner", "window", "error_budget_policy", "alert_ref"):
        if not s.get(k): errs.append(f"brak {k}")
    t = s.get("target")
    if not isinstance(t, (int, float)) or not 0 < t <= 1: errs.append(f"target={t!r}")
    if s.get("alert_ref") and s["alert_ref"] not in alerts: errs.append(f"alert_ref {s['alert_ref']} nie istnieje w rules.yml")
    if errs: bad += 1; print(f"[FAIL] SLO {name}: " + "; ".join(errs))
    else: have.add(name); print(f"[PASS] SLO {name}")
missing = [r for r in req if r not in have]
if missing: bad += 1; print(f"[FAIL] przepływy krytyczne bez ważnego SLO: {', '.join(missing)}")
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || rc=1
[ $rc -eq 0 ] && echo "STATUS: PASS" || echo "STATUS: FAIL"
exit $rc
