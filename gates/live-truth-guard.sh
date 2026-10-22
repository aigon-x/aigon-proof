#!/usr/bin/env bash
# live-truth-guard.sh — LAW-LIVE-TRUTH-1
#  (a) każdy artefakt z live-truth.yaml świeży (age <= ttl_hours); nieświeży = NIEZDROWY
#  (b) każdy GAP (API nie daje aktualnej wersji) ma owner + next_action + review_by
# Użycie: live-truth-guard.sh [--strict] [--selftest]
set -uo pipefail
REG="/opt/PROD/config/canonical/live-truth.yaml"
mode="${1:-}"

if [ "$mode" = "--selftest" ]; then
  python3 -c "import yaml;d=yaml.safe_load(open('$REG'));assert d.get('entries') or d.get('gaps');print('selftest PASS ('+str(len(d.get('entries') or []))+' entries, '+str(len(d.get('gaps') or []))+' gaps)')" \
    && echo "SELFTEST OK" || { echo "SELFTEST FAIL"; exit 1; }
  exit 0
fi

strict=0; [ "$mode" = "--strict" ] && strict=1

python3 - "$REG" "$strict" <<'PY'
import sys, yaml, os, time
reg = yaml.safe_load(open(sys.argv[1])) or {}
strict = int(sys.argv[2]); now = time.time(); problems = 0; gaps = 0
for e in (reg.get("entries") or []):
    a = e.get("artifact"); ttl = e.get("ttl_hours") or 0
    if not a or not os.path.exists(a):
        print(f"  WARN {e.get('id')}: brak artefaktu {a}"); continue
    age = (now - os.path.getmtime(a)) / 3600.0
    if age > ttl:
        print(f"  STALE {e.get('id')}: age={age:.1f}h > ttl={ttl}h ({a})"); problems += 1
for g in (reg.get("gaps") or []):
    gaps += 1
    miss = [k for k in ("owner","next_action","review_by") if not g.get(k)]
    if miss:
        print(f"  GAP {g.get('id')}: brak {miss}"); problems += 1
print(f"live-truth-guard: stale/gaps-problemy={problems}, gaps={gaps}")
sys.exit(1 if (problems and strict) else 0)
PY