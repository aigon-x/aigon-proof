#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/shell-static.sh — GATE-048 SHELL-STATIC
# Statyczna analiza skryptów bash (shellcheck) — wykrywa realne
# bugi, których `bash -n` nie widzi: SC2086 (unquoted expansion),
# SC2046 (command substitution bez quotes), SC2164 (cd bez || exit),
# SC2155, SC2181, SC2206...
#
# CHANGE-AWARE (default): skanuje TYLKO zmienione pliki .sh
# (staged / ostatni commit) — nowa zmiana nie może wprowadzać
# błędów bash. --all: pełny skan całego repo (CI/RELEASE/GENESIS).
#
# Fail-closed: znalezisko level=error|warning|info (SC2086/SC2046/
# SC2164 = realne bugi) w skanowanym pliku = BLOCKING FAIL z file:line.
# level=style (kosmetyka) = INFO, nie blokuje.
#
# Wykluczenia (uzasadnione pomiarem dla tego repo, 812 trafień):
#   SC1091 — "not following" dla `source lib.sh` (378 FP)
#   SC2034 — unused variable (84, celowe API modułów)
#   SC2317 — unreachable po verify_module_exit (26)
#
# Kontrakt automatu (sekcja 9 QUALITY-AUTOMATA-PLAN):
#   raport JSON zawsze zapisany → artifacts/quality/shellcheck/
#   liczba znalezisk w p_evidence (SHELL-002)
#   brak shellcheck = WARN (nigdy cichy PASS / FALSE GREEN)
#
# Użycie:
#   bash shell-static.sh            # change-aware (zmienione .sh)
#   bash shell-static.sh --all      # pełny skan wszystkich .sh
#   bash shell-static.sh <file>...  # jawne pliki (testy)
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-048 SHELL-STATIC (shellcheck) ==="

OUT_DIR="artifacts/quality/shellcheck"
mkdir -p "$OUT_DIR"

# ── SHELL-001: shellcheck dostępny ──────────────────────────
if ! command -v shellcheck >/dev/null 2>&1; then
  fail "SHELL-001 shellcheck dostępny" BLOCKING "shellcheck nie zainstalowany — fail-closed (linter obowiązkowy)"
  verify_module_exit
fi
pass "SHELL-001 shellcheck dostępny" BLOCKING "shellcheck: $(shellcheck --version 2>/dev/null | awk '/version:/{print $2; exit}')"

# ── Wybór plików do skanu ───────────────────────────────────
EXCLUDES=(--exclude=SC1091 --exclude=SC2034 --exclude=SC2317)

FILES=()
MODE="changed"
if [ "$#" -gt 0 ] && [ "$1" = "--all" ]; then
  MODE="all"
elif [ "$#" -gt 0 ]; then
  MODE="explicit"
  FILES=("$@")
fi

skip_path() { case "$1" in .qwen/*|node_modules/*|vendor/*|target/*|system/control-plane/state/*) return 0 ;; esac; return 1; }

case "$MODE" in
  all)
    # Pełny skan: wszystkie śledzone pliki .sh (repo_files = git ls-files)
    while IFS= read -r f; do
      skip_path "$f" && continue
      FILES+=("$f")
    done < <(repo_files --name '\.sh$')
    ;;
  explicit)
    : # FILES ustawione przez argumenty
    ;;
  changed)
    # Change-aware: staged (pre-commit) albo ostatni commit (pre-push)
    # set -u tylko (bez set -e): nieudany git diff = puste wyjście, nie exit.
    files="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)"
    if [ -z "$files" ]; then
      # --diff-filter=ACM: pomija DELETED (usunięte pliki nie istnieją na dysku
      # → shellcheck exit 2 openBinaryFile; np. po usunięciu toggle_skill.sh)
      files="$(git diff --name-only --diff-filter=ACM HEAD~1..HEAD 2>/dev/null)"
    fi
    while IFS= read -r f; do
      case "$f" in
        *.sh) skip_path "$f" && continue; FILES+=("$f") ;;
      esac
    done <<< "$files"
    ;;
esac

if [ "${#FILES[@]}" -eq 0 ]; then
  info "SHELL-002 skan shellcheck" "brak plików .sh do skanu (change-aware: nic nie zmieniono)"
  verify_module_exit
fi

# ── SHELL-002: skan (fail-closed) ───────────────────────────
REPORT="$OUT_DIR/shellcheck-$(date +%Y%m%d-%H%M%S).json"
ERR_LOG="$OUT_DIR/shellcheck-invocation.$$"

shellcheck -f json "${EXCLUDES[@]}" "${FILES[@]}" > "$REPORT" 2> "$ERR_LOG"
SC_EXIT=$?

if [ "$SC_EXIT" -eq 2 ]; then
  # exit 2 = błąd wywołania / składni pliku (nie znaleziska)
  fail "SHELL-002 skan shellcheck" BLOCKING "shellcheck exit 2 (błąd wywołania/składni):"
  sed -n '1,10p' "$ERR_LOG"
  rm -f "$ERR_LOG"
  verify_module_exit
fi
rm -f "$ERR_LOG"

if command -v jq >/dev/null 2>&1; then
  FINDINGS=$(jq '[.[] | select(.level != "style")] | length' "$REPORT" 2>/dev/null || echo 0)
  STYLE=$(jq '[.[] | select(.level == "style")] | length' "$REPORT" 2>/dev/null || echo 0)
else
  # Fallback bez jq: grep na liniach JSON (level:error|warning|info)
  FINDINGS=$(grep -cE '"level":"(error|warning|info)"' "$REPORT" 2>/dev/null || echo 0)
  STYLE=$(grep -cE '"level":"style"' "$REPORT" 2>/dev/null || echo 0)
fi

if [ "${FINDINGS:-0}" -gt 0 ]; then
  fail "SHELL-002 skan shellcheck" BLOCKING "$FINDINGS błęd(ów) bash w ${#FILES[@]} plikach — popraw przed commitem:"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.[] | select(.level != "style") | "\(.file):\(.line):\(.column): \(.code) \(.message)"' "$REPORT" | head -30
  else
    sed -n '1,30p' "$REPORT"
  fi
  echo "Raport: $REPORT"
  verify_module_exit
fi
pass "SHELL-002 skan shellcheck" BLOCKING "brak błędów bash w ${#FILES[@]} plikach (shellcheck)"

# ── SHELL-003: styl (kosmetyka) ─────────────────────────────
if [ "${STYLE:-0}" -gt 0 ]; then
  info "SHELL-003 styl shellcheck" "$STYLE uwag stylistycznych (nie blokuje)"
else
  pass "SHELL-003 styl shellcheck" BLOCKING "brak uwag stylistycznych"
fi

# ── SHELL-004: raport JSON (kontrakt automatu) ──────────────
if [ -s "$REPORT" ]; then
  pass "SHELL-004 raport JSON" BLOCKING "raport zapisany: $REPORT"
else
  fail "SHELL-004 raport JSON" BLOCKING "raport pusty — kontrakt automatu (artifacts/quality) naruszony"
fi

verify_module_exit
