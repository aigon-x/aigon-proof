#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/yaml-lint.sh — GATE-049 YAML-LINT
# Lint plików YAML (yamllint) — wykrywa realne defekty, których
# parsery wprost nie łapią: złą indentyfikację, duplikaty kluczy,
# trailing spaces, brakujące wartości, kolumnowe wyrównanie
# (colons > kanon), flow style braces, "on:" w GitHub workflows.
#
# Konfiguracja: .yamllint (korzeń repo) — pomiar na 44 plikach YAML
# template (2026-08-15): line-length 200 (warning), colons max 15,
# braces max 1, truthy on/off (GH Actions). Realne defekty = error
# (BLOCKING), długie linie = warning (INFO, celowe tabele configów).
#
# CHANGE-AWARE (default): lintuje TYLKO zmienione pliki .yaml/.yml
# (staged / ostatni commit) — nowa zmiana nie może wprowadzać
# defektów YAML. --all: pełny skan całego repo (CI/RELEASE/GENESIS).
#
# Fail-closed: błąd yamllint (level=error) w skanowanym pliku =
# BLOCKING FAIL z file:line (parsable format). level=warning = INFO.
# Brak plików YAML do skanu = PASS (N/A nie jest FAIL).
#
# Kontrakt automatu (sekcja 9 QUALITY-AUTOMATA-PLAN):
#   raport JSON zawsze zapisany → artifacts/quality/yamllint/
#   brak yamllint = WARN (nigdy cichy PASS / FALSE GREEN)
#
# Użycie:
#   bash yaml-lint.sh            # change-aware (zmienione .yaml/.yml)
#   bash yaml-lint.sh --all      # pełny skan wszystkich YAML
#   bash yaml-lint.sh <file>...  # jawne pliki (testy)
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

# ── FIX 2026-10-16 — yamllint osiągalny dla KAŻDEGO wywołującego ───────────
# Reaktor bramkarza chodzi jako root (HOME=/root, PATH minimalny), a linter
# żyje w user-site OPERATORA (/home/sniegul/.local, python3.12). Root ma inny
# user-site → modułu nie ma. Ta sama klasa co project-visual-verification /
# law-action-budget (HOME-zależność). ZERO zmian semantyki — dokładamy
# WYŁĄCZNIE zdolność ZNALEZIENIA lintera, niezależnie od tego KTO woła bramkę.
HOME_OPER="${AIGON_OPER_HOME:-/home/sniegul}"
if ! command -v yamllint >/dev/null 2>&1; then
  export PATH="$HOME_OPER/.local/bin:$PATH"
fi
if ! yamllint --version >/dev/null 2>&1; then
  for _site in "$HOME_OPER"/.local/lib/python3.*/site-packages; do
    [ -d "$_site/yamllint" ] || continue
    _py="/usr/bin/$(basename "$(dirname "$_site")")"
    [ -x "$_py" ] || _py="/usr/bin/python3"
    if PYTHONPATH="$_site${PYTHONPATH:+:$PYTHONPATH}" "$_py" -m yamllint --version >/dev/null 2>&1; then
      export PYTHONPATH="$_site${PYTHONPATH:+:$PYTHONPATH}"
      yamllint() { "$_py" -m yamllint "$@"; }
      break
    fi
  done
  unset _site
fi

say "=== GATE-049 YAML-LINT (yamllint) ==="

OUT_DIR="artifacts/quality/yamllint"
mkdir -p "$OUT_DIR"

# ── YAML-001: yamllint dostępny ─────────────────────────────
if ! command -v yamllint >/dev/null 2>&1; then
  fail "YAML-001 yamllint dostępny" BLOCKING "yamllint nie zainstalowany — fail-closed (linter obowiązkowy)"
  verify_module_exit
fi
pass "YAML-001 yamllint dostępny" BLOCKING "yamllint: $(yamllint --version 2>/dev/null | awk '{print $2; exit}')"

# ── Wybór plików do skanu ───────────────────────────────────
FILES=()
MODE="changed"
if [ "$#" -gt 0 ] && [ "$1" = "--all" ]; then
  MODE="all"
elif [ "$#" -gt 0 ]; then
  MODE="explicit"
  FILES=("$@")
fi

skip_path() { case "$1" in .qwen/*|node_modules/*|vendor/*|target/*|artifacts/*) return 0 ;; esac; return 1; }

case "$MODE" in
  all)
    # Pełny skan: wszystkie śledzone pliki YAML (repo_files = git ls-files)
    while IFS= read -r f; do
      skip_path "$f" && continue
      FILES+=("$f")
    done < <(repo_files --name '\.ya?ml$')
    ;;
  explicit)
    : # FILES ustawione przez argumenty
    ;;
  changed)
    # Change-aware: staged (pre-commit) albo ostatni commit (pre-push)
    # set -u tylko (bez set -e): nieudany git diff = puste wyjście, nie exit.
    files="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)"
    if [ -z "$files" ]; then
      files="$(git diff --name-only HEAD~1..HEAD 2>/dev/null)"
    fi
    while IFS= read -r f; do
      case "$f" in
        *.yaml|*.yml) skip_path "$f" && continue; FILES+=("$f") ;;
      esac
    done <<< "$files"
    ;;
esac

if [ "${#FILES[@]}" -eq 0 ]; then
  info "YAML-002 skan yamllint" "brak plików YAML do skanu (change-aware: nic nie zmieniono)"
  verify_module_exit
fi

# ── YAML-002: skan (fail-closed) ────────────────────────────
REPORT="$OUT_DIR/yamllint-$(date +%Y%m%d-%H%M%S).json"
ERR_LOG="$OUT_DIR/yamllint-invocation.$$"

# yamllint -f parsable → "file:line:col: [level] message (rule)"
# -f json dostępny od 1.28 — parsable jest stabilnym kontraktem.
yamllint -f parsable "${FILES[@]}" > "$REPORT" 2> "$ERR_LOG"
YAML_EXIT=$?

if [ "$YAML_EXIT" -eq 2 ]; then
  # exit 2 = błąd wywołania (np. brak pliku)
  fail "YAML-002 skan yamllint" BLOCKING "yamllint exit 2 (błąd wywołania):"
  sed -n '1,10p' "$ERR_LOG"
  rm -f "$ERR_LOG"
  verify_module_exit
fi
rm -f "$ERR_LOG"

# Klasyfikacja: [error] = BLOCKING, [warning] = INFO.
# yamllint parsable: "path:line:col: [error] message (rule)"
# FIX 2026-09-21: `grep -c` przy ZERO trafień wypisuje "0" I zwraca exit 1,
# więc `|| echo 0` dokładało DRUGIE zero → zmienna = "0\n0" → `[ -gt ]`
# wywalało "oczekiwano wyrażenia całkowitego" (zmierzone: linia 126).
# `grep -c` ZAWSZE wypisuje liczbę, więc `|| echo 0` jest zbędne i szkodliwe.
# Dodatkowo `|| true` chroni przed `set -e` w wołającym.
ERRORS=$(grep -cE ': \[(error|Error)\] ' "$REPORT" 2>/dev/null)
ERRORS=${ERRORS:-0}
WARNINGS=$(grep -cE ': \[(warning|Warning)\] ' "$REPORT" 2>/dev/null)
WARNINGS=${WARNINGS:-0}
# Twarda normalizacja: cokolwiek nie jest liczbą → 0 (fail-open na braku
# danych, bo brak uwag nie może być błędem).
case "$ERRORS" in ''|*[!0-9]*) ERRORS=0 ;; esac
case "$WARNINGS" in ''|*[!0-9]*) WARNINGS=0 ;; esac

if [ "${ERRORS:-0}" -gt 0 ]; then
  fail "YAML-002 skan yamllint" BLOCKING "$ERRORS błęd(ów) YAML w ${#FILES[@]} plikach — popraw przed commitem:"
  grep -E ': \[(error|Error)\] ' "$REPORT" | head -30
  echo "Raport: $REPORT"
  verify_module_exit
fi
pass "YAML-002 skan yamllint" BLOCKING "brak błędów YAML w ${#FILES[@]} plikach (yamllint)"

# ── YAML-003: warningi (kosmetyka / długie linie) ───────────
if [ "${WARNINGS:-0}" -gt 0 ]; then
  info "YAML-003 warningi yamllint" "$WARNINGS uwag (level=warning, nie blokuje; zwykle line-length > 200)"
else
  pass "YAML-003 warningi yamllint" BLOCKING "brak uwag yamllint"
fi

# ── YAML-004: raport (kontrakt automatu) ────────────────────
# FIX 2026-09-21 — ten check był SAMO-SPRZECZNY i zapalał FAIL za brak
# błędów. `yamllint -f parsable` nie wypisuje NIC, gdy pliki są czyste, więc
# raport miał 0 B i `[ -s ]` zawodził → "raport pusty". Zmierzone: wszystkie
# raporty w artifacts/quality/yamllint/ od 2026-09-06 do 2026-09-21 mają 0 B
# (m.in. yamllint-20260920-150019.json, czyli sprzed tej sesji) — check
# failował zawsze, gdy kod był poprawny.
# Kontrakt automatu to "skan wykonany i raport zapisany", a nie "raport ma
# treść": brak treści JEST poprawnym wynikiem czystego skanu. Rozróżniamy
# więc dwie sytuacje jawnie:
#   - plik nie istnieje        → FAIL (skan się nie wykonał)
#   - plik istnieje i pusty    → PASS (skan wykonany, zero uwag)
if [ -f "$REPORT" ]; then
  if [ -s "$REPORT" ]; then
    pass "YAML-004 raport" BLOCKING "raport zapisany ($(wc -c < "$REPORT") B): $REPORT"
  else
    pass "YAML-004 raport" BLOCKING \
      "skan wykonany, zero uwag — raport pusty z definicji (yamllint -f parsable milczy przy czystych plikach)"
  fi
else
  fail "YAML-004 raport" BLOCKING "brak pliku raportu — skan yamllint nie został wykonany: $REPORT"
fi

verify_module_exit
