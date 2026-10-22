#!/usr/bin/env bash
# TEMPLATE-CANON G-20f: wymaga runtime/crates/aigon-runtime/src
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/wired-check.sh — gate wired-check (hook-runner)
#
#  AUTOMAT: „Napisane = ma być wired w 100%" — sprawdza, czy każdy struct
#  w runtime ma DOWÓD użycia: jest polem struct Runtime, jest wołany w src,
#  jest używany w testach, jest zarejestrowany w ComponentRegistry, albo
#  jest świadomie na allowliście (orphan_struct_audit.json).
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS/WARN (brak nieuzasadnionych orphanów)
#    exit 1 = FAIL (orphany bez uzasadnienia — martwy kod)
#    exit 3 = błąd środowiska (np. brak katalogu runtime)
#  Opcje:
#    --json      → raport JSON na stdout
#    --regen     → przepisuje orphan_struct_audit.json aktualną listą orphanów
#    --quiet     → bez stdout (tylko exit code)
#
#  Analiza STATYCZNA (grep), bez cargo — nie wysypie się w CI bez toolchaina.
#  Zmienne env do testów: AIGON_WIRED_SRC (katalog src), AIGON_WIRED_RT (lib.rs).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${AIGON_WIRED_SRC:-$ROOT/runtime/crates/aigon-runtime/src}"
AUDIT="$SRC/orphan_struct_audit.json"
RUNTIME_STRUCT="${AIGON_WIRED_RT:-$SRC/lib.rs}"

JSON=0; REGEN=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --regen) REGEN=1 ;;
    --quiet) QUIET=1 ;;
  esac
done

[ -d "$SRC" ] || { echo "wired-check: brak $SRC"; exit 3; }

# ── Analiza w python3 (JSON + grep), zwraca JSON raportu ──────────────
REPORT="$(SRC="$SRC" AUDIT="$AUDIT" RUNTIME_STRUCT="$RUNTIME_STRUCT" python3 - << 'PYEOF'
import json, os, re, sys

src = os.environ["SRC"]
audit_path = os.environ["AUDIT"]
rt_struct = os.environ["RUNTIME_STRUCT"]

# 1. Zbierz definicje structów (plik → nazwa → linia).
structs = {}   # name -> {"file": rel, "line": int}
unreadable = []
for dirpath, dirnames, filenames in os.walk(src):
    for fn in filenames:
        if not fn.endswith(".rs"):
            continue
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, src)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
        except OSError:
            unreadable.append(rel)
            continue
        for i, ln in enumerate(lines, 1):
            m = re.match(r"^\s*(?:pub\s+)?struct\s+([A-Za-z_][A-Za-z0-9_]*)\b", ln)
            if m:
                name = m.group(1)
                if name not in structs:
                    structs[name] = {"file": rel, "line": i}

# 2. Pole struct Runtime — ekstrakcja nazw typów użytych jako pola.
#    Linia pola: [pub] nazwa: Typ, — typy generyczne (Arc<X>, Mutex<X>…)
#    dają tokeny z wielkich liter; token == nazwa structa = dowód wire'owania.
runtime_fields = set()
try:
    with open(rt_struct, "r", encoding="utf-8", errors="replace") as f:
        rt_lines = f.readlines()
    in_runtime = False
    for ln in rt_lines:
        if re.match(r"^\s*(?:pub\s+)?struct Runtime\s*\{", ln):
            in_runtime = True
            continue
        if in_runtime:
            if ln.strip() == "}":
                break
            m = re.match(r"^\s*(?:pub\s+)?[a-z_][a-z0-9_]*\s*:\s*(.+),?\s*$", ln)
            if m:
                typ = m.group(1)
                for tok in re.findall(r"[A-Z][A-Za-z0-9_]*", typ):
                    runtime_fields.add(tok)
except OSError:
    pass

# 3. Pełny tekst src (do grepów) + tekst katalogu tests/.
#    WAŻNE: linie deklaracji structów są WYŁĄCZANE z tekstu dowodowego —
#    inaczej wzorzec "Name {" zawsze pasuje do własnej deklaracji
#    (gate byłby w pełni przepuszczalny dla każdego structa z ciałem).
#    Komentarze też są wycinane — nazwa w komentarzu to NIE dowód użycia.
src_lines = []
for dirpath, dirnames, filenames in os.walk(src):
    for fn in filenames:
        if not fn.endswith(".rs"):
            continue
        path = os.path.join(dirpath, fn)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for ln in f:
                    if re.match(r"^\s*(?:pub\s+)?struct\s+[A-Za-z_][A-Za-z0-9_]*\b", ln):
                        continue
                    code = ln.split("//", 1)[0]
                    if not code.strip():
                        continue
                    src_lines.append(code)
        except OSError:
            pass
src_text = "".join(src_lines)

tests_dir = os.path.join(os.path.dirname(src), "tests")
tests_text = ""
try:
    for fn in os.listdir(tests_dir):
        if fn.endswith(".rs"):
            with open(os.path.join(tests_dir, fn), "r", encoding="utf-8", errors="replace") as f:
                tests_text += "\n" + f.read()
except OSError:
    pass

# 4. Allowlista z orphan_struct_audit.json (jeśli to poprawny JSON).
allowlist = set()
allowlist_reasons = {}
allowlist_corrupt = False
try:
    with open(audit_path, "r", encoding="utf-8", errors="replace") as f:
        audit_data = json.load(f)
    if isinstance(audit_data, list):
        for entry in audit_data:
            if isinstance(entry, dict) and entry.get("name"):
                allowlist.add(entry["name"])
                allowlist_reasons[entry["name"]] = entry.get("reason", "listed")
except (json.JSONDecodeError, OSError):
    allowlist_corrupt = True

# 5. Dla każdego structa: dowód użycia.
def used_evidence(name):
    ev = []
    if name in runtime_fields:
        ev.append("runtime_field")
    for pat in [f"impl {name}", f"{name}::", f"{name} {{", f"Arc<{name}>", f"Box<{name}>",
                f"&{name}", f"Vec<{name}>", f"Mutex<{name}>", f"Option<{name}>",
                f"RwLock<{name}>", f"HashMap<String, {name}>", f"Json<{name}>"]:
        if pat in src_text:
            ev.append(pat)
            break
    else:
        # ostatnia deska ratunku: nagie użycie nazwy jako typu/symbolu
        # (np. `tenant: Tenant`, `-> ExecuteResponse`, `use crate::api::Tenant`)
        if re.search(rf"\b{re.escape(name)}\b", src_text):
            ev.append("used_as_type")
    if name in tests_text:
        ev.append("used_in_tests")
    return ev

orphans = []
wired = []
for name, meta in sorted(structs.items()):
    ev = used_evidence(name)
    if ev:
        wired.append({"name": name, "file": meta["file"], "line": meta["line"], "evidence": ev})
    else:
        orphans.append({"name": name, "file": meta["file"], "line": meta["line"]})

# 6. Podział orphanów: allowlist (WARN) vs realny martwy kod (FAIL).
warn_orphans = []
fail_orphans = []
for o in orphans:
    if o["name"] in allowlist:
        o["reason"] = allowlist_reasons.get(o["name"], "listed")
        warn_orphans.append(o)
    else:
        fail_orphans.append(o)

report = {
    "gate": "wired-check",
    "status": "FAIL" if fail_orphans else ("WARN" if warn_orphans else "PASS"),
    "structs_total": len(structs),
    "structs_wired": len(wired),
    "orphans_total": len(orphans),
    "orphans_allowlisted": len(warn_orphans),
    "orphans_unjustified": len(fail_orphans),
    "snapshot_corrupt": allowlist_corrupt,
    "unreadable_files": unreadable,
    "fail_orphans": fail_orphans[:50],
    "warn_orphans": warn_orphans[:50],
}
print(json.dumps(report, indent=2, ensure_ascii=False))
PYEOF
)" || { echo "wired-check: analiza nie powiodła się"; exit 2; }

# ── --regen: przepisz snapshot aktualną listą orphanów (z uzasadnieniem) ─
if [ "$REGEN" = "1" ]; then
  AIGON_REPORT="$REPORT" python3 - "$AUDIT" << 'PYEOF'
import json, os, sys
path = sys.argv[1]
rep = json.loads(os.environ["AIGON_REPORT"])
orphans = rep.get("fail_orphans", []) + rep.get("warn_orphans", [])
out = []
for o in orphans:
    out.append({"name": o["name"], "file": o["file"], "line": o["line"],
                "reason": o.get("reason", "not_a_runtime_field")})
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, ensure_ascii=False)
print(f"wired-check: --regen — zapisano {len(out)} orphanów do {path}")
PYEOF
fi

# ── Wyjście ────────────────────────────────────────────────────────────
STATUS="$(echo "$REPORT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])')"
[ -n "$STATUS" ] || { echo "wired-check: nie mogę odczytać statusu raportu"; exit 2; }

if [ "$JSON" = "1" ]; then
  echo "$REPORT"
elif [ "$QUIET" != "1" ]; then
  AIGON_REPORT="$REPORT" python3 - << 'PYEOF'
import json, os, sys
r = json.loads(os.environ["AIGON_REPORT"])
print(f"wired-check: {r['status']} — structs={r['structs_total']} wired={r['structs_wired']} orphany={r['orphans_total']} (allowlist={r['orphans_allowlisted']}, FAIL={r['orphans_unjustified']})")
if r.get("snapshot_corrupt"):
    print("  UWAGA: orphan_struct_audit.json nie jest poprawnym JSON — allowlista pusta (uruchom --regen)")
for o in r.get("fail_orphans", [])[:15]:
    print(f"  FAIL orphan: {o['name']} ({o['file']}:{o['line']})")
for o in r.get("warn_orphans", [])[:10]:
    print(f"  WARN allowlisted: {o['name']} ({o['reason']})")
if r.get("unreadable_files"):
    print(f"  UWAGA: nieczytelne pliki (pominięte): {', '.join(r['unreadable_files'])}")
PYEOF
fi

case "$STATUS" in
  PASS|WARN) exit 0 ;;
  *) exit 1 ;;
esac
