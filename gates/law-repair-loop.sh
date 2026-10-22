#!/usr/bin/env bash
# law-repair-loop.sh — LAW-REPAIR-NO-LOOP (S11-T2)
# Każdy licznik restartów samonaprawy aigon_*restarts_total: increase w 1h
# <= MAX_RESTARTS (3). Powyżej = pętla naprawy (FAIL) — strażnik ma pauzować
# i eskalować (wzorzec cron-liveness-guard: restart_pending). Brak liczników
# = UNKNOWN. Read-only (Prometheus :49091).
# Wejścia: PROM_URL, MAX_RESTARTS, LAW_PROM_FIXTURE (JSON {seria: increase}).
set -uo pipefail
export PROM_URL="${PROM_URL:-http://127.0.0.1:49091}" MAX_RESTARTS="${MAX_RESTARTS:-3}" LAW_PROM_FIXTURE="${LAW_PROM_FIXTURE:-}"

timeout 40 python3 - <<'PY'
import json, os, sys, urllib.parse, urllib.request
mx = float(os.environ["MAX_RESTARTS"]); fx = os.environ.get("LAW_PROM_FIXTURE")
if fx:
    series = json.load(open(fx))
else:
    # increase() gubi __name__, więc regex po nazwie daje zduplikowane
    # labelsety — pytamy osobno o każdą nazwę licznika.
    base = os.environ["PROM_URL"]
    get = lambda path: json.load(urllib.request.urlopen(base + path, timeout=10))
    try:
        names = [n for n in get("/api/v1/label/__name__/values")["data"]
                 if n.startswith("aigon_") and n.endswith("restarts_total")]
        series = {}
        for n in names:
            d = get("/api/v1/query?" + urllib.parse.urlencode({"query": f"increase({n}[1h])"}))
            for r in d.get("data", {}).get("result", []):
                m = r["metric"]
                lab = ",".join(f"{k}={v}" for k, v in sorted(m.items()) if k not in ("job", "instance"))
                series[f"{n}{{{lab}}}"] = float(r["value"][1])
    except Exception as e:
        print(f"[UNKNOWN] Prometheus niedostępny ({type(e).__name__})"); print("STATUS: UNKNOWN"); sys.exit(1)
if not series:
    print("[UNKNOWN] 0 liczników aigon_*restarts_total"); print("STATUS: UNKNOWN"); sys.exit(1)
fail = 0
for k, v in sorted(series.items()):
    if v > mx: fail += 1; print(f"[FAIL] {k}: +{v:.1f} restartów/1h > {mx:g} — pętla naprawy")
print(f"liczników={len(series)} w_pętli={fail} (próg {mx:g}/h)")
print("STATUS: " + ("FAIL" if fail else "PASS"))
sys.exit(1 if fail else 0)
PY
