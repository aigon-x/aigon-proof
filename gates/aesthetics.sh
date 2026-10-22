#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# aesthetics/aesthetics.sh — Universal Project Template — AESTHETICS PLANE
# Orkiestrator modułu AESTHETICS: uruchamia trzy wyspecjalizowane
# świadków jako SUBPROCESY i agreguje ich wyniki.
#
#   spectral.sh  — AEST-08  API DESIGN LINT (spectral/vacuum na OpenAPI)
#   fitness.sh   — CONS-01  GOLDEN PATH CONFORMANCE (fitness functions)
#   qi.sh        — QI-001..005  QUALITY INDEX (kalkulator, wariant c)
#
# Każdy sub-skrypt kończy się `verify_module_exit` (exit $?), więc MUSI
# być uruchamiany jako subproces (bash spectral.sh), NIGDY source'owany —
# source'owanie zabiłoby ten orkiestrator przez exit.
#
# Fail-closed: każdy sub-skrypt z kodem != 0 = FAIL (BLOCKING) w tym
# orkiestratorze. Brak sub-skryptu = FAIL (BLOCKING), nigdy skip.
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

# Katalog z sub-skryptami (względem tego pliku — działa niezależnie od cwd).
AEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say "=== AESTHETICS PLANE — ORKIESTRATOR ==="

# ── Uruchomienie sub-skryptu i agregacja wyniku ─────────────
# Wzorzec jak run_module w verify.sh: subproces (bash), rc != 0 → FAIL
# (BLOCKING). Każdy sub-skrypt sam zapisuje evidence do StateStore.
run_aesthetics_module() {
  local name="$1"
  local script="$AEST_DIR/$name"
  if [ ! -f "$script" ]; then
    # FAIL-CLOSED (anti-drift): sub-skrypt zadeklarowany, a nieistniejący
    # = FAIL (BLOCKING), NIGDY skip (ghost gate).
    fail "aesthetics $name" BLOCKING "Brak sub-skryptu: $script (fail-closed)"
    evidence_record "verify:aesthetics:$name:MODULE-MISSING" "module" "aesthetics/$name"
    return
  fi
  say ""
  say "────────────────────────────────────────────────────────────"
  say "AESTHETICS SUB-MODUŁ: $name"
  say "────────────────────────────────────────────────────────────"
  bash "$script"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "aesthetics $name" BLOCKING "Sub-moduł zakończył się kodem $rc (oczekiwano 0)."
  fi
  # Evidence bridge (P0#1): każdy uruchomiony sub-moduł zapisuje wynik.
  evidence_record "verify:aesthetics:$name:rc=$rc" "module" "aesthetics/$name"
}

# ── Trzy świadków AESTHETICS PLANE ──────────────────────────
run_aesthetics_module "spectral.sh"
run_aesthetics_module "fitness.sh"
run_aesthetics_module "qi.sh"

# ── Evidence: orkiestrator zakończony ───────────────────────
evidence_record "verify:aesthetics:orchestrator:complete" "module" "aesthetics/aesthetics.sh"

verify_module_exit
