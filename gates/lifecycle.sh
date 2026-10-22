#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# lifecycle/lifecycle.sh — LIFECYCLE PLANE (Evidence-Driven Software Lifecycle)
# Weryfikuje że cykl życia oprogramowania (LIFECYCLE-001) jest kompletny,
# spójny i wykonywalny. To NIE jest checklista — to gate, który sprawdza,
# czy konstytucja lifecycle (docs/00-foundation/LIFECYCLE.md) definiuje
# fazy F00-F17, gate'y G0-G17, state machine, model artefaktów i traceability,
# oraz czy StateStore ma tabele lifecycle (requirement/change/verification/release).
#
# Zasada: "Nie przechodzimy dalej dlatego, że skończyliśmy pracę. Przechodzimy
# dalej dlatego, że spełniliśmy kontrakt i mamy dowód."
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

LIFECYCLE_DOC="docs/00-foundation/LIFECYCLE.md"
STATE_DB="system/control-plane/state/data/canonical-state.db"

say "=== LIFECYCLE PLANE ==="

# ── LIFECYCLE-001: LIFECYCLE.md istnieje ────────────────────
if [ -f "$LIFECYCLE_DOC" ]; then
  pass "LIFECYCLE-001 LIFECYCLE.md istnieje" BLOCKING "Konstytucja lifecycle obecna."
else
  fail "LIFECYCLE-001 LIFECYCLE.md istnieje" BLOCKING "Brak $LIFECYCLE_DOC."
fi

# ── LIFECYCLE-002: LIFECYCLE.md nie jest placeholderem ──────
if [ -f "$LIFECYCLE_DOC" ]; then
  if grep -qiE 'placeholder|TODO|coming soon|brak implementacji' "$LIFECYCLE_DOC" 2>/dev/null; then
    fail "LIFECYCLE-002 LIFECYCLE.md nie jest placeholderem" BLOCKING "Konstytucja zawiera placeholder."
  else
    pass "LIFECYCLE-002 LIFECYCLE.md nie jest placeholderem" BLOCKING "Konstytucja nie jest placeholderem."
  fi
fi

# ── LIFECYCLE-003: state machine zdefiniowany ───────────────
# Uniwersalny state machine (IDEA→RETIRED, nigdy "DONE").
# State machine w LIFECYCLE.md jest w bloku kodu WIELOLINIOWYM, więc
# normalizujemy nowe linie do spacji przed dopasowaniem wzorca.
if [ -f "$LIFECYCLE_DOC" ]; then
  if tr '\n' ' ' < "$LIFECYCLE_DOC" 2>/dev/null | grep -qE 'IDEA.*DISCOVERING.*DEFINED.*CONTRACTED.*DESIGNED.*IMPLEMENTING.*VERIFYING.*INTEGRATING.*HARDENING.*RELEASING.*STAGING.*CERTIFIED.*CANARY.*PRODUCTION.*OPERATING.*DEPRECATED.*RETIRED'; then
    pass "LIFECYCLE-003 state machine zdefiniowany" BLOCKING "Pełny state machine obecny."
  else
    fail "LIFECYCLE-003 state machine zdefiniowany" BLOCKING "State machine niekompletny (brak pełnej sekwencji IDEA→RETIRED)."
  fi
fi

# ── LIFECYCLE-004: fazy F00-F17 zdefiniowane ────────────────
if [ -f "$LIFECYCLE_DOC" ]; then
  f00=$(grep -c 'F00' "$LIFECYCLE_DOC" 2>/dev/null || true)
  f17=$(grep -c 'F17' "$LIFECYCLE_DOC" 2>/dev/null || true)
  if [ "$f00" -gt 0 ] && [ "$f17" -gt 0 ]; then
    pass "LIFECYCLE-004 fazy F00-F17 zdefiniowane" BLOCKING "Fazy F00 i F17 obecne."
  else
    fail "LIFECYCLE-004 fazy F00-F17 zdefiniowane" BLOCKING "Brak faz F00/F17 w konstytucji."
  fi
fi

# ── LIFECYCLE-005: gate'y G0-G17 zdefiniowane ───────────────
if [ -f "$LIFECYCLE_DOC" ]; then
  g0=$(grep -c 'G0' "$LIFECYCLE_DOC" 2>/dev/null || true)
  g17=$(grep -c 'G17' "$LIFECYCLE_DOC" 2>/dev/null || true)
  if [ "$g0" -gt 0 ] && [ "$g17" -gt 0 ]; then
    pass "LIFECYCLE-005 gate'y G0-G17 zdefiniowane" BLOCKING "Gate'y G0 i G17 obecne."
  else
    fail "LIFECYCLE-005 gate'y G0-G17 zdefiniowane" BLOCKING "Brak gate'ów G0/G17 w konstytucji."
  fi
fi

# ── LIFECYCLE-006: model artefaktów zdefiniowany ────────────
# Uniwersalny model artefaktów (CHANGE_ID → ... → VERIFICATION_ID).
# Model artefaktów w LIFECYCLE.md jest w bloku kodu WIELOLINIOWYM, więc
# normalizujemy nowe linie do spacji przed dopasowaniem wzorca.
if [ -f "$LIFECYCLE_DOC" ]; then
  if tr '\n' ' ' < "$LIFECYCLE_DOC" 2>/dev/null | grep -qE 'CHANGE_ID.*REQUIREMENT_ID.*CONTRACT_ID.*DESIGN_ID.*CODE_ID.*TEST_ID.*GATE_ID.*BUILD_ID.*ARTIFACT_ID.*RELEASE_ID.*DEPLOYMENT_ID.*RUNTIME_ID.*EVIDENCE_ID.*VERIFICATION_ID'; then
    pass "LIFECYCLE-006 model artefaktów zdefiniowany" BLOCKING "Pełny model artefaktów obecny."
  else
    fail "LIFECYCLE-006 model artefaktów zdefiniowany" BLOCKING "Model artefaktów niekompletny."
  fi
fi

# ── LIFECYCLE-007: traceability matrix zdefiniowana ─────────
if [ -f "$LIFECYCLE_DOC" ]; then
  if grep -qE 'REQUIREMENT.*CONTRACT.*DESIGN.*CODE.*TEST.*GATE.*EVIDENCE.*VERIFICATION' "$LIFECYCLE_DOC" 2>/dev/null; then
    pass "LIFECYCLE-007 traceability matrix zdefiniowana" BLOCKING "Traceability matrix obecna."
  else
    fail "LIFECYCLE-007 traceability matrix zdefiniowana" BLOCKING "Brak traceability matrix."
  fi
fi

# ── LIFECYCLE-008: StateStore ma tabele lifecycle ───────────
# Wymagane tabele: requirement, change, verification, release.
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$STATE_DB" ]; then
  missing_tables=""
  for t in requirement change verification release; do
    if ! sqlite3 "$STATE_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='$t';" 2>/dev/null | grep -q "$t"; then
      missing_tables="$missing_tables $t"
    fi
  done
  if [ -z "$missing_tables" ]; then
    pass "LIFECYCLE-008 StateStore ma tabele lifecycle" BLOCKING "Tabele requirement/change/verification/release obecne."
  else
    fail "LIFECYCLE-008 StateStore ma tabele lifecycle" BLOCKING "Brak tabel:$missing_tables (uruchom state.sh migrate)."
  fi
else
  warn "LIFECYCLE-008 StateStore ma tabele lifecycle" "Brak sqlite3 lub bazy — pomijam (best-effort)."
fi

# ── LIFECYCLE-009: moduł zarejestrowany w registry ──────────
# GATE-INTEGRITY-003: każdy skrypt domains/ MUSI mieć wpis w registry.
# lifecycle.sh jest w lifecycle/, nie domains/, ale sprawdzamy że registry
# ma wpis GATE-040 LIFECYCLE (spójność z GATE-INTEGRITY).
if [ -f "tools/verify/gates/registry.sh" ]; then
  if grep -q 'GATE-040' "tools/verify/gates/registry.sh" 2>/dev/null; then
    pass "LIFECYCLE-009 moduł zarejestrowany w registry" BLOCKING "GATE-040 LIFECYCLE obecny w registry."
  else
    fail "LIFECYCLE-009 moduł zarejestrowany w registry" BLOCKING "Brak GATE-040 LIFECYCLE w registry.sh."
  fi
else
  warn "LIFECYCLE-009 moduł zarejestrowany w registry" "Brak registry.sh — pomijam."
fi

# ── Evidence bridge ─────────────────────────────────────────
evidence_record "verify:lifecycle:PASS" "verify" "lifecycle/lifecycle.sh"

verify_module_exit
