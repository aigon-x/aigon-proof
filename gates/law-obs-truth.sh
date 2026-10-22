#!/usr/bin/env bash
# law-obs-truth.sh — LAW-OBS-TRUTH (S9-T1, rozszerza LAW-METRIC-INDEPENDENCE)
# Metryka krytyczna z ablation_registry (S9-observability.yaml) musi się
# RUSZAĆ w oknie: changes()==0 = zamrożona seria = fasada (FAIL); brak serii =
# UNKNOWN (rc=1, nigdy PASS). Read-only: tylko zapytania do Prometheusa.
# Wejścia (nadpisywalne w teście): LAW_DRAFT, PROM_URL, LAW_PROM_FIXTURE
# (JSON {metric: liczba|null} zamiast żywego Prometheusa).
set -uo pipefail
ROOT="${AIGON_ROOT:-/opt/PROD}"
LAW_DRAFT="${LAW_DRAFT:-$ROOT/config/canonical/constitution-drafts/S9-observability.yaml}"
PROM_URL="${PROM_URL:-http://127.0.0.1:49091}"
export LAW_DRAFT PROM_URL LAW_PROM_FIXTURE="${LAW_PROM_FIXTURE:-}"

timeout 50 python3 - <<'PY'
import json, os, sys, urllib.parse, urllib.request, yaml
draft = yaml.safe_load(open(os.environ["LAW_DRAFT"]))
reg = next((l.get("ablation_registry") or [] for l in draft.get("laws", []) if l.get("task_id") == "S9-T1"), [])
fx = os.environ.get("LAW_PROM_FIXTURE")
fixture = json.load(open(fx)) if fx else None

def changes(metric, window):
    if fixture is not None:
        return fixture.get(metric)
    q = f"max(changes({metric}[{window}]))"
    url = os.environ["PROM_URL"] + "/api/v1/query?" + urllib.parse.urlencode({"query": q})
    try:
        d = json.load(urllib.request.urlopen(url, timeout=10))
        r = d.get("data", {}).get("result", [])
        return float(r[0]["value"][1]) if r else None
    except Exception:
        return None

if not reg:
    print("[UNKNOWN] S9-T1 ablation_registry pusty — brak metryk do sprawdzenia"); print("STATUS: UNKNOWN"); sys.exit(1)
fail = unknown = 0
for e in reg:
    m, w = e["metric"], e.get("window", "15m")
    v = changes(m, w)
    if v is None:
        unknown += 1; print(f"[UNKNOWN] {m}: brak serii w Prometheusie (EVIDENCE_MISSING)")
    elif v <= 0:
        fail += 1; print(f"[FAIL] {m}: changes[{w}]=0 — seria zamrożona, metryka niewrażliwa na źródło ({e.get('source_toggle')})")
    else:
        print(f"[PASS] {m}: changes[{w}]={v:g}")
status = "FAIL" if fail else ("UNKNOWN" if unknown else "PASS")
print(f"STATUS: {status} (metryk={len(reg)} fail={fail} unknown={unknown})")
sys.exit(0 if status == "PASS" else 1)
PY
