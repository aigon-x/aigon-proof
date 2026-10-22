#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/resilience.sh — GATE-039 RESILIENCE
# Weryfikuje warstwę odporności (HA/DR/Backup): config/registry.yaml ma
# klucze resilience (rto/rpo/restore_drill_max_age/dr_game_day_max_age +
# floors per tier), state.sh ma backup/restore/backup-restore-test, istnieje
# pipeline restore drill (tools/resilience/restore-drill/), migration
# 0014_resilience.sql istnieje.
# Checks RES-B-01..04: pokrycie backupu, restore drill, immutability, retention.
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-039 RESILIENCE ==="

REGISTRY_YAML="./runtime/tools/sigil/config/registry.yaml"
STATE_SH="./system/control-plane/state/state.sh"
RESTORE_DRILL="./tools/resilience/restore-drill/restore-drill.sh"
MIGRATION_0014="./system/control-plane/state/migrations/0014_resilience.sql"

# ── RES-B-01: pokrycie backupu — registry.yaml ma klucze resilience ────────
# Kanoniczne źródło prawdy dla RTO/RPO/floors. Bez tych kluczy nie ma
# zdefiniowanych wymagań odporności → brak pokrycia backupu.
if [ -f "$REGISTRY_YAML" ]; then
  if grep -qE '^resilience:' "$REGISTRY_YAML" 2>/dev/null \
     && grep -qE '^\s+rto:' "$REGISTRY_YAML" 2>/dev/null \
     && grep -qE '^\s+rpo:' "$REGISTRY_YAML" 2>/dev/null \
     && grep -qE '^\s+restore_drill_max_age:' "$REGISTRY_YAML" 2>/dev/null \
     && grep -qE '^\s+dr_game_day_max_age:' "$REGISTRY_YAML" 2>/dev/null \
     && grep -qE '^\s+floors:' "$REGISTRY_YAML" 2>/dev/null; then
    pass "RES-B-01 registry.yaml ma klucze resilience" BLOCKING "rto/rpo/restore_drill_max_age/dr_game_day_max_age/floors obecne."
  else
    fail "RES-B-01 registry.yaml ma klucze resilience" BLOCKING "Brak wymaganych kluczy resilience w config/registry.yaml."
  fi
else
  fail "RES-B-01 registry.yaml ma klucze resilience" BLOCKING "Brak config/registry.yaml."
fi

# ── RES-B-02: restore drill — state.sh ma backup/restore + pipeline istnieje ─
# Restore drill to end-to-end dowód restorowalności. Wymaga komend backup/
# restore/backup-restore-test w state.sh ORAZ pipeline restore-drill.sh.
if [ -f "$STATE_SH" ]; then
  if grep -qE 'backup' "$STATE_SH" 2>/dev/null \
     && grep -qE 'restore' "$STATE_SH" 2>/dev/null \
     && grep -qE 'backup-restore-test' "$STATE_SH" 2>/dev/null; then
    pass "RES-B-02 state.sh ma backup/restore/backup-restore-test" BLOCKING "state.sh obsługuje backup/restore/backup-restore-test."
  else
    fail "RES-B-02 state.sh ma backup/restore/backup-restore-test" BLOCKING "state.sh nie ma backup/restore/backup-restore-test."
  fi
else
  fail "RES-B-02 state.sh ma backup/restore/backup-restore-test" BLOCKING "Brak state.sh."
fi

if [ -f "$RESTORE_DRILL" ]; then
  pass "RES-B-02 pipeline restore drill istnieje" BLOCKING "tools/resilience/restore-drill/restore-drill.sh obecny."
else
  fail "RES-B-02 pipeline restore drill istnieje" BLOCKING "Brak tools/resilience/restore-drill/restore-drill.sh."
fi

# ── RES-B-03: immutability — backup ma hash + weryfikację integralności ────
# Backup musi być immutable (hash) i weryfikowalny (backup-verify). Bez tego
# nie można udowodnić że backup nie został zmodyfikowany.
# Uwaga: komenda backup-verify jest w state.sh (dispatcher), a implementacja
# sha256 (hash + .sha256 checksum) w lib.sh — sprawdzamy OBA pliki.
STATE_LIB="./system/control-plane/state/lib.sh"
if [ -f "$STATE_SH" ]; then
  if grep -qE 'backup-verify' "$STATE_SH" 2>/dev/null \
     && { grep -qE 'sha256' "$STATE_SH" 2>/dev/null || grep -qE 'sha256' "$STATE_LIB" 2>/dev/null; }; then
    pass "RES-B-03 backup immutable (hash + backup-verify)" BLOCKING "state.sh ma backup-verify; sha256 w state.sh/lib.sh."
  else
    fail "RES-B-03 backup immutable (hash + backup-verify)" BLOCKING "state.sh nie ma backup-verify/sha256."
  fi
else
  fail "RES-B-03 backup immutable (hash + backup-verify)" BLOCKING "Brak state.sh."
fi

# ── RES-B-04: retention — state.sh ma backup-retention + migration 0014 ────
# Retention chroni przed niekontrolowanym wzrostem backupów. Migration 0014
# definiuje backup_catalog/resilience_requirements/game_days/spof_findings.
if [ -f "$STATE_SH" ]; then
  if grep -qE 'backup-retention' "$STATE_SH" 2>/dev/null; then
    pass "RES-B-04 state.sh ma backup-retention" BLOCKING "state.sh obsługuje backup-retention."
  else
    fail "RES-B-04 state.sh ma backup-retention" BLOCKING "state.sh nie ma backup-retention."
  fi
else
  fail "RES-B-04 state.sh ma backup-retention" BLOCKING "Brak state.sh."
fi

if [ -f "$MIGRATION_0014" ]; then
  if grep -qE 'CREATE TABLE.*backup_catalog' "$MIGRATION_0014" 2>/dev/null \
     && grep -qE 'CREATE TABLE.*resilience_requirements' "$MIGRATION_0014" 2>/dev/null \
     && grep -qE 'CREATE TABLE.*game_days' "$MIGRATION_0014" 2>/dev/null \
     && grep -qE 'CREATE TABLE.*spof_findings' "$MIGRATION_0014" 2>/dev/null; then
    pass "RES-B-04 migration 0014_resilience.sql istnieje" BLOCKING "Tabele backup_catalog/resilience_requirements/game_days/spof_findings zdefiniowane."
  else
    fail "RES-B-04 migration 0014_resilience.sql istnieje" BLOCKING "Migration 0014 nie definiuje wymaganych tabel."
  fi
else
  fail "RES-B-04 migration 0014_resilience.sql istnieje" BLOCKING "Brak migration 0014_resilience.sql."
fi

verify_module_exit
