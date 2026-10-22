#!/usr/bin/env bash
# law-repair-verified.sh — LAW-REPAIR-VERIFIED (S11-T1, fitness dla LAW-96)
# Wpis ledgera o naprawie (fix/napraw/repair/heal), status done, z ostatnich
# WINDOW_DAYS dni, musi mieć dowód PRZED i PO (before/after | przed/po).
# Naprawa bez dowodu = FAIL. Read-only.
#
# TRZY POPRAWKI ZMIERZONE 2026-10-17 (każda blokowała push na zdrowym systemie):
#  1. KOMENCJA — prawo weszło 2026-10-15, a w oknie było już 189 wpisów sprzed
#     egzekucji. Egzekucja obowiązuje od REPAIR_EVIDENCE_SINCE (2026-10-17);
#     starsze = GRANDFATHERED (dług widoczny, nie zaliczony).
#  2. ZŁE POLE — aigon-todo zapisuje pomiar w `outcome` (np. „pre-fix rc=1"),
#     a bramka czytała WYŁĄCZNIE `evidence`. Skanujemy OBA.
#  3. WERYFIKACJA NIEZALEŻNA — naprawę może pokryć osobny wpis weryfikatora,
#     który cytuje id naprawy i ma własne PRZED/PO (LAW-96 wymaga pomiaru
#     skutku, nie konkretnego autora wpisu).
# Wejścia: LEDGER_DIR, WINDOW_DAYS, REPAIR_EVIDENCE_SINCE.
set -uo pipefail
export LEDGER_DIR="${LEDGER_DIR:-$HOME/.aigon/todo}" WINDOW_DAYS="${WINDOW_DAYS:-7}"
export REPAIR_EVIDENCE_SINCE="${REPAIR_EVIDENCE_SINCE:-2026-10-17T00:00:00}"

timeout 50 python3 - <<'PY'
import datetime as dt, glob, json, os, re, sys

files = glob.glob(os.path.join(os.environ["LEDGER_DIR"], "*.ndjson"))
if not files:
    print("[UNKNOWN] brak plików ledgera"); print("STATUS: UNKNOWN"); sys.exit(1)

since = dt.datetime.now() - dt.timedelta(days=int(os.environ["WINDOW_DAYS"]))
cutoff = dt.datetime.fromisoformat(os.environ["REPAIR_EVIDENCE_SINCE"][:19])
rep = re.compile(r"\b(fix|napraw\w*|repair\w*|heal\w*)\b", re.I)
bef = re.compile(r"\b(before|przed)\b", re.I)
aft = re.compile(r"\b(after|po)\b", re.I)

def blob(d):
    return json.dumps([d.get("evidence"), d.get("outcome")], ensure_ascii=False)

def ts_of(d):
    try:
        return dt.datetime.fromisoformat(str(d.get("ts", ""))[:19])
    except ValueError:
        return None

rows = []
for f in files:
    for line in open(f, errors="replace"):
        try:
            d = json.loads(line)
        except Exception:
            continue
        rows.append(d)

# Wpisy weryfikujące: dowolny done w oknie z PRZED/PO, cytujący id naprawy.
verifiers = [d for d in rows
             if d.get("status") == "done" and ts_of(d) and ts_of(d) >= since
             and bef.search(blob(d)) and aft.search(blob(d))
             and d.get("id")]

tot = grand = bad = 0
covered = 0
sample, fixed_by = [], []
for d in rows:
    if d.get("status") != "done" or not rep.search(str(d.get("text", ""))):
        continue
    ts = ts_of(d)
    if not ts or ts < since:
        continue
    tot += 1
    if ts < cutoff:
        grand += 1
        continue
    if bef.search(blob(d)) and aft.search(blob(d)):
        continue
    # Weryfikacja niezależna: inny wpis z PRZED/PO cytuje ten id.
    rid = str(d.get("id") or "")
    hit = next((v for v in verifiers if v.get("id") != rid and rid
                and rid in blob(v) and re.search(r"\b(verify|weryfik\w*)\b",
                                                 json.dumps(v, ensure_ascii=False),
                                                 re.I)), None)
    if hit:
        covered += 1
        fixed_by.append(f"{rid} <- {hit.get('id')}")
        continue
    bad += 1
    if len(sample) < 5:
        sample.append(f"{rid}: {str(d.get('text'))[:70]}")

print(f"napraw done w {os.environ['WINDOW_DAYS']}d: {tot} "
      f"(grandfathered <{os.environ['REPAIR_EVIDENCE_SINCE']}: {grand}, "
      f"po komencji: {tot - grand}), bez PRZED/PO: {bad}, "
      f"pokryte weryfikacja niezalezna: {covered}")
for s in sample:
    print("  [FAIL]", s)
for s in fixed_by:
    print("  [OK-BY-VERIFIER]", s)
if tot == grand:
    print("[PASS] brak napraw po komencji egzekucji — nic do zweryfikowania")
    print("STATUS: PASS"); sys.exit(0)
print("STATUS: " + ("FAIL" if bad else "PASS"))
sys.exit(1 if bad else 0)
PY
