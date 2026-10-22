#!/usr/bin/env bash
# always-answer-guard.sh — egzekutor LAW-ALWAYS-ANSWER-1 (zawsze odpowiedź).
#
# Prawo: każde żądanie kończy się odpowiedzią albo jawną kolejką; ZAKAZANY jest
# stan terminalny bez odpowiedzi. Mierzymy to na ledgerze decyzji klasyfikatora
# (JSONL), nie na deklaracji.
#
# C1 ledger istnieje i ma rekordy (brak danych = UNKNOWN, nie PASS).
# C2 w oknie ostatnich N rekordów KAŻDY ma niepuste answer.content.
# C3 rekord bez answer musi mieć skip/hop z powodem (kolejka), nie ciszę.
# C4 metryka Prometheus jest świeża (mtime < TTL) — inaczej pomiar kłamie.
#
# Kody: 0 PASS, 1 FAIL, 2 UNKNOWN.
set -uo pipefail
ROOT="${AIGON_ROOT:-/srv/aigon}"
CFG="$ROOT/config/canonical/model-classifier.yaml"
WINDOW="${ALWAYS_ANSWER_WINDOW:-200}"
TTL_H="${ALWAYS_ANSWER_TTL_H:-168}"

[ -f "$CFG" ] || { echo "UNKNOWN always-answer-guard: brak $CFG"; exit 2; }
command -v python3 >/dev/null || { echo "UNKNOWN always-answer-guard: brak python3"; exit 2; }

python3 - "$ROOT" "$CFG" "$WINDOW" "$TTL_H" <<'PY'
import json, os, sys, time
from pathlib import Path
import yaml

root, cfgp, window, ttl_h = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
c = yaml.safe_load(cfgp.read_text(encoding="utf-8")) or {}
paths = c.get("paths") or {}
ledger = root / (paths.get("ledger") or "var/metrics/model-classifier/decisions.jsonl")
prom = root / (paths.get("prom") or "var/metrics/model-classifier/model_classifier.prom")

fails, notes = [], []
if not ledger.exists():
    print(f"UNKNOWN always-answer-guard: brak ledgera {ledger}")
    raise SystemExit(2)

recs = []
with ledger.open(encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            recs.append(json.loads(line))
        except Exception:
            fails.append("C1 nieparsowalny rekord w ledgerze")
recs = recs[-window:]
if not recs:
    print("UNKNOWN always-answer-guard: ledger pusty (brak przebiegów do zmierzenia)")
    raise SystemExit(2)

answered = queued = 0
for i, r in enumerate(recs):
    ans = (r.get("answer") or {}).get("content")
    if isinstance(ans, str) and ans.strip():
        answered += 1
        continue
    # Brak treści: dozwolone TYLKO jako jawna kolejka z powodem.
    reason = r.get("queued_reason") or r.get("skip_reason") or (r.get("answer") or {}).get("queued_reason")
    hops = r.get("hops") or []
    last = hops[-1] if hops else {}
    if reason or last.get("result") in ("queued", "blocked", "no_capacity"):
        queued += 1
        continue
    fails.append(f"C2 rekord #{i} bez odpowiedzi i bez kolejki (node={r.get('node')}, class={r.get('task_class')})")

if not prom.exists():
    fails.append("C4 brak metryki Prometheus (pomiar nieeksportowany)")
else:
    age_h = (time.time() - prom.stat().st_mtime) / 3600
    if age_h > ttl_h:
        fails.append(f"C4 metryka nieświeża: {age_h:.1f} h > TTL {ttl_h:.0f} h")

if fails:
    for f in fails[:10]:
        print("FAIL always-answer-guard:", f)
    raise SystemExit(1)
print(f"PASS always-answer-guard: rekordy={len(recs)} odpowiedzi={answered} kolejka={queued} terminal=0")
PY
