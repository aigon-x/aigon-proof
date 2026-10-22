#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# self-profile-integrity.sh — SELF-001 — Profile Integrity Gate
# Universal Project Template — Repository Certification Engine
#
# SELF-001 weryfikuje integralność profili: każdy moduł zadeklarowany
# w VERIFY_MODULES (profiles.sh) MUSI istnieć i być wykonywalny.
# Moduł zadeklarowany, a nieistniejący = FAIL (BLOCKING), NIGDY skip.
#
# To jest META-GATE (gate o gate'ach): chroni przed ghost modułami,
# które deklarują zdolność, ale nie mają implementacji. Bez tego
# drift wraca po 3 miesiącach (FALSE GATE). Spójne z zasadą anti-drift.
#
# Użycie: ./self-profile-integrity.sh
# ─────────────────────────────────────────────────────────────
set -u

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Wczytaj core ────────────────────────────────────────────
. "$VERIFY_DIR/core/lib.sh"
. "$VERIFY_DIR/core/profiles.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

# ── SELF-001: integralność profili ──────────────────────────
# Iteruje po wszystkich modułach zadeklarowanych w VERIFY_MODULES.
# Dla każdego sprawdza: (1) module_script zwraca niepustą ścieżkę,
# (2) plik istnieje. Brak pliku = FAIL (BLOCKING) — to jest ghost
# detection. Wykonywalność (bit x) to WARN: moduły są uruchamiane
# przez `bash "$script"`, więc bit x nie jest wymagany do działania,
# ale jego brak to sygnał, że plik nie był przygotowany jako gate.
# Każdy brak = FAIL (BLOCKING). Na końcu zapisuje evidence (P0#1).
self_profile_integrity() {
  local declared=0 missing=0 notexec=0
  local entry module script
  for entry in "${VERIFY_MODULES[@]}"; do
    module="${entry%%:*}"
    declared=$((declared+1))
    script="$(module_script "$module")"
    if [ -z "$script" ]; then
      missing=$((missing+1))
      fail "SELF-001 module $module" BLOCKING "Brak mapowania w module_script (ghost moduł)"
      continue
    fi
    # KOREKTA 2026-10-19: moduły deklarowane w gates.yaml jako `script: X.sh`
    # leżą w katalogu gates/domains/ (tak uruchamia je runner profili),
    # a ta bramka szukała WYŁĄCZNIE w $VERIFY_DIR/X.sh → 21 FAŁSZYWYCH „ghost
    # moduł" (mesh-ui-parity, map-graph-artifact, llm-lane-truth...) i blokada
    # pre-commit całej flocie. Sprawdzamy oba układy: płaski i domains/.
    local sp="$VERIFY_DIR/$script"
    if [ ! -f "$sp" ] && [ -f "$VERIFY_DIR/domains/$(basename "$script")" ]; then
      sp="$VERIFY_DIR/domains/$(basename "$script")"
      script="domains/$(basename "$script")"
    fi
    # VERIFY_DIR to tools/verify, a moduły-runnery żyją w tools/verify/gates/domains/.
    if [ ! -f "$sp" ] && [ -f "$VERIFY_DIR/gates/domains/$(basename "$script")" ]; then
      sp="$VERIFY_DIR/gates/domains/$(basename "$script")"
      script="gates/domains/$(basename "$script")"
    fi
    if [ ! -f "$sp" ]; then
      missing=$((missing+1))
      fail "SELF-001 module $module" BLOCKING "Brak skryptu: $script (ghost moduł)"
      continue
    fi
    if [ ! -x "$sp" ]; then
      notexec=$((notexec+1))
      warn "SELF-001 module $module" "Skrypt nie jest wykonywalny (bit x): $script"
    fi
    pass "SELF-001 module $module" BLOCKING "Skrypt istnieje: $script"
  done

  # Evidence bridge (P0#1): wynik SELF-001 trafia do StateStore.
  if [ "$missing" -eq 0 ]; then
    evidence_record "verify:self-profile-integrity:PASS declared=$declared" "verify" "self-profile-integrity.sh"
  else
    evidence_record "verify:self-profile-integrity:FAIL declared=$declared missing=$missing" "verify" "self-profile-integrity.sh"
  fi
}

self_profile_integrity

# ── Zakończenie ─────────────────────────────────────────────
verify_module_exit
