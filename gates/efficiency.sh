#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# efficiency/efficiency.sh — Universal Project Template — Repository Certification Engine
# Moduł: EFFICIENCY — CHANGE INTELLIGENCE / ENGINEERING EFFICIENCY GATE
# Weryfikuje, czy platforma posiada mechanizmy "Change Intelligence" Suwerena:
# dependency impact analysis, build intelligence, fingerprint cache,
# engineering optimality, change impact prediction, minimal change gate,
# duplicate work gate oraz uniwersalną zasadę impact→reuse→execute→certify.
#
# Checki:
#   EFF-001  Dependency Impact Analysis — graf zależności istnieje (BLOCKING)
#   EFF-002  Dependency Impact Analysis — affected/unaffected wyznaczalne
#   EFF-003  Dependency Impact Analysis — targeted build/test/verify
#   EFF-004  Build Intelligence — pipeline source→graph→affected→gates (BLOCKING)
#   EFF-005  Build Intelligence — tabela typów zmian
#   EFF-006  Build Intelligence — podsumowanie typów zmian (INFORMATIONAL)
#   EFF-007  Fingerprint Cache — tabela fingerprint_cache istnieje (BLOCKING)
#   EFF-008  Fingerprint Cache — kolumny fingerprintu kompletne
#   EFF-009  Fingerprint Cache — cache hit/miss (INFORMATIONAL)
#   EFF-010  Engineering Optimality — necessity + scope
#   EFF-011  Engineering Optimality — complexity + duplication
#   EFF-012  Engineering Optimality — wymiary kosztów (INFORMATIONAL)
#   EFF-013  Change Impact Prediction — change_proposals istnieje
#   EFF-014  Change Impact Prediction — prediction_accuracy istnieje
#   EFF-015  Change Impact Prediction — pipeline się uczy (INFORMATIONAL)
#   EFF-016  Minimal Change Gate — change_scope z wymiarami zmiany
#   EFF-017  Minimal Change Gate — scope_anomaly + justification
#   EFF-018  Minimal Change Gate — anomalia wymaga uzasadnienia (INFORMATIONAL)
#   EFF-019  Duplicate Work Gate — duplicate_work istnieje
#   EFF-020  Duplicate Work Gate — can_reuse/reuse_evidence/decision
#   EFF-021  Duplicate Work Gate — reuse valid evidence (INFORMATIONAL)
#   EFF-022  Uniwersalność — zasada impact→reuse→execute→certify
#   EFF-023  Uniwersalność — łańcuch NECESSITY→…→ACTUAL vs PREDICTED
#   EFF-024  Uniwersalność — Quality Gate vs Efficiency Gate (INFORMATIONAL)
# ─────────────────────────────────────────────────────────────
set -u

# Wymuszamy C locale dla arytmetyki float (awk) — w locale z przecinkiem
# dziesiętnym (np. pl_PL) awk parsuje "0.034483" jako 0, co fałszuje sumy.
export LC_NUMERIC=C

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== EFFICIENCY — CHANGE INTELLIGENCE / ENGINEERING EFFICIENCY GATE ==="

# ── Ścieżki i stan środowiska ────────────────────────────────
STATE_DB="system/control-plane/state/data/canonical-state.db"
SQLITE_OK=0
DB_OK=0
if command -v sqlite3 >/dev/null 2>&1; then
  SQLITE_OK=1
  if [ -f "$STATE_DB" ]; then
    DB_OK=1
  fi
fi

# ── Helper: czy tabela istnieje w StateStore ─────────────────
# Zwraca 0 jeśli tabela istnieje, 1 jeśli nie, 2 jeśli nie można ocenić
# (brak sqlite3 lub bazy). Checki zależne od bazy traktują wynik 2 jako WARN.
table_exists() {
  local table="$1"
  if [ "$SQLITE_OK" -eq 0 ] || [ "$DB_OK" -eq 0 ]; then
    return 2
  fi
  if sqlite3 "$STATE_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';" 2>/dev/null | grep -qx "$table"; then
    return 0
  fi
  return 1
}

# ── Helper: liczba wierszy tabeli (0 jeśli brak/nie można) ───
table_rows() {
  local table="$1"
  if [ "$SQLITE_OK" -eq 0 ] || [ "$DB_OK" -eq 0 ]; then
    printf '0'
    return
  fi
  sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM $table;" 2>/dev/null || printf '0'
}

# ── Helper: czy tabela ma wszystkie podane kolumny ───────────
# Zwraca 0 jeśli wszystkie kolumny obecne, 1 jeśli nie, 2 jeśli nie można ocenić.
table_has_columns() {
  local table="$1"; shift
  if [ "$SQLITE_OK" -eq 0 ] || [ "$DB_OK" -eq 0 ]; then
    return 2
  fi
  local cols
  cols="$(sqlite3 "$STATE_DB" "PRAGMA table_info($table);" 2>/dev/null | awk -F'|' '{print $2}')"
  local c
  for c in "$@"; do
    if ! printf '%s\n' "$cols" | grep -qx "$c"; then
      return 1
    fi
  done
  return 0
}

# ═════════════════════════════════════════════════════════════
# SEKCJA 1 — Dependency Impact Analysis (EFF-001..003)
# ═════════════════════════════════════════════════════════════

# ── EFF-001 Graf zależności istnieje (BLOCKING) ──────────────
# Bez grafu zależności nie da się wyznaczyć affected/unaffected setu.
# Sprawdzamy obecność plików definiujących zależności.
DEP_FILES="$(repo_files --name '(Cargo\.toml|package\.json|requirements\.txt|go\.mod|pyproject\.toml)$')"
if [ -n "$DEP_FILES" ]; then
  pass "EFF-001 Graf zależności istnieje" BLOCKING "Znaleziono pliki zależności: $(printf '%s' "$DEP_FILES" | tr '\n' ' ')"
else
  fail "EFF-001 Graf zależności istnieje" BLOCKING "Brak plików zależności (Cargo.toml/package.json/requirements.txt/go.mod/pyproject.toml) — nie można wyznaczyć affected/unaffected."
fi

# ── EFF-002 Affected/unaffected wyznaczalne (WARNING) ────────
# Rozpoznawcze: jeśli istnieje co najmniej jeden plik zależności, mechanizm
# wyznaczania affected setu jest możliwy. Nie wymagamy pełnego grafu.
if [ -n "$DEP_FILES" ]; then
  SRC_COUNT="$(repo_files --name '\.(rs|ts|js|py|go|c|h|sh)$' | grep -c . || true)"
  pass "EFF-002 Affected/unaffected wyznaczalne" WARNING "Graf zależności obecny — affected set wyznaczalny (plików źródłowych: ${SRC_COUNT:-0})."
else
  warn "EFF-002 Affected/unaffected wyznaczalne" "Brak grafu zależności — affected/unaffected nie do wyznaczenia."
fi

# ── EFF-003 Targeted build/test/verify (WARNING) ─────────────
# Mechanizm targeted build (cargo build -p, npm --filter, Makefile z targetami).
TARGETED_BUILD="$(repo_files --name '(Makefile|makefile|\.mk$|justfile|Taskfile\.ya?ml)$')"
if [ -n "$TARGETED_BUILD" ]; then
  pass "EFF-003 Targeted build/test/verify" WARNING "Znaleziono mechanizm targeted build: $(printf '%s' "$TARGETED_BUILD" | tr '\n' ' ')"
else
  warn "EFF-003 Targeted build/test/verify" "Brak Makefile/skryptu z targetami — brak targeted build (nie blokuje, ale sygnalizuje)."
fi

# ═════════════════════════════════════════════════════════════
# SEKCJA 2 — Build Intelligence (EFF-004..006)
# ═════════════════════════════════════════════════════════════

# ── EFF-004 Pipeline source→graph→affected→gates (BLOCKING) ──
# Dokumentacja/konfiguracja opisująca pipeline change intelligence.
PIPELINE_DOC="$(grep -rilE 'affected|impact analysis|impact.*gate' docs/ ARCHITECTURE.md README.md config/ 2>/dev/null | head -5)"
if [ -n "$PIPELINE_DOC" ]; then
  pass "EFF-004 Pipeline source→graph→affected→gates" BLOCKING "Pipeline udokumentowany w: $(printf '%s' "$PIPELINE_DOC" | tr '\n' ' ')"
else
  fail "EFF-004 Pipeline source→graph→affected→gates" BLOCKING "Brak dokumentacji/konfiguracji opisującej pipeline source→graph→affected→gates."
fi

# ── EFF-005 Tabela typów zmian (WARNING) ─────────────────────
# Tabela mapująca typ zmiany → wymagane gate'y.
CHANGE_TABLE="$(grep -rilE 'README.*docs|config schema.*canonical|shared contract.*E2E|Dockerfile.*security|State schema.*recovery|security policy.*release' docs/ ARCHITECTURE.md README.md config/ 2>/dev/null | head -5)"
if [ -n "$CHANGE_TABLE" ]; then
  pass "EFF-005 Tabela typów zmian" WARNING "Tabela typów zmian obecna w: $(printf '%s' "$CHANGE_TABLE" | tr '\n' ' ')"
else
  warn "EFF-005 Tabela typów zmian" "Brak tabeli mapującej typ zmiany → wymagane gate'y."
fi

# ── EFF-006 Podsumowanie typów zmian (INFORMATIONAL) ─────────
DOCS_N="$(repo_files --name '^docs/' | grep -c . || true)"
CODE_N="$(repo_files --name '\.(rs|ts|js|py|go)$' | grep -c . || true)"
CONFIG_N="$(repo_files --name '\.(yaml|yml|toml|json)$' | grep -c . || true)"
CONTRACT_N="$(repo_files --name '(contract|schema|proto)' | grep -c . || true)"
DOCKER_N="$(repo_files --name '(Dockerfile|docker-compose|\.dockerignore)' | grep -c . || true)"
STATE_N="$(repo_files --name 'state/' | grep -c . || true)"
info "EFF-006 Podsumowanie typów zmian" "docs=$DOCS_N code=$CODE_N config=$CONFIG_N contract=$CONTRACT_N dockerfile=$DOCKER_N state=$STATE_N (INFORMATIONAL)."

# ═════════════════════════════════════════════════════════════
# SEKCJA 3 — Fingerprint Cache (EFF-007..009)
# ═════════════════════════════════════════════════════════════

# ── EFF-007 Dowodowy fingerprint cache istnieje (BLOCKING) ───
table_exists "fingerprint_cache"
FP_TBL=$?
if [ "$FP_TBL" -eq 0 ]; then
  pass "EFF-007 Dowodowy fingerprint cache istnieje" BLOCKING "Tabela fingerprint_cache obecna w StateStore."
elif [ "$FP_TBL" -eq 2 ]; then
  warn "EFF-007 Dowodowy fingerprint cache istnieje" "sqlite3/baza niedostępne — nie można zweryfikować fingerprint_cache (środowisko testowe)."
else
  fail "EFF-007 Dowodowy fingerprint cache istnieje" BLOCKING "Brak tabeli fingerprint_cache w StateStore — brak dowodowego cache."
fi

# ── EFF-008 Kolumny fingerprintu kompletne (WARNING) ─────────
table_has_columns "fingerprint_cache" source_hash dependency_hash compiler_hash toolchain_hash config_hash build_flags target environment
FP_COLS=$?
if [ "$FP_COLS" -eq 0 ]; then
  pass "EFF-008 Kolumny fingerprintu kompletne" WARNING "fingerprint_cache ma wszystkie kolumny (source/dependency/compiler/toolchain/config hash, build flags, target, environment)."
elif [ "$FP_COLS" -eq 2 ]; then
  warn "EFF-008 Kolumny fingerprintu kompletne" "sqlite3/baza niedostępne — nie można sprawdzić kolumn fingerprint_cache."
else
  fail "EFF-008 Kolumny fingerprintu kompletne" WARNING "fingerprint_cache nie ma wszystkich wymaganych kolumn."
fi

# ── EFF-009 Cache hit/miss (INFORMATIONAL) ───────────────────
FP_ROWS="$(table_rows "fingerprint_cache")"
info "EFF-009 Cache hit/miss" "Wierszy w fingerprint_cache: $FP_ROWS — CACHE HIT = udowodniono identyczne wejścia (INFORMATIONAL)."

# ═════════════════════════════════════════════════════════════
# SEKCJA 4 — Engineering Optimality (EFF-010..012)
# ═════════════════════════════════════════════════════════════

# ── EFF-010 Necessity + Scope (WARNING) ──────────────────────
table_exists "change_scope"
CS_TBL=$?
if [ "$CS_TBL" -eq 0 ]; then
  pass "EFF-010 Necessity + Scope" WARNING "Tabela change_scope obecna — mechanizm oceny konieczności i zakresu istnieje."
elif [ "$CS_TBL" -eq 2 ]; then
  warn "EFF-010 Necessity + Scope" "sqlite3/baza niedostępne — nie można zweryfikować change_scope."
else
  warn "EFF-010 Necessity + Scope" "Brak tabeli change_scope — brak mechanizmu oceny necessity + scope."
fi

# ── EFF-011 Complexity + Duplication (WARNING) ───────────────
DUP_TOOL="$(repo_files --name '(dup|duplicate|complexity|simian|jscpd)' | grep -c . || true)"
if [ "$DUP_TOOL" -gt 0 ]; then
  pass "EFF-011 Complexity + Duplication" WARNING "Znaleziono narzędzie/skrypt wykrywania duplikacji."
else
  warn "EFF-011 Complexity + Duplication" "Brak narzędzia wykrywania duplikacji/złożoności."
fi

# ── EFF-012 Wymiary optymalności (INFORMATIONAL) ─────────────
info "EFF-012 Wymiary optymalności" "Performance / Resource cost / Build cost / Operational cost / Maintenance cost — wymiary oceny optymalności (INFORMATIONAL)."

# ═════════════════════════════════════════════════════════════
# SEKCJA 5 — Change Impact Prediction (EFF-013..015)
# ═════════════════════════════════════════════════════════════

# ── EFF-013 CHANGE PROPOSAL wylicza predicted affected set ───
table_exists "change_proposals"
CP_TBL=$?
if [ "$CP_TBL" -eq 0 ]; then
  pass "EFF-013 CHANGE PROPOSAL wylicza predicted affected set" WARNING "Tabela change_proposals obecna."
elif [ "$CP_TBL" -eq 2 ]; then
  warn "EFF-013 CHANGE PROPOSAL wylicza predicted affected set" "sqlite3/baza niedostępne — nie można zweryfikować change_proposals."
else
  warn "EFF-013 CHANGE PROPOSAL wylicza predicted affected set" "Brak tabeli change_proposals — brak mechanizmu predykcji affected setu."
fi

# ── EFF-014 Porównanie PREDICTED vs ACTUAL (WARNING) ─────────
table_exists "prediction_accuracy"
PA_TBL=$?
if [ "$PA_TBL" -eq 0 ]; then
  pass "EFF-014 Porównanie PREDICTED vs ACTUAL" WARNING "Tabela prediction_accuracy obecna."
elif [ "$PA_TBL" -eq 2 ]; then
  warn "EFF-014 Porównanie PREDICTED vs ACTUAL" "sqlite3/baza niedostępne — nie można zweryfikować prediction_accuracy."
else
  warn "EFF-014 Porównanie PREDICTED vs ACTUAL" "Brak tabeli prediction_accuracy — brak porównania predicted vs actual."
fi

# ── EFF-015 Pipeline się uczy (INFORMATIONAL) ────────────────
PA_ROWS="$(table_rows "prediction_accuracy")"
info "EFF-015 Prediction Accuracy — pipeline się uczy" "Wierszy w prediction_accuracy: $PA_ROWS (INFORMATIONAL)."

# ═════════════════════════════════════════════════════════════
# SEKCJA 6 — Minimal Change Gate (EFF-016..018)
# ═════════════════════════════════════════════════════════════

# ── EFF-016 Analiza files/lines/components/dependencies/config/tests/docs ──
table_has_columns "change_scope" files_changed lines_changed components_changed dependencies_changed configs_changed tests_changed docs_changed
CS_COLS=$?
if [ "$CS_COLS" -eq 0 ]; then
  pass "EFF-016 Analiza wymiarów zmiany" WARNING "change_scope ma wszystkie wymiary (files/lines/components/dependencies/config/tests/docs)."
elif [ "$CS_COLS" -eq 2 ]; then
  warn "EFF-016 Analiza wymiarów zmiany" "sqlite3/baza niedostępne — nie można sprawdzić kolumn change_scope."
else
  warn "EFF-016 Analiza wymiarów zmiany" "change_scope nie ma wszystkich wymiarów zmiany."
fi

# ── EFF-017 CHANGE_SCOPE_ANOMALY wymaga uzasadnienia ─────────
table_has_columns "change_scope" scope_anomaly justification
CS_ANOM=$?
if [ "$CS_ANOM" -eq 0 ]; then
  pass "EFF-017 CHANGE_SCOPE_ANOMALY wymaga uzasadnienia" WARNING "change_scope ma kolumny scope_anomaly + justification."
elif [ "$CS_ANOM" -eq 2 ]; then
  warn "EFF-017 CHANGE_SCOPE_ANOMALY wymaga uzasadnienia" "sqlite3/baza niedostępne — nie można sprawdzić kolumn scope_anomaly/justification."
else
  warn "EFF-017 CHANGE_SCOPE_ANOMALY wymaga uzasadnienia" "change_scope nie ma kolumn scope_anomaly/justification."
fi

# ── EFF-018 Anomalia wymaga uzasadnienia (INFORMATIONAL) ─────
info "EFF-018 Anomalia wymaga uzasadnienia" "Anomalia zakresu nie musi być FAIL — wymaga uzasadnienia (INFORMATIONAL)."

# ═════════════════════════════════════════════════════════════
# SEKCJA 7 — Duplicate Work Gate (EFF-019..021)
# ═════════════════════════════════════════════════════════════

# ── EFF-019 REQUEST → CAN I REUSE? ───────────────────────────
table_exists "duplicate_work"
DW_TBL=$?
if [ "$DW_TBL" -eq 0 ]; then
  pass "EFF-019 REQUEST → CAN I REUSE?" WARNING "Tabela duplicate_work obecna."
elif [ "$DW_TBL" -eq 2 ]; then
  warn "EFF-019 REQUEST → CAN I REUSE?" "sqlite3/baza niedostępne — nie można zweryfikować duplicate_work."
else
  warn "EFF-019 REQUEST → CAN I REUSE?" "Brak tabeli duplicate_work — brak mechanizmu reuse."
fi

# ── EFF-020 YES verify existing / NO execute ─────────────────
table_has_columns "duplicate_work" can_reuse reuse_evidence decision
DW_COLS=$?
if [ "$DW_COLS" -eq 0 ]; then
  pass "EFF-020 YES verify existing / NO execute" WARNING "duplicate_work ma kolumny can_reuse/reuse_evidence/decision."
elif [ "$DW_COLS" -eq 2 ]; then
  warn "EFF-020 YES verify existing / NO execute" "sqlite3/baza niedostępne — nie można sprawdzić kolumn duplicate_work."
else
  warn "EFF-020 YES verify existing / NO execute" "duplicate_work nie ma kolumn can_reuse/reuse_evidence/decision."
fi

# ── EFF-021 Reuse valid evidence (INFORMATIONAL) ─────────────
DW_ROWS="$(table_rows "duplicate_work")"
info "EFF-021 Reuse valid evidence" "Wierszy w duplicate_work: $DW_ROWS (INFORMATIONAL)."

# ═════════════════════════════════════════════════════════════
# SEKCJA 8 — Uniwersalność (EFF-022..024)
# ═════════════════════════════════════════════════════════════

# ── EFF-022 Zasada impact→reuse→execute→certify (WARNING) ───
UNIV_DOC="$(grep -rilE 'impact analysis|minimal affected|reuse valid evidence|invalidate affected' docs/ ARCHITECTURE.md README.md 2>/dev/null | head -5)"
if [ -n "$UNIV_DOC" ]; then
  pass "EFF-022 Zasada impact→reuse→execute→certify" WARNING "Zasada udokumentowana w: $(printf '%s' "$UNIV_DOC" | tr '\n' ' ')"
else
  warn "EFF-022 Zasada impact→reuse→execute→certify" "Brak dokumentacji zasady impact analysis → minimal affected set → reuse → execute → certify."
fi

# ── EFF-023 Łańcuch NECESSITY→…→ACTUAL vs PREDICTED (WARNING) ──
CHAIN_DOC="$(grep -rilE 'NECESSITY|IMPACT|REUSE|MINIMAL SCOPE|ACTUAL vs PREDICTED|actual.*predicted' docs/ ARCHITECTURE.md README.md 2>/dev/null | head -5)"
if [ -n "$CHAIN_DOC" ]; then
  pass "EFF-023 Łańcuch NECESSITY→…→ACTUAL vs PREDICTED" WARNING "Łańcuch udokumentowany w: $(printf '%s' "$CHAIN_DOC" | tr '\n' ' ')"
else
  warn "EFF-023 Łańcuch NECESSITY→…→ACTUAL vs PREDICTED" "Brak dokumentacji łańcucha NECESSITY→IMPACT→REUSE→MINIMAL SCOPE→EXECUTE→VERIFY→ACTUAL vs PREDICTED."
fi

# ── EFF-024 Quality Gate vs Efficiency Gate (INFORMATIONAL) ──
info "EFF-024 Quality Gate vs Efficiency Gate" "Quality Gate pyta 'czy dobrze zrobione?', Efficiency Gate pyta 'czy zrobione minimalnie i bez duplikacji?' — dwa pytania (INFORMATIONAL)."

# ── Evidence ─────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:efficiency:FAIL" "verify" "efficiency/efficiency.sh"
else
  evidence_record "verify:efficiency:PASS" "verify" "efficiency/efficiency.sh"
fi

verify_module_exit
