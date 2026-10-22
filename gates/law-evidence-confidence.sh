#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/law-evidence-confidence.sh — S4-T5 (pewność nie wyższa niż dowód)
#
#  PRAWO: zadeklarowany status nie może przewyższać dowodu, który go niesie.
#  Plik dowodu bramki (artifacts/evidence/gates/*.evidence) z status=PASS
#  musi mieć exit_code=0, niepusty output i timestamp; status=FAIL musi mieć
#  exit_code!=0. Rozjazd = „zielony bez dowodu" albo dowód przeinaczony.
#  Dowód starszy niż TTL (domyślnie 7 dni) = STALE — status PASS na nim
#  jest pewnością większą niż dowód.
#  Override: LAW_EC_DIR, LAW_EC_TTL_DAYS. exit 0 = PASS, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
DIR="${LAW_EC_DIR:-/srv/aigon/artifacts/evidence/gates}"
TTL="${LAW_EC_TTL_DAYS:-7}"
python3 - "$DIR" "$TTL" <<'PY'
import sys, glob, os, datetime as dt
d, ttl = sys.argv[1], int(sys.argv[2])
files = sorted(glob.glob(os.path.join(d, "*.evidence")))
if not files: print(f"[FAIL] brak plików dowodu w {d}"); sys.exit(1)
now = dt.datetime.now(dt.timezone.utc)
bad = stale = 0
for f in files:
    kv = {}
    for line in open(f, errors="replace"):
        if "=" in line:
            k, v = line.rstrip("\n").split("=", 1); kv.setdefault(k, v)
    st, rc, out, ts = kv.get("status"), kv.get("exit_code"), kv.get("output", ""), kv.get("timestamp")
    n = os.path.basename(f)
    if st == "PASS" and (rc != "0" or not out.strip()):
        bad += 1; print(f"[FAIL] {n}: status=PASS przy exit_code={rc} output={'pusty' if not out.strip() else 'ok'}")
    elif st == "FAIL" and rc == "0":
        bad += 1; print(f"[FAIL] {n}: status=FAIL przy exit_code=0 (dowód przeinaczony)")
    elif st not in ("PASS", "FAIL", "WARN", "UNKNOWN", "STALE", "PARTIAL"):
        bad += 1; print(f"[FAIL] {n}: status={st!r} spoza kontraktu statusów")
    try:
        age = (now - dt.datetime.fromisoformat((ts or "").replace("Z", "+00:00"))).days
    except Exception:
        bad += 1; print(f"[FAIL] {n}: brak/zły timestamp {ts!r}"); continue
    if st == "PASS" and age > ttl:
        stale += 1; print(f"[STALE] {n}: PASS sprzed {age} dni (TTL {ttl}) — pewność > dowód")
print(f"[INFO] plików={len(files)} rozjazdów={bad} stale_pass={stale}")
fail = bad > 0 or stale > 0
print("law-evidence-confidence:", "FAIL" if fail else "PASS")
sys.exit(1 if fail else 0)
PY
