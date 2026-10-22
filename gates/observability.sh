#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/observability.sh — GATE-043 OBSERVABILITY
# Weryfikuje warstwę Observability & Knowledge Explorer: narzędzie
# tools/explore/explore.sh (kanoniczny model projektu), biblioteki
# lib/ (discovery, model, git, docs, graphs, html, validate, security),
# testy tests/, oraz że `explore.sh all` generuje wszystkie widoki
# (Markdown, Mermaid, HTML, JSON, indexes) z JEDNEGO kanonicznego modelu.
#
# ARCHITEKTURA: Explorer oparty na JEDNYM kanonicznym modelu projektu.
#   REPOSITORY → DISCOVERY ENGINE → NORMALIZED PROJECT MODEL → GENERATORS
#   (Markdown, Mermaid, JSON, HTML, indexes). Jeden model → wiele widoków.
#
# Semantyka NOT_APPLICABLE: brak danych (np. brak narzędzia) NIE jest FAIL —
# to informacja (info/warn), bo gate jest poprawnie zbudowany, a dane mogą
# nie istnieć jeszcze w danym repo. NO FALSE GREEN: nie raportujemy PASS gdy
# brak danych — raportujemy NOT_APPLICABLE.
#
# Checks: OBS-001..015.
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-043 OBSERVABILITY ==="

EXPLORE_SH="./tools/explore/explore.sh"
EXPLORE_LIB="./tools/explore/lib"
EXPLORE_TESTS="./tools/explore/tests"
MODEL_JSON="./docs/generated/project-model.json"
MODEL_SCHEMA="./docs/generated/project-model.schema.json"
SUMMARY_JSON="./docs/generated/summary.json"
EXPLORER_HTML="./docs/explorer/index.html"
GRAPHS_DIR="./docs/graphs"
INDEXES_DIR="./docs/generated/indexes"

# ── OBS-001: narzędzie explore.sh istnieje ──────────────────
if [ -f "$EXPLORE_SH" ]; then
  pass "OBS-001 narzędzie tools/explore/explore.sh istnieje" BLOCKING "Explorer CLI obecny."
else
  fail "OBS-001 narzędzie tools/explore/explore.sh istnieje" BLOCKING "Brak tools/explore/explore.sh"
fi

# ── OBS-002: biblioteki lib/ istnieją ───────────────────────
# Kanoniczny model wymaga bibliotek: discovery, model, git, docs,
# graphs, html, validate, security.
LIBS=(
  "discovery.sh"
  "model.sh"
  "git.sh"
  "docs.sh"
  "graphs.sh"
  "html.sh"
  "validate.sh"
  "security.sh"
)
MISSING_LIB=0
MISSING_LIB_DETAIL=""
for libf in "${LIBS[@]}"; do
  if [ ! -f "$EXPLORE_LIB/$libf" ]; then
    MISSING_LIB=$((MISSING_LIB+1))
    MISSING_LIB_DETAIL="$MISSING_LIB_DETAIL $libf"
  fi
done
if [ "$MISSING_LIB" -eq 0 ]; then
  pass "OBS-002 biblioteki lib/ istnieją" BLOCKING "Wszystkie 8 bibliotek obecne."
else
  fail "OBS-002 biblioteki lib/ istnieją" BLOCKING "Brak bibliotek:$MISSING_LIB_DETAIL"
fi

# ── OBS-003: testy tests/ istnieją ──────────────────────────
# Testy: test-explorer, test-model, test-graphs, test-html, test-determinism.
TESTS=(
  "test-explorer.sh"
  "test-model.sh"
  "test-graphs.sh"
  "test-html.sh"
  "test-determinism.sh"
)
MISSING_TEST=0
MISSING_TEST_DETAIL=""
for tf in "${TESTS[@]}"; do
  if [ ! -f "$EXPLORE_TESTS/$tf" ]; then
    MISSING_TEST=$((MISSING_TEST+1))
    MISSING_TEST_DETAIL="$MISSING_TEST_DETAIL $tf"
  fi
done
if [ "$MISSING_TEST" -eq 0 ]; then
  pass "OBS-003 testy tests/ istnieją" BLOCKING "Wszystkie 5 testów obecne."
else
  fail "OBS-003 testy tests/ istnieją" BLOCKING "Brak testów:$MISSING_TEST_DETAIL"
fi

# ── OBS-004: explore.sh ma set -u ───────────────────────────
if [ -f "$EXPLORE_SH" ]; then
  if grep -qE 'set -[a-z]*u' "$EXPLORE_SH" 2>/dev/null; then
    pass "OBS-004 explore.sh ma set -u" BLOCKING "set -u obecny."
  else
    fail "OBS-004 explore.sh ma set -u" BLOCKING "Brak set -u w explore.sh"
  fi
else
  info "OBS-004 explore.sh ma set -u" "Brak explore.sh (NOT_APPLICABLE)."
fi

# ── OBS-005: biblioteki lib/ mają set -u ────────────────────
NO_SET_U_LIB=0
NO_SET_U_LIB_DETAIL=""
for libf in "${LIBS[@]}"; do
  f="$EXPLORE_LIB/$libf"
  [ -f "$f" ] || continue
  if ! grep -qE 'set -[a-z]*u' "$f" 2>/dev/null; then
    NO_SET_U_LIB=$((NO_SET_U_LIB+1))
    NO_SET_U_LIB_DETAIL="$NO_SET_U_LIB_DETAIL $libf"
  fi
done
if [ "$NO_SET_U_LIB" -eq 0 ]; then
  pass "OBS-005 biblioteki lib/ mają set -u" BLOCKING "Wszystkie biblioteki mają set -u."
else
  fail "OBS-005 biblioteki lib/ mają set -u" BLOCKING "Brak set -u:$NO_SET_U_LIB_DETAIL"
fi

# ── OBS-006: explore.sh ma komendę all (GŁÓWNA KOMENDA) ─────
# `explore all` musi być pojedynczą komendą reprodukującą cały obraz.
if [ -f "$EXPLORE_SH" ]; then
  if grep -qE 'explore_all\(\)' "$EXPLORE_SH" 2>/dev/null \
     && grep -qE 'all\)' "$EXPLORE_SH" 2>/dev/null; then
    pass "OBS-006 explore.sh ma komendę all" BLOCKING "Komenda all obecna (scan+build+docs+graphs+html+validate+status)."
  else
    fail "OBS-006 explore.sh ma komendę all" BLOCKING "Brak komendy all w explore.sh"
  fi
else
  info "OBS-006 explore.sh ma komendę all" "Brak explore.sh (NOT_APPLICABLE)."
fi

# ── OBS-007: kanoniczny model (project-model.json) ──────────
# JEDEN model → wiele widoków. Model musi istnieć po `explore.sh all`.
if [ -f "$MODEL_JSON" ]; then
  pass "OBS-007 kanoniczny model project-model.json istnieje" BLOCKING "Model obecny."
else
  info "OBS-007 kanoniczny model project-model.json istnieje" "Brak modelu — uruchom explore.sh all (NOT_APPLICABLE)."
fi

# ── OBS-008: schema modelu istnieje ─────────────────────────
if [ -f "$MODEL_SCHEMA" ]; then
  pass "OBS-008 schema project-model.schema.json istnieje" BLOCKING "Schema obecna."
else
  info "OBS-008 schema project-model.schema.json istnieje" "Brak schemy — uruchom explore.sh all (NOT_APPLICABLE)."
fi

# ── OBS-009: summary.json istnieje ──────────────────────────
if [ -f "$SUMMARY_JSON" ]; then
  pass "OBS-009 summary.json istnieje" BLOCKING "Podsumowanie obecne."
else
  info "OBS-009 summary.json istnieje" "Brak summary.json — uruchom explore.sh all (NOT_APPLICABLE)."
fi

# ── OBS-010: HTML explorer istnieje ─────────────────────────
if [ -f "$EXPLORER_HTML" ]; then
  pass "OBS-010 HTML explorer docs/explorer/index.html istnieje" BLOCKING "HTML explorer obecny."
else
  info "OBS-010 HTML explorer docs/explorer/index.html istnieje" "Brak HTML — uruchom explore.sh all (NOT_APPLICABLE)."
fi

# ── OBS-011: grafy Mermaid istnieją ─────────────────────────
# Katalog grafów musi zawierać 13 plików .mmd + README.md.
if [ -d "$GRAPHS_DIR" ]; then
  MMD_COUNT="$(ls "$GRAPHS_DIR"/*.mmd 2>/dev/null | wc -l)"
  if [ "$MMD_COUNT" -ge 13 ]; then
    pass "OBS-011 grafy Mermaid istnieją" BLOCKING "$MMD_COUNT plików .mmd obecnych."
  else
    fail "OBS-011 grafy Mermaid istnieją" BLOCKING "Tylko $MMD_COUNT plików .mmd (oczekiwano >= 13)."
  fi
else
  info "OBS-011 grafy Mermaid istnieją" "Brak katalogu grafów — uruchom explore.sh all (NOT_APPLICABLE)."
fi

# ── OBS-012: indeksy istnieją ───────────────────────────────
# Indeksy: components, pipelines, gates, documents, findings.
INDEXES=(
  "components.md"
  "pipelines.md"
  "gates.md"
  "documents.md"
  "findings.md"
)
MISSING_IDX=0
MISSING_IDX_DETAIL=""
for idx in "${INDEXES[@]}"; do
  if [ ! -f "$INDEXES_DIR/$idx" ]; then
    MISSING_IDX=$((MISSING_IDX+1))
    MISSING_IDX_DETAIL="$MISSING_IDX_DETAIL $idx"
  fi
done
if [ "$MISSING_IDX" -eq 0 ]; then
  pass "OBS-012 indeksy docs/generated/indexes/ istnieją" BLOCKING "Wszystkie 5 indeksów obecne."
else
  info "OBS-012 indeksy docs/generated/indexes/ istnieją" "Brak indeksów:$MISSING_IDX_DETAIL — uruchom explore.sh all (NOT_APPLICABLE)."
fi

# ── OBS-013: brak false green w bibliotekach lib/ ───────────
# Zakazane wzorce: || true, set +e, ignorowany exit code.
FALSE_GREEN_LIB=0
FALSE_GREEN_LIB_DETAIL=""
for libf in "${LIBS[@]}"; do
  f="$EXPLORE_LIB/$libf"
  [ -f "$f" ] || continue
  if awk '
      /^[[:space:]]*#/ { next }
      /<<[[:space:]]*['\''"]?[A-Za-z_]+/ { in_heredoc=1; next }
      in_heredoc && /^[[:space:]]*[A-Za-z_]+[[:space:]]*$/{ in_heredoc=0; next }
      in_heredoc { next }
      {
          line=$0
          gsub(/"[^"]*"/, "", line)
          gsub(/'\''[^'\'']*'\''/, "", line)
          if (line ~ /(^|[^'\''"])set \+[e]([[:space:]]|$)/ ||
              line ~ /(^|[^'\''"])continue-on-[e]rror([[:space:]]|$)/ ||
              line ~ /(^|[^'\''"])\|\| tru[e]([[:space:]]|$)/) print
      }
  ' "$f" 2>/dev/null | grep -q .; then
    FALSE_GREEN_LIB=$((FALSE_GREEN_LIB+1))
    FALSE_GREEN_LIB_DETAIL="$FALSE_GREEN_LIB_DETAIL $libf"
  fi
done
if [ "$FALSE_GREEN_LIB" -eq 0 ]; then
  pass "OBS-013 brak false green w bibliotekach lib/" BLOCKING "Brak wzorców false green."
else
  fail "OBS-013 brak false green w bibliotekach lib/" BLOCKING "Wykryto false green:$FALSE_GREEN_LIB_DETAIL"
fi

# ── OBS-014: model ma sekcje coverage z formula+input_set ───
# Coverage metrics: każda ma FORMULA + INPUT SET + EXCLUSIONS. NO FAKE 100%.
if [ -f "$MODEL_JSON" ]; then
  if grep -q '"coverage"' "$MODEL_JSON" 2>/dev/null \
     && grep -q '"formula"' "$MODEL_JSON" 2>/dev/null \
     && grep -q '"input_set"' "$MODEL_JSON" 2>/dev/null \
     && grep -q '"exclusions"' "$MODEL_JSON" 2>/dev/null; then
    pass "OBS-014 model ma coverage z formula+input_set+exclusions" BLOCKING "Coverage kompletne."
  else
    fail "OBS-014 model ma coverage z formula+input_set+exclusions" BLOCKING "Coverage niekompletne w modelu."
  fi
else
  info "OBS-014 model ma coverage z formula+input_set+exclusions" "Brak modelu (NOT_APPLICABLE)."
fi

# ── OBS-015: brak sekretów w modelu ─────────────────────────
# Secret redaction: żaden sekret nie powinien przetrwać do modelu.
if [ -f "$MODEL_JSON" ]; then
  if grep -qE 'sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----' "$MODEL_JSON" 2>/dev/null; then
    fail "OBS-015 brak sekretów w modelu" BLOCKING "Wykryto sekret w project-model.json"
  else
    pass "OBS-015 brak sekretów w modelu" BLOCKING "Brak sekretów w modelu."
  fi
else
  info "OBS-015 brak sekretów w modelu" "Brak modelu (NOT_APPLICABLE)."
fi

verify_module_exit
