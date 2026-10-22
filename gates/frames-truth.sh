#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/frames-truth.sh — GATE-233 FRAMES-TRUTH
#
#  PRAWO: LAW-FRAMES-TRUTH-1 (config/canonical/law-frames-truth.yaml)
#  „Ramka nie kłamie": grafika rysuje tę samą liczbę co tekst obok; brak
#  pomiaru to BRAK, nie zero; wartość zmienia się WYŁĄCZNIE od zdarzenia
#  silnika, nigdy od zegara.
#
#  PO CO OSOBNA BRAMKA (zmierzone 2026-10-17): istniejąca bramka rodziny
#  INORG `ui-truth` ma `find | while read; exit 1; done; echo PASS; exit 0`
#  — kod wyjścia z podpowłoki PRZEPADA, więc zawsze zwraca PASS (fałszywa
#  zieleń). Ta bramka wykrywa KLASĘ wzorców i jest wpięta w przebieg.
#
#  CO MIERZY (struktura plików UI; wzorce konserwatywne):
#    F1  Postęp animowany zegarem: setInterval/setTimeout, w którego ciele
#        jest przypisanie do progress|percent|pct|postęp — FAIL.
#    F2  Wartość licząca z zegara: Date.now()/performance.now() w pliku,
#        który liczy eta|remaining|pozostało|progres — FAIL.
#    F3  Brak pomiaru pokazany jako zero: `?? 0` / `|| 0` przy identyfikatorze
#        miary (value|count|total|score|kpi|reading|pomiar|wynik) — WARN.
#    F4  Druga definicja liczby w tym samym pliku (>=2 wywołania tej samej
#        funkcji liczącej KPI w jednym pliku) — WARN.
#
#  POKRYCIE: F1-F2 blokujące; F3-F4 doradcze. NIE mierzy reflow ani formatu
#  liczby na żywym renderze — to wymaga testu przeglądarkowego (poza tą bramką,
#  jawnie odnotowane w raporcie jako luka).
#
#  KONTRAKT: 0 = PASS/WARN, 1 = FAIL, 2 = UNKNOWN (brak targetów).
#  SELFTEST: --selftest (3/3), --report (wypisz i nie blokuj).
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="${AIGON_FRAMES_ROOT:-$ROOT_DEFAULT}"

run_check() {
python3 - "$ROOT" "$1" <<'PY'
import glob, re, sys
from pathlib import Path
root = Path(sys.argv[1]); mode = sys.argv[2]
try:
    import yaml
except ImportError:
    print("UNKNOWN: brak pyyaml"); sys.exit(2)
law = root / "config" / "canonical" / "law-frames-truth.yaml"
if not law.exists():
    print(f"UNKNOWN: brak {law}"); sys.exit(2)
d = yaml.safe_load(open(law, encoding="utf-8")) or {}
targets = d.get("targets") or []
if not targets:
    print("UNKNOWN: prawo nie deklaruje `targets:` — brak zakresu do zmierzenia")
    sys.exit(2)

files = []
for t in targets:
    p = t if str(t).startswith("/") else str(root / t)
    for f in glob.glob(p, recursive=True):
        q = Path(f)
        if q.is_file() and q.suffix in (".js", ".jsx", ".ts", ".tsx", ".html", ".vue", ".svelte"):
            files.append(q)
files = sorted(set(files))
if not files:
    print("UNKNOWN: zero plików UI w zadeklarowanych targetach (sprawdź ścieżki)")
    sys.exit(2)

F1 = re.compile(r'(setInterval|setTimeout)\s*\([^;]{0,400}?(progress|percent|pct|post[eę]p)\w*\s*(\+=|=)', re.S | re.I)
F2 = re.compile(r'(Date\.now|performance\.now)\s*\(', re.I)
F2_CTX = re.compile(r'\b(eta|remaining|pozosta[lł]o|progres)\w*', re.I)
F3 = re.compile(r'\b(value|count|total|score|kpi|reading|pomiar|wynik)\w*\s*(\?\?|\|\|)\s*0\b', re.I)
F4 = re.compile(r'\b(evaluate|computeKpi|calculateKpi|kpiScore)\s*\(', re.I)

fails, warns = [], []
for f in files:
    try:
        txt = f.read_text(encoding="utf-8", errors="replace")
    except Exception:
        continue
    rel = str(f.relative_to(root)) if str(f).startswith(str(root)) else str(f)
    for m in F1.finditer(txt):
        line = txt[:m.start()].count("\n") + 1
        fails.append(f"F1 {rel}:{line}: postęp animowany zegarem ({m.group(1)} → {m.group(2)})")
    if F2.search(txt) and F2_CTX.search(txt):
        line = txt[:F2.search(txt).start()].count("\n") + 1
        fails.append(f"F2 {rel}:{line}: wartość licząca z zegara (Date.now/performance.now + ETA/progres)")
    for m in F3.finditer(txt):
        line = txt[:m.start()].count("\n") + 1
        warns.append(f"F3 {rel}:{line}: brak pomiaru jako zero ({m.group(0).strip()})")
    hits = len(F4.findall(txt))
    if hits >= 2:
        warns.append(f"F4 {rel}: {hits} wywołania funkcji liczącej KPI w jednym pliku — sprawdź, czy to nie druga definicja liczby")

print(f"targety: {len(targets)}, pliki UI: {len(files)}, FAIL: {len(fails)}, WARN: {len(warns)}")
for x in fails[:40]:
    print("FAIL " + x)
for x in warns[:40]:
    print("WARN " + x)
if mode == "--report":
    print("REPORT ONLY — nie blokuję")
    sys.exit(0)
if fails:
    sys.exit(1)
print("PASS frames-truth: zero zegarowych postępów, zero wartości liczonych z zegara")
sys.exit(0)
PY
}

selftest() {
  local tmp rc ok=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/config/canonical" "$tmp/ui"
  cat > "$tmp/config/canonical/law-frames-truth.yaml" <<EOF
law: LAW-FRAMES-TRUTH-1
targets:
  - "$tmp/ui/**/*.jsx"
EOF
  cat > "$tmp/ui/clean.jsx" <<'EOF'
export function Frame({ value, present }) {
  return <div>{present ? value : "—"}</div>;
}
EOF
  AIGON_FRAMES_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  rc=$?; [ "$rc" -eq 0 ] && echo "selftest 1/3 PASS (czysty widok)" || { echo "selftest 1/3 FAIL (rc=$rc)"; ok=1; }

  cat > "$tmp/ui/timer.jsx" <<'EOF'
export function Bar() {
  let progress = 0;
  setInterval(() => { progress += 1; }, 1000);
  return <div style={{ width: progress + "%" }} />;
}
EOF
  AIGON_FRAMES_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  rc=$?; [ "$rc" -eq 1 ] && echo "selftest 2/3 PASS (postęp z zegara złapany)" || { echo "selftest 2/3 FAIL (rc=$rc)"; ok=1; }

  rm -f "$tmp/ui/timer.jsx"
  cat > "$tmp/ui/eta.jsx" <<'EOF'
export function Eta({ started }) {
  const remaining = 100 - (Date.now() - started) / 1000;
  return <span>{remaining}s</span>;
}
EOF
  AIGON_FRAMES_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  rc=$?; [ "$rc" -eq 1 ] && echo "selftest 3/3 PASS (ETA z zegara złapane)" || { echo "selftest 3/3 FAIL (rc=$rc)"; ok=1; }
  return "$ok"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --report) run_check --report; exit $? ;;
  "") run_check ""; exit $? ;;
  *) echo "użycie: $0 [--selftest|--report]" >&2; exit 2 ;;
esac
