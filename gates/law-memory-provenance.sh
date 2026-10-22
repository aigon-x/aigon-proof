#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/law-memory-provenance.sh — S5-T1 (pochodzenie pamięci)
#
#  PRAWO: każdy wpis pamięci trwałej agenta ma POCHODZENIE — kto/co go
#  zapisał i jakiego typu jest fakt. Wpis bez pochodzenia nie daje się
#  zweryfikować ani unieważnić; agent czyta go jak prawdę.
#
#  POMIAR:
#    Claude  ~/.claude/projects/*/memory/*.md (bez MEMORY.md) — frontmatter
#            z `name`, `description` i `type` (bezpośrednio albo w metadata).
#            Brak = FAIL.
#    Hermes  ~/.hermes/memories/MEMORY.md — wpisy rozdzielone `§` nie mają
#            pól metadanych z założenia formatu; liczymy wpisy BEZ żadnej
#            daty RRRR-MM-DD jako bez kotwicy pochodzenia (WARN, informacyjnie).
#  Override: LAW_MP_CLAUDE_GLOB, LAW_MP_HERMES. exit 0 = PASS, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
CG="${LAW_MP_CLAUDE_GLOB:-$HOME/.claude/projects/*/memory/*.md}"
HM="${LAW_MP_HERMES:-$HOME/.hermes/memories/MEMORY.md}"
python3 - "$HM" $CG <<'PY'
import sys, re, os
hm, files = sys.argv[1], sys.argv[2:]
bad = 0; n = 0
for f in files:
    if os.path.basename(f) == "MEMORY.md" or not os.path.isfile(f): continue
    n += 1
    t = open(f, errors="replace").read()
    m = re.match(r"^---\n(.*?)\n---", t, re.S)
    fm = m.group(1) if m else ""
    miss = [k for k, rx in (("name", r"^name:\s*\S"), ("description", r"^description:\s*\S"),
                            ("type", r"^\s*type:\s*\S")) if not re.search(rx, fm, re.M)]
    if miss:
        bad += 1; print(f"[FAIL] {f}: brak {','.join(miss)}")
print(f"[INFO] claude: plików={n} bez_pochodzenia={bad}")
if os.path.isfile(hm):
    ents = [e.strip() for e in open(hm, errors="replace").read().split("§") if e.strip()]
    nodate = sum(1 for e in ents if not re.search(r"20\d\d-\d\d-\d\d", e))
    print(f"[WARN] hermes: wpisów={len(ents)} bez_daty_pochodzenia={nodate} (format § bez pól metadanych)")
print("law-memory-provenance:", "FAIL" if bad else "PASS")
sys.exit(1 if bad else 0)
PY
