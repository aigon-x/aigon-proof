#!/usr/bin/env bash
# tools/gates/naming-taxonomy.sh — GATE N-90 (CANON-NAMING-1)
# Sprawdza nazwy plików względem config/canonical/naming-taxonomy.yaml.
# Ratchet: domyślnie sprawdza TYLKO pliki podane jako argumenty (nowe/zmienione).
# Kody: 0=PASS, 1=FAIL, 2=ERROR (nie zmierzono — liczony jak UNKNOWN).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANON="$ROOT/config/canonical/naming-taxonomy.yaml"

if [ ! -f "$CANON" ]; then echo "ERROR: brak kanonu $CANON"; exit 2; fi
if ! command -v python3 >/dev/null 2>&1; then echo "ERROR: brak python3"; exit 2; fi

python3 - "$CANON" "$@" <<'PY'
import os, re, sys, subprocess

canon_path, *files = sys.argv[1:]
try:
    import yaml
    d = yaml.safe_load(open(canon_path, encoding="utf-8"))
except Exception as e:
    print(f"ERROR: nie można wczytać kanonu: {e}")
    sys.exit(2)

types = {k for k in d.get("types", {}) if k != "uzasadnienie"}
domains = {k for k in d.get("domains", {}) if k != "uzasadnienie"}

SECRET = re.compile(r"(hasl|hasł|password|passwd|pass|secret|token|klucz|key)[a-z]{0,4}[-_]?[A-Za-z0-9!@#$%^&*]{6,}", re.I)
EIGHT = re.compile(r"20\d{6}")
DATE = re.compile(r"20\d{2}-\d{2}-\d{2}")
ALLOWED = re.compile(r"^[a-z0-9][a-z0-9.-]*$")

if not files:
    try:
        out = subprocess.run(["git", "-C", os.path.dirname(os.path.dirname(canon_path)),
                              "diff", "--name-only", "--cached"],
                             capture_output=True, text=True, timeout=60)
        files = [l for l in out.stdout.splitlines() if l.strip()]
    except Exception:
        files = []

if not files:
    print("PASS N-90: brak plików do sprawdzenia (ratchet — nic nie zmieniono)")
    sys.exit(0)

conventions = d.get("conventions_per_layer") or {}

def konwencja(path):
    best = None
    for prefix, conf in conventions.items():
        if path.startswith(prefix) and (best is None or len(prefix) > len(best[0])):
            best = (prefix, conf or {})
    return best[1] if best else {}

ROOT_SKIP = {".gitignore", ".gitattributes", "README.md", "LICENSE",
             "Cargo.toml", "Cargo.lock", "KANON.md", "AGENTS.md", "QWEN.md",
             "CLAUDE.md", "GEMINI.md"}

fails, warns = [], []
for f in files:
    base = os.path.basename(f)
    stem, _ext = os.path.splitext(base)
    if base in ROOT_SKIP:
        continue
    conf = konwencja(f)
    zakazy = set(conf.get("zakazy") or [])
    wymagaj_typu = bool(conf.get("wymagaj_typu", True))
    if SECRET.search(stem):
        fails.append((f, "N-91", "wartość sekretu/hasła w nazwie"))
        continue
    if "N-92" in zakazy and EIGHT.search(stem):
        fails.append((f, "N-92", "data 8-cyfrowa zamiast ISO 8601"))
    if "N-94" in zakazy and not ALLOWED.match(stem):
        fails.append((f, "N-94", "niedozwolone znaki (spacje/wielkie litery/PL)"))
    parts = stem.replace("_", "-").split("-")
    if wymagaj_typu and parts and parts[0] not in types:
        fails.append((f, "N-96", f"brak typu na początku (jest '{parts[0]}')"))
    elif wymagaj_typu and not (set(parts) & domains):
        warns.append((f, "N-97", "brak znanej domeny w nazwie"))
    if "v" in parts:
        i = parts.index("v")
        if i + 1 >= len(parts) or not parts[i + 1].isdigit():
            fails.append((f, "N-93", "wersja 'v' bez numeru"))

for f, rule, why in warns:
    print(f"WARN {rule} {f}: {why}")
for f, rule, why in fails:
    print(f"FAIL {rule} {f}: {why}")

if fails:
    print(f"FAIL N-90: {len(fails)} naruszeń / {len(files)} plików")
    sys.exit(1)
print(f"PASS N-90: {len(files)} plików, 0 naruszeń ({len(warns)} ostrzeżeń)")
sys.exit(0)
PY
