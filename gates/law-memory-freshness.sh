#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/law-memory-freshness.sh — S5-T2 + S5-T4 (konflikty i świeżość pamięci)
#
#  PRAWO: każdy wpis pamięci ma stan CURRENT / STALE / SUPERSEDED /
#  CONFLICTED / UNKNOWN; konflikt rozstrzyga się jawnie, nie kolejnością
#  czytania.
#
#  POMIAR (per katalog pamięci projektu Claude):
#    CONFLICTED  dwa pliki z tym samym `name:` -> FAIL (dwie prawdy o jednym fakcie)
#    UNKNOWN     link w MEMORY.md do pliku, którego nie ma -> FAIL (indeks kłamie)
#    ORPHAN      plik pamięci nieobecny w indeksie MEMORY.md -> WARN (nigdy nie wraca do kontekstu)
#    STALE       brak `modified:` i mtime > TTL dni -> INFO (liczony, nie blokuje)
#  Override: LAW_MF_ROOT (katalog z */memory), LAW_MF_TTL_DAYS. exit 0/1.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="${LAW_MF_ROOT:-$HOME/.claude/projects}"
TTL="${LAW_MF_TTL_DAYS:-30}"
python3 - "$ROOT" "$TTL" <<'PY'
import sys, os, re, glob, time
root, ttl = sys.argv[1], int(sys.argv[2])
fail = 0; tot = {"conflicted": 0, "unknown": 0, "orphan": 0, "stale": 0, "files": 0}
for mdir in sorted(glob.glob(os.path.join(root, "*", "memory"))):
    files = [f for f in glob.glob(os.path.join(mdir, "*.md")) if os.path.basename(f) != "MEMORY.md"]
    names = {}
    for f in files:
        tot["files"] += 1
        t = open(f, errors="replace").read()
        m = re.search(r"^name:\s*(.+)$", t, re.M)
        if m: names.setdefault(m.group(1).strip(), []).append(os.path.basename(f))
        if not re.search(r"^\s*modified:", t, re.M) and time.time() - os.path.getmtime(f) > ttl * 86400:
            tot["stale"] += 1
    for k, v in names.items():
        if len(v) > 1:
            tot["conflicted"] += 1; fail = 1; print(f"[FAIL] CONFLICTED {mdir}: name={k} w {v}")
    idx = os.path.join(mdir, "MEMORY.md")
    if os.path.isfile(idx):
        links = set(re.findall(r"\]\(([^)#\s]+\.md)\)", open(idx, errors="replace").read()))
        for l in sorted(links):
            if not os.path.isfile(os.path.join(mdir, l)):
                tot["unknown"] += 1; fail = 1; print(f"[FAIL] UNKNOWN {idx}: link do nieistniejącego {l}")
        for f in files:
            if os.path.basename(f) not in links:
                tot["orphan"] += 1; print(f"[WARN] ORPHAN {f}: poza indeksem MEMORY.md")
print("[INFO] " + " ".join(f"{k}={v}" for k, v in tot.items()) + f" (TTL={ttl}d)")
print("law-memory-freshness:", "FAIL" if fail else "PASS")
sys.exit(fail)
PY
