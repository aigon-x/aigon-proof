#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/sast.sh — GATE-045 SAST-SEMGREP
# Statyczna analiza kodu semgrep (2000+ reguł OSS, 30+ języków).
# Wykrywa błędy bezpieczeństwa, injection, path traversal, hardcoded
# secrets, unsafe deserialization itp.
#
# Zasada fail-closed: semgrep ZAINSTALOWANY = uruchamiany; znalezione
# błędy wysokiej pewności = BLOCKING FAIL. Brak semgrep = WARN.
#
# Użycie:
#   bash tools/verify/gates/domains/sast.sh
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-045 SAST-SEMGREP ==="

# ── SAST-001: semgrep dostępny ──────────────────────────────
if ! command -v semgrep >/dev/null 2>&1; then
  fail "SAST-001 semgrep dostępny" BLOCKING "semgrep nie jest zainstalowany — fail-closed (linter obowiązkowy)"
  verify_module_exit
fi
pass "SAST-001 semgrep dostępny" BLOCKING "semgrep: $(semgrep --version 2>/dev/null)"

# ── SAST-002: skan kodu ─────────────────────────────────────
# --config auto = 2000+ reguł OSS (pcre, owasp-top-ten, etc.)
# --error = exit 1 gdy znaleziono dopasowania (fail-closed)
# Wykluczamy katalogi narzędzi weryfikacyjnych (własne wzorce regex)
# i zależności (node_modules, .venv, venv, .git) — vendor nie jest naszym
# kodem; semgrep na site-packages daje ~122 FP na jedno repo.
# ── LIMITY (ZMIERZONE 2026-09-30) ───────────────────────────
# Semgrep domyślnie bierze `--jobs = liczba rdzeni` i NIE ma timeoutu.
# Zmierzone: `semgrep-core` pożerał cały host (load 166/24 rdzenie, przez co
# node_exporter :49090 zwracał 000 i Prometheus tracił próbki), a skan był
# wywoływany przez pre-commit hooka. Limity są konfigurowalne (env), z sensownym
# zapasem: domyślnie 4 zadania (nie 24) i 15 min sufitu.
# --max-target-bytes: korpusy/dumpy JSONL nie są kodem — bez tego semgrep
# czyta setki MB danych. datasets/bench/reports to DANE, nie kod.
SEMGREP_JOBS="${AIGON_SEMGREP_JOBS:-4}"
SEMGREP_MAX_BYTES="${AIGON_SEMGREP_MAX_TARGET_BYTES:-2000000}"
SEMGREP_TIMEOUT="${AIGON_SEMGREP_TIMEOUT:-900}"

set +e
timeout "$SEMGREP_TIMEOUT" semgrep scan --config auto --error --quiet \
  --jobs "$SEMGREP_JOBS" --max-target-bytes "$SEMGREP_MAX_BYTES" \
  --exclude=.git --exclude=node_modules --exclude=.venv --exclude=venv --exclude=out \
  --exclude=tools/verify --exclude=tools/automation \
  --exclude=datasets --exclude=bench --exclude=reports --exclude=_archive \
  --exclude='*.evidence' --exclude='*.md' \
  . >/tmp/semgrep-out.$$ 2>&1
SEMGREP_RC=$?
set -e

if [ "$SEMGREP_RC" -eq 124 ]; then
  # PRZEKROCZONY CZAS != brak znalezisk. Brak pomiaru nie może udawać ani
  # FAIL (blokowałby WSZYSTKICH na zawsze), ani PASS (ukrywałby defekty).
  warn "SAST-002 skan semgrep" \
    "PRZEKROCZONO LIMIT ${SEMGREP_TIMEOUT}s (jobs=$SEMGREP_JOBS) — brak rozstrzygnięcia. Podnieś AIGON_SEMGREP_TIMEOUT/AIGON_SEMGREP_JOBS albo zawęź zakres."
  rm -f /tmp/semgrep-out.$$
  verify_module_exit
fi

if [ "$SEMGREP_RC" -ne 0 ]; then
  # semgrep podaje liczbę findings w nagłówku "N Code Findings"; fallback:
  # liczba linii dopasowań (❯❱) = liczba (plik, reguła) par.
  FINDINGS=$(grep -oE '[0-9]+ Code Findings' /tmp/semgrep-out.$$ 2>/dev/null | grep -oE '[0-9]+' | head -1)
  [ -z "$FINDINGS" ] && FINDINGS=$(grep -cE '❯❱' /tmp/semgrep-out.$$ 2>/dev/null || echo 0)
  fail "SAST-002 skan semgrep" BLOCKING "$FINDINGS znalezionych dopasowań semgrep (reguły auto) — popraw przed mergem:"
  # Format semgrep 1.x: ścieżka → reguła (❯❱) → opis → numer linii (┆).
  grep -E '^    \.|❯❱|❰❰|┆|Details:' /tmp/semgrep-out.$$ 2>/dev/null | head -60
  rm -f /tmp/semgrep-out.$$
  verify_module_exit
fi
pass "SAST-002 skan semgrep" BLOCKING "semgrep: brak dopasowań (reguły auto; jobs=$SEMGREP_JOBS)"

rm -f /tmp/semgrep-out.$$

verify_module_exit
