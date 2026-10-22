#!/usr/bin/env bash
# =============================================================================
# PDF GATE — produkty/drony/aito (generator: scripts/generate_pdfs.py) —
# 8 domen (PDF1-PDF8), każda waga = 100/8 pkt → przy pełnym PASS: 8/8 = 100/100.
# Dowód: evidence/PDF<n>.log + SUMMARY.log.  Uruchomienie:
#     ./pdf-gate.sh <zrodlo.html> [artefakt.pdf]
# Bez drugiego argumentu artefakt jest renderowany z HTML (weasyprint ->
# wkhtmltopdf). Zgodne w duchem z products/drony/production-gate.sh (D1-D18).
#
# Uwaga o WĘZŁACH (narzędzia PDF są NIERÓWNOMIERNE):
#   local-aigon: pdfinfo pdftotext pdftoppm wkhtmltopdf pandoc (+ ~/.local/bin/weasyprint)
#   prod-aigon : pdfinfo pdftotext pdftoppm wkhtmltopdf
#   contabo    : pdfinfo pdftotext pdftoppm weasyprint pandoc
#   site-aigon : pdfinfo pdftotext pdftoppm
# Dlatego: (a) $HOME/.local/bin jest dokładany do PATH, (b) brak narzędzia =
# FAIL danego obszaru z jawnym komunikatem (fail-closed), a nie cichy PASS.
# PDF6 liczy /URI w BAJTACH, więc weasyprint renderuje z --uncompressed-pdf
# (domyślne spakowanie Object Streams ukrywa /URI przed grep; zmierzone).
# =============================================================================
set -u
# Hermetyczność pomiaru: bramka mierzy SYSTEM, a nie ścieżki modułów wstrzyknięte
# przez wołającego. Zostawiony PYTHONPATH potrafi podmienić PIL na wariant bez
# _imaging (zmierzone: "cannot import name '_imaging'") i dać fałszywy FAIL.
unset PYTHONPATH
# KATALOG SKRYPTU (dla lib/pdf_checks.py obok) — oraz ROOT repo (dla fixture).
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# Samowystarczalność: jeśli pypdf jest zwendorowany w lib/py (instalacja bez
# mutowania systemu), wystawiamy WYŁĄCZNIE tę ścieżkę — świadomie, po unset.
[ -d "$HERE/lib/py" ] && export PYTHONPATH="$HERE/lib/py"
EVD="${PDF_EVD:-$ROOT/evidence}"
LIBS="$HERE/lib/pdf_checks.py"
SUMMARY="$EVD/SUMMARY.log"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SRC="${1:-}"; ART="${2:-}"
# 2026-09-29: DOMYŚLNE FIXTURE Z REPO — brama ma działać bez argumentów (jak
# pozostałe bramki wołane z hook-runnera/verify). Fixture leży w
# tests/fixtures/pdf/ razem z oczekiwanymi wartościami (fixture.expected).
# Jawny argument nadal działa: `pdf-gate.sh <html> [pdf]`.
if [ -z "$SRC" ]; then
  SRC="$ROOT/tests/fixtures/pdf/fixture.html"
fi
if [ ! -f "$SRC" ]; then
  echo "FATAL: brak źródła HTML: $SRC" >&2
  echo "       Domyślne fixture: $ROOT/tests/fixtures/pdf/fixture.html" >&2
  exit 1
fi
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/gate-params.sh"
PDF_BOTTOM_MARGIN_MM="$(gp GATE-179 pdf_bottom_margin_mm 20)"
PDF_EXPECT_PHRASE="${PDF_EXPECT_PHRASE:-zażółć gęślą jaźń}"

mkdir -p "$EVD"
: > "$SUMMARY"
FAILS=0

# ---- detekcja narzędzi (wspólna dla domen; brak => komunikat, domena FAIL) ----
for t in pdfinfo pdftotext; do
  command -v "$t" >/dev/null || { echo "FATAL: brak $t w PATH — bramki PDF nie da się zmierzyć"; exit 2; }
done
PDFINFO=pdfinfo; PDFTOTEXT=pdftotext
PY=""
for c in "${PDF_PY:-}" python3 /usr/bin/python3; do
  [ -n "$c" ] || continue
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import pypdf; from PIL import Image' 2>/dev/null; then PY="$c"; break; fi
done
RENDERER="$(command -v weasyprint || command -v wkhtmltopdf || true)"

pdf_render() { # $1=zrodlo.html  $2=wyjscie.pdf
  if [ -n "${PDF_RENDER:-}" ]; then eval "$PDF_RENDER \"$1\" \"$2\""; return $?; fi
  case "$RENDERER" in
    */weasyprint)  weasyprint --uncompressed-pdf "$1" "$2" ;;
    */wkhtmltopdf) wkhtmltopdf -q "$1" "$2" ;;
    *) echo "BRAK RENDERERA (weasyprint/wkhtmltopdf) — podaj PDF_RENDER"; return 127 ;;
  esac
}

run_domain() { # $1=id, $2=nazwa, $3=opis, $4=funkcja (eval w podpowłoce)
  local id="$1" name="$2" desc="$3"
  local log="$EVD/PDF$id-$name.log"
  { echo "=== PDF$id $name — $desc ==="; echo "---";
    ( eval "$4" ) 2>&1
    echo "RC=$?"; } > "$log"
  local rc; rc="$(tail -1 "$log" | sed 's/RC=//')"
  if [ "$rc" = "0" ]; then
    echo "PDF$id $name: PASS" | tee -a "$SUMMARY"
  else
    echo "PDF$id $name: FAIL (rc=$rc) — log: $log" | tee -a "$SUMMARY"
    FAILS=$((FAILS+1))
  fi
}

# ---- artefakt: render z HTML jeśli nie podano ----
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo "FATAL: podaj istniejące źródło HTML: ./pdf-gate.sh <zrodlo.html> [artefakt.pdf]" >&2
  exit 2
fi
SRCDIR="$(cd "$(dirname "$SRC")" && pwd)"; SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
if [ -z "$ART" ]; then
  ART="$EVD/artifact.pdf"
  echo "--- render: $SRC -> $ART (renderer: ${RENDERER:-BRAK}) ---"
  pdf_render "$SRC" "$ART" || { echo "FATAL: render nieudany"; exit 2; }
else
  ART="$(cd "$(dirname "$ART")" && pwd)/$(basename "$ART")"
fi
echo "SRC=$SRC"; echo "ART=$ART (sha256=$(sha256sum "$ART" | cut -d' ' -f1))"

# ---------- PDF1: STRUKTURA (strony>0, format A4) ----------
pdf1() {
  "$PDFINFO" "$ART"
  "$PDFINFO" "$ART" | awk 'BEGIN{ok=1} /^Pages:/{p=$2} /^Page size:/{w=$3;h=$5}
    END{d1=w-595.276; if(d1<0)d1=-d1; d2=h-841.89; if(d2<0)d2=-d2;
        printf "pages=%s w=%s h=%s tol=2\n",p,w,h;
        if(!(p>0 && d1<=2 && d2<=2)) ok=0; exit(ok?0:1)}'
}
run_domain 1 struktura "strony>0 oraz format A4 (595.276 x 841.89 +/-2pt)" pdf1

# ---------- PDF2: BRAK PUSTYCH STRON (każda >300 znaków widocznych) ----------
pdf2() {
  local pages bad=0 i n
  pages="$("$PDFINFO" "$ART" | awk '/^Pages:/{print $2}')"
  echo "pages=$pages prog=300 (znaki widoczne)"
  for ((i=1;i<=pages;i++)); do
    n="$("$PDFTOTEXT" -f "$i" -l "$i" "$ART" - | tr -d '[:space:]' | wc -c)"
    echo "strona $i: $n znakow"
    [ "$n" -gt 300 ] || bad=$((bad+1))
  done
  echo "puste_lub_ubogie=$bad"
  [ "$bad" -eq 0 ]
}
run_domain 2 puste-strony "każda strona >300 znaków tekstu" pdf2

# ---------- PDF3: ZAPAS DOLNY (treść nie wchodzi w dolny margines) ----------
pdf3() {
  # LC_ALL=C na awk: pod pl_PL printf "%.2f" daje przecinek ("775,20"), a python
  # oczekuje kropki. Wymuszamy kropkę lokalnie, bez zmiany globalnego locale
  # (grep -P na cyrylicę potrzebuje UTF-8).
  local th; th="$(LC_ALL=C awk -v m="$PDF_BOTTOM_MARGIN_MM" 'BEGIN{printf "%.2f",841.89 - m*72/25.4 - 10}')"
  echo "dolny_margines=${PDF_BOTTOM_MARGIN_MM}mm prog_max_yMax=$th"
  [ -n "$PY" ] || { echo "BRAK pypdf/PIL w ${PY:-żadnym} pythonie"; return 2; }
  "$PY" "$LIBS" bbox "$ART" "$th"
}
run_domain 3 zapas-dolny "pdftotext -bbox: max yMax < 842 - margines - 10" pdf3

# ---------- PDF4: DETERMINIZM (render 2x ten sam SHA źródła) ----------
pdf4() {
  [ -n "$RENDERER" ] || [ -n "${PDF_RENDER:-}" ] || { echo "BRAK RENDERERA"; return 2; }
  local s r1 r2
  s="$(sha256sum "$SRC" | cut -d' ' -f1)"; echo "SRC_sha256=$s"
  r1="$(mktemp "$EVD/.det1.XXXX.pdf")"; r2="$(mktemp "$EVD/.det2.XXXX.pdf")"
  pdf_render "$SRC" "$r1" && pdf_render "$SRC" "$r2" || { rm -f "$r1" "$r2"; return 1; }
  local h1 h2 ha; h1="$(sha256sum "$r1"|cut -d' ' -f1)"; h2="$(sha256sum "$r2"|cut -d' ' -f1)"
  ha="$(sha256sum "$ART"|cut -d' ' -f1)"
  echo "render1=$h1"; echo "render2=$h2"; echo "artifact=$ha"
  rm -f "$r1" "$r2"
  [ "$h1" = "$h2" ] && [ "$ha" = "$h1" ]
}
run_domain 4 determinizm "dwa rendery tego samego źródła = ten sam SHA (== artefakt)" pdf4

# ---------- PDF5: TREŚĆ (brak placeholderów i cyrylicy) ----------
pdf5() {
  local t ph cyr; t="$("$PDFTOTEXT" "$ART" -)"
  ph="$(printf '%s' "$t" | grep -c '__' || true)"
  ph=$(( ph + $(printf '%s' "$t" | grep -c '{{' || true) ))
  cyr="$(printf '%s' "$t" | grep -cP '[\x{0400}-\x{04FF}]' || true)"
  echo "placeholdery(__/{{)=$ph  cyrylica=$cyr"
  [ "$ph" -eq 0 ] && [ "$cyr" -eq 0 ]
}
run_domain 5 tresc "brak '__' i '{{' oraz brak cyrylicy w tekście" pdf5

# ---------- PDF6: LINKI (/URI w bajtach PDF == <a href> w HTML) ----------
pdf6() {
  local n_pdf n_html
  n_pdf="$(grep -aoP '/URI\s*\(' "$ART" | wc -l)"
  n_html="$(grep -o '<a href' "$SRC" | wc -l)"
  echo "URI_w_PDF=$n_pdf  a_href_w_HTML=$n_html"
  [ "$n_pdf" -eq "$n_html" ]
}
run_domain 6 linki "licznik /URI( w bajtach PDF == liczba <a href> w HTML" pdf6

# ---------- PDF7: OBRAZY (unikalne z pypdf == źródła, rozmiar +/-15%) ----------
pdf7() {
  [ -n "$PY" ] || { echo "BRAK pypdf/PIL w ${PY:-żadnym} pythonie"; return 2; }
  "$PY" "$LIBS" images "$ART" "$SRC" "$SRCDIR"
}
run_domain 7 obrazy "unikalne obrazy z pypdf == <img src>, rozmiar +/-15%" pdf7

# ---------- PDF8: PL-SAFE (diakrytyki + twarda spacja, asercja na RDZENIU) ----------
pdf8() {
  local t ok=1 c
  t="$("$PDFTOTEXT" "$ART" -)"
  if printf '%s' "$t" | grep -qF -- "$PDF_EXPECT_PHRASE"; then
    echo "fraza RDZEN: '$PDF_EXPECT_PHRASE' OK"
  else
    echo "BRAK frazy rdzeniowej: '$PDF_EXPECT_PHRASE'"; ok=0
  fi
  for c in ą ć ę ł ń ó ś ź ż; do
    if printf '%s' "$t" | grep -qF -- "$c"; then echo "diakrytyk $c OK"; else echo "BRAK diakrytyku $c"; ok=0; fi
  done
  echo "--- twarda spacja (U+00A0) przez pypdf ---"
  if [ -n "$PY" ]; then "$PY" "$LIBS" nbsp "$ART" || ok=0
  else echo "BRAK pypdf — twardej spacji NIE zmierzono (fail-closed)"; ok=0; fi
  [ "$ok" -eq 1 ]
}
run_domain 8 pl-safe "diakrytyki PL + twarda spacja; asercja na rdzeniu frazy" pdf8

# ---------- Podsumowanie ----------
echo "" | tee -a "$SUMMARY"
echo "=== PODSUMOWANIE ===" | tee -a "$SUMMARY"
PASSED="$(grep -c ': PASS' "$SUMMARY" || true)"
echo "PASS=$PASSED/8  FAIL=$FAILS" | tee -a "$SUMMARY"
echo "SCORE=$((PASSED * 100 / 8))/100" | tee -a "$SUMMARY"
[ "$FAILS" -eq 0 ] && exit 0 || exit 1