#!/usr/bin/env bash
# tools/gates/law-decision-provenance.sh — S1-T1 DECISION PROVENANCE (rozszerza LAW-13/51).
#
# Każda DECYZJA agenta zapisana w ledgerze (rekord z run_id = przebieg z celem)
# musi nieść łańcuch pochodzenia: kto (actor), czym (tools), na jakiej podstawie
# (evidence), z jakim wynikiem (outcome) i W JAKIEJ PRZYCZYNOWOŚCI (trace_id,
# causation_id). Bez causation_id nie da się odtworzyć intent -> effect (S1-T7).
#
# Read-only: czyta NDJSON ledgera, niczego nie zapisuje.
# Statusy wyjścia wg M1-status-contract.yaml (executor_status):
#   exit 0 = PASS; exit 1 = FAIL albo ERROR (ERROR liczony jak UNKNOWN, nigdy PASS).
#
# Parametry (env) — pozwalają testowi negatywnemu wskazać kopię w mktemp:
#   PROV_LEDGER_DIR   katalog *.ndjson            (domyślnie ~/.aigon/todo)
#   PROV_SINCE_DAYS   okno oceny w dniach         (domyślnie 7 — ocena BIEŻĄCEGO zachowania)
#   PROV_REQUIRED     wymagane pola, spacjami
#   PROV_MIN_PCT      minimalne pokrycie per pole (domyślnie 99)
set -uo pipefail

PROV_LEDGER_DIR="${PROV_LEDGER_DIR:-$HOME/.aigon/todo}"
PROV_SINCE_DAYS="${PROV_SINCE_DAYS:-7}"
PROV_REQUIRED="${PROV_REQUIRED:-actor run_id tools evidence outcome trace_id causation_id}"
PROV_MIN_PCT="${PROV_MIN_PCT:-99}"

if [[ ! -d "$PROV_LEDGER_DIR" ]]; then
  echo "ERROR law-decision-provenance: brak katalogu ledgera $PROV_LEDGER_DIR (reason=EVIDENCE_MISSING)"
  exit 1
fi

PROV_LEDGER_DIR="$PROV_LEDGER_DIR" PROV_SINCE_DAYS="$PROV_SINCE_DAYS" \
PROV_REQUIRED="$PROV_REQUIRED" PROV_MIN_PCT="$PROV_MIN_PCT" \
timeout 50 python3 - <<'PY'
import glob, json, os, sys, datetime as dt

d = os.environ["PROV_LEDGER_DIR"]
req = os.environ["PROV_REQUIRED"].split()
min_pct = float(os.environ["PROV_MIN_PCT"])
since = (dt.datetime.now(dt.timezone.utc)
         - dt.timedelta(days=float(os.environ["PROV_SINCE_DAYS"]))).isoformat()[:19]

total = 0
have = {k: 0 for k in req}
for f in glob.glob(os.path.join(d, "*.ndjson")):
    with open(f, errors="replace") as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except Exception:
                continue
            if not isinstance(r, dict) or "run_id" not in r:
                continue          # zwykły wpis todo, nie decyzja
            if str(r.get("ts", ""))[:19] < since:
                continue
            total += 1
            for k in req:
                v = r.get(k)
                if v not in (None, "", [], {}):
                    have[k] += 1

if total == 0:
    print(f"ERROR law-decision-provenance: 0 decyzji (rekordów z run_id) w oknie od {since} — brak dowodu (reason=EVIDENCE_MISSING)")
    sys.exit(1)

bad = []
for k in req:
    pct = 100.0 * have[k] / total
    print(f"  {k:<14} {have[k]:>6}/{total} = {pct:6.2f}%")
    if pct < min_pct:
        bad.append(f"{k}={pct:.1f}%")
if bad:
    print(f"FAIL law-decision-provenance: pola pochodzenia poniżej {min_pct}%: {', '.join(bad)}")
    sys.exit(1)
print(f"PASS law-decision-provenance: {total} decyzji, wszystkie pola >= {min_pct}%")
PY
rc=$?
[[ $rc -eq 0 ]] && exit 0
[[ $rc -eq 124 ]] && echo "ERROR law-decision-provenance: timeout 50 s (reason=EXECUTOR_ERROR)"
exit 1
