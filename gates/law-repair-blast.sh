#!/usr/bin/env bash
# law-repair-blast.sh — LAW-REPAIR-BLAST (S11-T3)
# Akcja samonaprawy deklaruje zakres: w skryptach heal/guard/watchdog/
# stack-health `docker compose ... up` ma --no-deps i nazwę serwisu;
# `docker restart` zakazany; `docker compose restart|down` bez serwisu
# zakazany. Komentarze pomijane. Read-only.
# Wejścia: SCAN_DIR (domyślnie scripts/).
set -uo pipefail
ROOT="${AIGON_ROOT:-/srv/aigon}"
export SCAN_DIR="${SCAN_DIR:-$ROOT/scripts}"

timeout 30 python3 - <<'PY'
import glob, os, re, sys
d = os.environ["SCAN_DIR"]
files = sorted(f for f in glob.glob(os.path.join(d, "*.sh"))
               if re.search(r"heal|guard|watchdog|stack-health", os.path.basename(f))
               and not os.path.basename(f).startswith("test-"))
if not files:
    print("[UNKNOWN] brak skryptów samonaprawy w " + d); print("STATUS: UNKNOWN"); sys.exit(1)
up = re.compile(r"docker[ -]compose\b.*\bup\b")
bad = 0
for f in files:
    for i, raw in enumerate(open(f, errors="replace"), 1):
        line = raw.split("#", 1)[0] if not raw.lstrip().startswith("#") else ""
        if not line.strip(): continue
        why = None
        if re.search(r"\bdocker\s+restart\b", line): why = "docker restart (poza compose)"
        elif up.search(line) and "--no-deps" not in line: why = "compose up bez --no-deps"
        elif re.search(r"docker[ -]compose\b.*\b(restart|down)\s*(;|&|\||$)", line): why = "compose restart/down bez serwisu"
        if why:
            bad += 1; print(f"[FAIL] {os.path.relpath(f, d)}:{i}: {why}: {line.strip()[:110]}")
print(f"skryptów={len(files)} naruszeń={bad}")
print("STATUS: " + ("FAIL" if bad else "PASS"))
sys.exit(1 if bad else 0)
PY
