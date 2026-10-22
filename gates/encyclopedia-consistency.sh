#!/usr/bin/env bash
# ============================================================================
# encyclopedia-consistency.sh — GATE spójności entries ↔ encyclopedia.yaml ↔ data.js
# ============================================================================
# AIGON-X — auto-encyklopedia (wdrożenie 2026-09-04)
#
# Pilnuje trzech warstw rejestru encyklopedii:
#   entries/            — źródło prawdy (katalogi NN-* z README.md + opcjonalne *.md)
#   encyclopedia.yaml   — rejestr kanoniczny (sekcja canon: wybrane wpisy)
#   encyclopedia-data.js— index viewer-a www (generowany przez generate_data.py)
#
# Checki:
#   ENC-001  data.js parsuje się i zawiera spójny zbiór id (każde id: katalog lub kat/plik).
#   ENC-002  każdy katalog wpisów entries/NN-* ma wpis w data.js (albo w yaml canon).
#   ENC-003  liczba wpisów w data.js == liczba plików *.md (top-level) w katalogach wpisów.
#   ENC-004  każdy wpis canon z encyclopedia.yaml ma istniejący katalog i plik.
#   ENC-005  data.js nie starszy niż najnowszy wpis entries/ (sygnał braku regeneracji).
#
# Użycie:
#   ./encyclopedia-consistency.sh          — sprawdź spójność (exit 0 = OK, 1 = FAIL)
#   ./encyclopedia-consistency.sh --regen  — najpierw uruchom generator, potem sprawdź
#   ./encyclopedia-consistency.sh --quiet  — tylko exit code (do cron/log)
#
# Niezależny od tools/verify/core (self-contained) — działa z cron bez
# StateStore/sqlite/verify engine. Wzorowany na modułach tools/verify/*.
# ============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENTRIES_DIR="$ROOT/runtime/knowledge/encyclopedia/entries"
DATA_JS="$ROOT/runtime/knowledge/encyclopedia/encyclopedia-data.js"
YAML="$ROOT/config/encyclopedia.yaml"
GENERATOR="$ENTRIES_DIR/generate_data.py"

REGEN=0
QUIET=0
for a in "$@"; do
  case "$a" in
    --regen) REGEN=1 ;;
    --quiet) QUIET=1 ;;
    *) echo "nieznany argument: $a (dozwolone: --regen --quiet)" >&2; exit 2 ;;
  esac
done

for p in "$ENTRIES_DIR" "$DATA_JS" "$YAML" "$GENERATOR"; do
  [ -e "$p" ] || { echo "FATAL: brak ścieżki $p" >&2; exit 1; }
done

if [ "$REGEN" -eq 1 ]; then
  [ "$QUIET" -eq 0 ] && echo "=== ENC --regen: uruchamiam generator ==="
  if ! python3 "$GENERATOR"; then
    echo "FATAL: generator zwrócił błąd (python3 $GENERATOR)" >&2
    exit 1
  fi
fi

export ENC_QUIET="$QUIET"
python3 - "$ENTRIES_DIR" "$DATA_JS" "$YAML" <<'PY'
import json, os, re, sys

entries_dir, data_js, yaml_path = sys.argv[1], sys.argv[2], sys.argv[3]
quiet = os.environ.get('ENC_QUIET', '0') == '1'

def say(s=''):
    if not quiet:
        print(s)

fails = 0
def check_fail(cid, desc, detail=''):
    global fails
    fails += 1
    say(f'[FAIL] {cid} {desc}')
    if detail:
        for line in str(detail).splitlines():
            say(f'       {line}')

def check_pass(cid, desc):
    say(f'[PASS] {cid} {desc}')

# ── Katalogi wpisów: NN-* (2-3 cyfry + "-") ────────────────────────────────
dirs = sorted(d for d in os.listdir(entries_dir)
              if os.path.isdir(os.path.join(entries_dir, d)) and re.match(r'^\d{2,3}-', d))

# ── Pliki *.md top-level → oczekiwane id: README.md → "kat"; inny → "kat/nazwa"
fs_ids = {}
for d in dirs:
    dpath = os.path.join(entries_dir, d)
    for f in sorted(x for x in os.listdir(dpath) if x.endswith('.md')):
        fs_ids[d if f == 'README.md' else f'{d}/{f[:-3]}'] = f'{d}/{f}'

# ── data.js: window.ENCYCLOPEDIA_DATA = [...];  (rfind ']' — treść ma markdown z "]")
js_ids = []
datajs_mtime = 0
try:
    raw = open(data_js, encoding='utf-8').read()
    datajs_mtime = os.path.getmtime(data_js)
    m = re.search(r'window\.ENCYCLOPEDIA_DATA\s*=\s*', raw)
    if not m:
        raise ValueError('brak window.ENCYCLOPEDIA_DATA w data.js')
    payload = raw[m.end():]
    end = payload.rfind(']')
    if end < 0:
        raise ValueError('brak "]" zamykającego tablicę ENCYCLOPEDIA_DATA')
    data = json.loads(payload[:end + 1])
    js_ids = [e.get('id', '') for e in data if isinstance(e, dict) and e.get('id')]
except Exception as e:
    check_fail('ENC-001', 'data.js nieparsowalny', f'{type(e).__name__}: {e}')
    say('')
    say(f'=== ENCYCLOPEDIA CONSISTENCY: FAIL ===')
    sys.exit(1)

# ── encyclopedia.yaml — canon ──────────────────────────────────────────────
try:
    import yaml as _y
    with open(yaml_path, encoding='utf-8') as f:
        cfg = _y.safe_load(f) or {}
    canon = [(e.get('id',''), e.get('file',''), e.get('category',''))
             for e in (cfg.get('canon') or []) if isinstance(e, dict)]
except Exception as e:
    check_fail('ENC-001', 'encyclopedia.yaml nieparsowalny', f'{type(e).__name__}: {e}')
    say('')
    say('=== ENCYCLOPEDIA CONSISTENCY: FAIL ===')
    sys.exit(1)

js_set = set(js_ids)
fs_set = set(fs_ids)
canon_ids = {c[0] for c in canon}
canon_files = {c[1] for c in canon}

say(f'=== ENCYCLOPEDIA CONSISTENCY GATE (entries={len(dirs)} katalogów, *.md={len(fs_ids)}, data.js={len(js_ids)}, canon={len(canon)}) ===')

# ── ENC-001 data.js parsowalny + zbiór id ─────────────────────────────────
if not js_ids:
    check_fail('ENC-001', 'data.js nie zawiera wpisów (0 id)', f'przebuduj: python3 {os.path.join(entries_dir, "generate_data.py")}')
else:
    bad = [i for i in js_ids if i not in fs_set and not any(i.startswith(d + '/') for d in dirs)]
    if bad:
        check_fail('ENC-001', f'data.js ma {len(bad)} id bez pokrycia w entries/', '; '.join(bad[:10]))
    else:
        check_pass('ENC-001', f'data.js parsowalny, {len(js_ids)} unikalnych id zgodnych z entries/')

# ── ENC-002 każdy katalog wpisów ma wpis w data.js (lub canon) ────────────
missing_dirs = [d for d in dirs if d not in js_set and d not in canon_ids]
if missing_dirs:
    check_fail('ENC-002', f'{len(missing_dirs)} katalogów BEZ wpisu w data.js/canon:', '\n'.join(f'  {d}' for d in missing_dirs))
else:
    check_pass('ENC-002', f'wszystkie {len(dirs)} katalogów wpisów ma wpis w data.js/canon')

# ── ENC-003 liczba wpisów data.js == liczba *.md top-level ────────────────
js_extra = sorted(js_set - fs_set)
fs_extra = sorted(fs_set - js_set)
if js_extra or fs_extra:
    detail = []
    if fs_extra:
        detail.append(f'BRAK W data.js ({len(fs_extra)}): ' + ' '.join(fs_extra[:15]))
    if js_extra:
        detail.append(f'Tylko w data.js ({len(js_extra)}): ' + ' '.join(js_extra[:15]))
    check_fail('ENC-003', f'rozjazd: data.js={len(js_ids)} vs entries/*.md={len(fs_ids)}', '\n'.join(detail))
else:
    check_pass('ENC-003', f'liczba wpisów data.js ({len(js_ids)}) == liczba *.md w entries ({len(fs_ids)})')

# ── ENC-004 wpisy canon mają istniejący katalog i plik ────────────────────
canon_bad = []
for cid, cfile, ccat in canon:
    if not cfile or not os.path.isfile(cfile):
        canon_bad.append(f"canon '{cid}': brak pliku {cfile}")
        continue
    d = os.path.basename(os.path.dirname(cfile))
    if not os.path.isdir(os.path.dirname(cfile)) or d not in dirs:
        canon_bad.append(f"canon '{cid}': katalog {os.path.dirname(cfile)} nie jest katalogiem wpisu")
if canon_bad:
    check_fail('ENC-004', f'{len(canon_bad)} wpisów canon bez katalogu/pliku:', '\n'.join('  ' + b for b in canon_bad))
else:
    check_pass('ENC-004', f'wszystkie wpisy canon ({len(canon)}) mają istniejący katalog+plik')

# ── ENC-005 data.js nie starszy niż najnowszy wpis ────────────────────────
try:
    newest_entry = max(os.path.getmtime(os.path.join(entries_dir, d, f))
                       for d in dirs for f in os.listdir(os.path.join(entries_dir, d))
                       if f.endswith('.md'))
    if datajs_mtime >= newest_entry - 1:
        check_pass('ENC-005', 'data.js aktualny względem entries/ (brak zaległej regeneracji)')
    else:
        check_fail('ENC-005', 'data.js STARSZY niż najnowszy wpis entries/ — brak regeneracji!',
                   f'uruchom: python3 {os.path.join(entries_dir, "generate_data.py")}')
except ValueError:
    check_fail('ENC-005', 'brak plików *.md w entries/')

say('')
if fails:
    say(f'=== ENCYCLOPEDIA CONSISTENCY: FAIL ({fails} checków) — {len(fs_ids)} wpisów w entries, {len(js_ids)} w data.js ===')
    sys.exit(1)
else:
    say(f'=== ENCYCLOPEDIA CONSISTENCY: PASS ({len(fs_ids)} wpisów = {len(js_ids)} w data.js, {len(dirs)} katalogów, canon={len(canon)}) ===')
    sys.exit(0)
PY
exit $?
