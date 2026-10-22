#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/ci-workflow.sh — GATE-051 CI-WORKFLOW
# Lint GitHub Actions workflows (actionlint) — wykrywa realne
# błędy w .github/workflows/: złą składnię YAML, błędne wyrażenia
# ${{ }}, nieistniejące akcje/versje, brakujące pola, deprecated
# syntax. Znacznie mocniejszy niż sam parse YAML — zna semantykę
# GitHub Actions.
#
# CHANGE-AWARE (default): lintuje TYLKO zmienione workflow
# (staged / ostatni commit) — nowa zmiana nie może psuć CI.
# --all: pełny skan wszystkich workflow (CI/RELEASE/GENESIS).
#
# Fail-closed: znalezisko actionlint = BLOCKING FAIL z file:line.
# Brak workflow w repo = PASS (N/A nie jest FAIL).
#
# Kontrakt automatu (sekcja 9 QUALITY-AUTOMATA-PLAN):
#   raport JSON zawsze zapisany → artifacts/quality/actionlint/
#   brak actionlint = WARN (nigdy cichy PASS / FALSE GREEN)
#
# Uwagi implementacyjne (pomierzone 2026-08-15):
#   - actionlint wymaga kontekstu repo git (szuka projektu); exit 3
#     "no project was found" gdy brak .git lub brak workflows.
#   - `-format '{{json .}}'` → JSON array na STDOUT, rc=1 przy błędach.
#   - na broken workflow JSON jest poprawny; na czystym: "[]".
#
# Użycie:
#   bash ci-workflow.sh            # change-aware (zmienione workflow)
#   bash ci-workflow.sh --all      # pełny skan wszystkich workflow
#   bash ci-workflow.sh <file>...  # jawne pliki (testy)
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-051 CI-WORKFLOW (actionlint) ==="

OUT_DIR="artifacts/quality/actionlint"
mkdir -p "$OUT_DIR"

# ── CI-001: actionlint dostępny ─────────────────────────────
if ! command -v actionlint >/dev/null 2>&1; then
  fail "CI-001 actionlint dostępny" BLOCKING "actionlint nie zainstalowany — fail-closed (linter obowiązkowy)"
  verify_module_exit
fi
pass "CI-001 actionlint dostępny" BLOCKING "actionlint: $(actionlint --version 2>/dev/null | awk '{print $2; exit}')"

# ── Wybór plików do skanu ───────────────────────────────────
FILES=()
MODE="changed"
if [ "$#" -gt 0 ] && [ "$1" = "--all" ]; then
  MODE="all"
elif [ "$#" -gt 0 ]; then
  MODE="explicit"
  FILES=("$@")
fi

case "$MODE" in
  all)
    # Pełny skan: wszystkie śledzone workflow (repo_files = git ls-files)
    while IFS= read -r f; do
      case "$f" in
        .github/workflows/*.yml|.github/workflows/*.yaml) FILES+=("$f") ;;
      esac
    done < <(repo_files --name '\.ya?ml$')
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
        .github/workflows/*.yml|.github/workflows/*.yaml) FILES+=("$f") ;;
      esac
    done <<< "$files"
    ;;
esac

if [ "${#FILES[@]}" -eq 0 ]; then
  # Brak workflow w repo lub brak zmian — N/A nie jest FAIL.
  # (actionlint exit 3 na repo bez workflows — sprawdzamy pliki wprost.)
  info "CI-002 skan actionlint" "brak workflow do skanu (change-aware: nic nie zmieniono)"
  verify_module_exit
fi

# ── CI-002: skan (fail-closed) ──────────────────────────────
REPORT="$OUT_DIR/actionlint-$(date +%Y%m%d-%H%M%S).json"
ERR_LOG="$OUT_DIR/actionlint-invocation.$$"

# JSON array na stdout; rc: 0=czysto, 1=znaleziska, 3=błąd środowiska.
actionlint -format '{{json .}}' "${FILES[@]}" > "$REPORT" 2> "$ERR_LOG"
AL_EXIT=$?

if [ "$AL_EXIT" -eq 3 ]; then
  # exit 3 = brak projektu/workflows (np. repo bez .github/workflows)
  warn "CI-002 skan actionlint" "actionlint exit 3 (brak projektu/workflows):"
  sed -n '1,5p' "$ERR_LOG"
  rm -f "$ERR_LOG"
  verify_module_exit
fi
rm -f "$ERR_LOG"

if command -v jq >/dev/null 2>&1; then
  FINDINGS=$(jq 'length' "$REPORT" 2>/dev/null || echo 0)
else
  FINDINGS=$(grep -cE '"filepath"' "$REPORT" 2>/dev/null || echo 0)
fi

if [ "${FINDINGS:-0}" -gt 0 ]; then
  fail "CI-002 skan actionlint" BLOCKING "$FINDINGS błęd(ów) w workflow — popraw przed commitem:"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.[] | "\(.filepath):\(.line):\(.column): \(.kind) \(.message)"' "$REPORT" | head -30
  else
    sed -n '1,30p' "$REPORT"
  fi
  echo "Raport: $REPORT"
  verify_module_exit
fi
pass "CI-002 skan actionlint" BLOCKING "brak błędów w ${#FILES[@]} workflow (actionlint)"

# ── CI-003: raport JSON (kontrakt automatu) ─────────────────
if [ -s "$REPORT" ]; then
  pass "CI-003 raport JSON" BLOCKING "raport zapisany: $REPORT"
else
  fail "CI-003 raport JSON" BLOCKING "raport pusty — kontrakt automatu (artifacts/quality) naruszony"
fi

verify_module_exit
