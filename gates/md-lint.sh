#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/md-lint.sh — GATE-050 MD-LINT
# Lint dokumentacji Markdown (markdownlint-cli2) — wykrywa realne
# defekty docs: MD018/MD019 (spacje po #), MD012 (wielokrotne puste
# linie), MD040 (blok kodu bez języka), MD041 (pierwsza linia = H1),
# MD013 wyłączony (docs/ to produkt narracyjny — długie linie celowe).
#
# STAGED ROLLOUT (plan QUALITY-AUTOMATA-PLAN sekcja 10): template ma
# 3925 issues w 221 plikach MD (głównie generowane docs/reports).
# Dlatego default = WARNING (raport pełny, nie blokuje), a --strict
# przełącza na BLOCKING — do użycia po oczyszczeniu docs (CI/RELEASE).
#
# CHANGE-AWARE (default): lintuje TYLKO zmienione pliki .md
# (staged / ostatni commit) — nowa zmiana nie może wprowadzać
# nowych defektów. --all: pełny skan całego repo.
#
# Fail-closed: --strict + znalezisko level=error = BLOCKING FAIL
# z file:line. Default (WARNING): znaleziska raportowane jako WARN
# z pełną listą — wartość dodana (widać co poprawić) bez blokady.
# Brak plików MD = PASS (N/A nie jest FAIL).
#
# Kontrakt automatu (sekcja 9 QUALITY-AUTOMATA-PLAN):
#   raport JSON zawsze zapisany → artifacts/quality/markdownlint/
#   brak markdownlint-cli2 = WARN (nigdy cichy PASS / FALSE GREEN)
#
# Użycie:
#   bash md-lint.sh              # change-aware, WARNING (staged rollout)
#   bash md-lint.sh --strict     # change-aware, BLOCKING (po oczyszczeniu)
#   bash md-lint.sh --all        # pełny skan wszystkich .md
#   bash md-lint.sh <file>...    # jawne pliki (testy)
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-050 MD-LINT (markdownlint-cli2) ==="

OUT_DIR="artifacts/quality/markdownlint"
mkdir -p "$OUT_DIR"

# ── MD-001: markdownlint-cli2 dostępny ──────────────────────
if ! command -v markdownlint-cli2 >/dev/null 2>&1; then
  fail "MD-001 markdownlint-cli2 dostępny" BLOCKING "markdownlint-cli2 nie zainstalowany — fail-closed (linter obowiązkowy)"
  verify_module_exit
fi
pass "MD-001 markdownlint-cli2 dostępny" BLOCKING "markdownlint-cli2: $(markdownlint-cli2 --version 2>/dev/null | awk '{print $2; exit}')"

# ── Tryb: BLOCKING (--strict) vs WARNING (default, staged rollout) ─
# ${1:-} — skrypt wołany bez argumentów (evidence.sh / enforcement.sh)
# nie może crashować na nieustawionym $1 przy set -u.
STRICT=0
case "${1:-}" in
  --strict) STRICT=1; shift ;;
esac

# ── Wybór plików do skanu ───────────────────────────────────
FILES=()
MODE="changed"
if [ "$#" -gt 0 ] && [ "$1" = "--all" ]; then
  MODE="all"
elif [ "$#" -gt 0 ]; then
  MODE="explicit"
  FILES=("$@")
fi

skip_path() { case "$1" in .qwen/*|node_modules/*|vendor/*|target/*|artifacts/*|docs/generated/*|reports/*) return 0 ;; esac; return 1; }

case "$MODE" in
  all)
    # Pełny skan: wszystkie śledzone pliki .md (repo_files = git ls-files)
    while IFS= read -r f; do
      skip_path "$f" && continue
      FILES+=("$f")
    done < <(repo_files --name '\.md$')
    ;;
  explicit)
    : # FILES ustawione przez argumenty
    ;;
  changed)
    # Change-aware: staged (pre-commit) albo ostatni commit (pre-push)
    files="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)"
    if [ -z "$files" ]; then
      files="$(git diff --name-only HEAD~1..HEAD 2>/dev/null)"
    fi
    while IFS= read -r f; do
      case "$f" in
        *.md) skip_path "$f" && continue; FILES+=("$f") ;;
      esac
    done <<< "$files"
    ;;
esac

if [ "${#FILES[@]}" -eq 0 ]; then
  info "MD-002 skan markdownlint" "brak plików .md do skanu (change-aware: nic nie zmieniono)"
  verify_module_exit
fi

# ── MD-002: skan (fail-closed wg trybu) ─────────────────────
REPORT="$OUT_DIR/markdownlint-$(date +%Y%m%d-%H%M%S).json"
ERR_LOG="$OUT_DIR/markdownlint-invocation.$$"

# markdownlint-cli2: exit 0 = czysto, 1 = znaleziska, 2 = błąd wywołania.
# Output (stderr): "file:line:col severity code msg [Context: ...]"
markdownlint-cli2 --config .markdownlint-cli2.jsonc "${FILES[@]}" > "$ERR_LOG" 2>&1
MD_EXIT=$?

if [ "$MD_EXIT" -eq 2 ]; then
  fail "MD-002 skan markdownlint" BLOCKING "markdownlint-cli2 exit 2 (błąd wywołania):"
  sed -n '1,10p' "$ERR_LOG"
  rm -f "$ERR_LOG"
  verify_module_exit
fi

# Konwersja parsable → JSON (kontrakt automatu: artifacts/quality/*.json)
# "file:line:col severity code msg" → {"file","line","col","severity","code","message"}
if command -v jq >/dev/null 2>&1 && [ -s "$ERR_LOG" ]; then
  # Uwaga (fix 2026-09-23): `jq -Rr` bez `-s`/`-n` wypisywał obiekty PRETTY-PRINTED
  # jeden po drugim — plik .json nie był ani tablicą, ani poprawnym NDJSON
  # (`json.load` → "Extra data"). Kontrakt automatu mówi "raport JSON", więc
  # budujemy JEDNĄ tablicę: `-Rn` + `inputs` iteruje po surowych liniach.
  # Kolumna jest OPCJONALNA — patrz komentarz przy licznikach niżej.
  grep -E "^[^ ]+\.md:[0-9]+(:[0-9]+)? (error|warning) " "$ERR_LOG" 2>/dev/null | \
    jq -Rn '[inputs | capture("^(?<file>[^:]+):(?<line>[0-9]+)(?::(?<col>[0-9]+))? (?<severity>error|warning) (?<code>[^ ]+) (?<message>.*)$")]' > "$REPORT" 2>/dev/null
  # Walidacja kontraktu: raport MUSI być parsowalny. Pusty/uszkodzony = [].
  if ! jq empty "$REPORT" >/dev/null 2>&1; then
    printf '[]\n' > "$REPORT"
  fi
else
  printf '[]\n' > "$REPORT"
fi

# Fix 2026-09-22: wzorzec wymagał SPACJI po dwukropku, a markdownlint-cli2
# wypisuje 'plik:LINIA:KOLUMNA error CODE'. Licznik zwracał zawsze 0 → bramka
# raportowała '0 error' i PASS nawet przy dziesiątkach realnych defektów.
FINDINGS=$(grep -cE ':[0-9]+(:[0-9]+)? error ' "$ERR_LOG" 2>/dev/null || :)
WARNINGS=$(grep -cE ':[0-9]+(:[0-9]+)? warning ' "$ERR_LOG" 2>/dev/null || :)

# Uwaga (fix 2026-09-23) — TRZECI wariant tej samej klasy błędu, znaleziony
# dopiero po porównaniu licznika z podsumowaniem markdownlint (147 issues in
# 10 files vs 1 policzone przez bramkę):
#   markdownlint-cli2 NIE wypisuje kolumny dla wszystkich reguł. Linie wyglądają
#   `plik.md:26 error MD022/...` (BEZ kolumny) albo `plik.md:106:18 error MD060/...`
#   (Z kolumną) — zależnie od reguły. Poprzedni wzorzec wymagał `:LINIA:KOLUMNA`,
#   więc CAŁE reguły bez kolumny (MD022, MD024, MD025, MD003, MD041, MD036, MD033,
#   MD028) były NIEWIDOCZNE dla bramki: 146 z 147 znalezisk nie liczyło się.
#   Poprawnie: `:[0-9]+(:[0-9]+)? ` — kolumna opcjonalna.
#   Lekcja: licz TAK SAMO jak raportuje narzędzie, inaczej mierzysz własne
#   założenie o formacie, nie rzeczywistość.
# Weryfikacja krzyżowa: liczba znalezisk jest porównywana z „Summary: N issues"
# które markdownlint wypisuje sam — rozbieżność = FAIL (nie cicha tolerancja).
TOOL_SUMMARY=$(grep -oE 'Summary: [0-9]+ issues? in [0-9]+ files?' "$ERR_LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1)
TOOL_SUMMARY=${TOOL_SUMMARY:-}
if [ -n "$TOOL_SUMMARY" ] && [ "$TOOL_SUMMARY" -ne "$((FINDINGS + WARNINGS))" ]; then
  fail "MD-002b zgodność licznika z narzędziem" BLOCKING \
    "markdownlint podaje $TOOL_SUMMARY znalezisk, bramka policzyła $((FINDINGS + WARNINGS)) — wzorzec parsowania rozjechał się z formatem narzędzia"
  sed -n '/^Summary:/p' "$ERR_LOG" | tail -3
  verify_module_exit
fi
pass "MD-002b zgodność licznika z narzędziem" BLOCKING "licznik zgodny z podsumowaniem markdownlint (${FINDINGS} error, ${WARNINGS} warning)"

# ── Rozstrzygnięcie: BLOCKING (--strict) vs WARNING (staged rollout) ─
if [ "${FINDINGS:-0}" -gt 0 ]; then
  if [ "$STRICT" -eq 1 ]; then
    fail "MD-002 skan markdownlint" BLOCKING "$FINDINGS błęd(ów) Markdown w ${#FILES[@]} plikach — popraw przed commitem:"
    grep -E ':[0-9]+(:[0-9]+)? error ' "$ERR_LOG" | head -30
    echo "Raport: $REPORT"
    verify_module_exit
  else
    warn "MD-002 skan markdownlint" "$FINDINGS błęd(ów) Markdown w ${#FILES[@]} plikach (staged rollout — WARNING; użyj --strict by blokować)"
    grep -E ':[0-9]+(:[0-9]+)? error ' "$ERR_LOG" | head -20
  fi
fi
pass "MD-002 skan markdownlint" BLOCKING "skan zakończony (${FINDINGS:-0} error, ${WARNINGS:-0} warning w ${#FILES[@]} plikach)"

# ── MD-003: warningi (kosmetyka) ─────────────────────────────
if [ "${WARNINGS:-0}" -gt 0 ]; then
  info "MD-003 warningi markdownlint" "$WARNINGS uwag (level=warning, nie blokuje)"
else
  pass "MD-003 warningi markdownlint" BLOCKING "brak uwag markdownlint"
fi

# ── MD-004: raport JSON (kontrakt automatu) ─────────────────
# ── MD-004: raport JSON (kontrakt automatu) ─────────────────
# Sam niepusty plik to za mało — kontrakt mówi "raport JSON", więc weryfikujemy
# PARSOWALNOŚĆ (jq empty). Wcześniej wystarczyło `-s`, co przepuszczało plik
# będący ciągiem obiektów (nie JSON) jako PASS.
if [ -s "$REPORT" ] && jq empty "$REPORT" >/dev/null 2>&1; then
  pass "MD-004 raport JSON" BLOCKING "raport zapisany i parsowalny: $REPORT ($(jq 'length' "$REPORT" 2>/dev/null || echo '?') wpisów)"
else
  fail "MD-004 raport JSON" BLOCKING "raport nieparsowalny/niepusty — kontrakt automatu (artifacts/quality) naruszony"
fi

rm -f "$ERR_LOG"
verify_module_exit
