#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# architecture/architecture.sh — Universal Project Template — Repository Certification Engine
# Moduł: ARCHITECTURE — ARCHITECTURE GATE
# Weryfikuje kompletność i spójność dokumentacji architektury:
#   ARCHITECTURE.md, SOURCE-OF-TRUTH.md, OWNERSHIP.md.
#
# Zasada fail-closed: architektura musi być zdefiniowana. Dokument z
# STATUS: UNDEFINED = architektura niezdefiniowana = FAIL (BLOCKING).
#
# Checki:
#   ARCH-001  ARCHITECTURE.md istnieje
#   ARCH-002  SOURCE-OF-TRUTH.md istnieje
#   ARCH-003  OWNERSHIP.md istnieje
#   ARCH-004  ARCHITECTURE.md nie ma STATUS: UNDEFINED
#   ARCH-005  SOURCE-OF-TRUTH.md nie ma STATUS: UNDEFINED
#   ARCH-006  OWNERSHIP.md nie ma STATUS: UNDEFINED
#   ARCH-007  Spójność: ARCHITECTURE.md linkuje do SOURCE-OF-TRUTH.md i OWNERSHIP.md
#   ARCH-008  Epistemic governance — podsumowanie statusów (INFORMATIONAL)
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== ARCHITECTURE — ARCHITECTURE GATE ==="

ARCH_DOC="ARCHITECTURE.md"
SOT_DOC="SOURCE-OF-TRUTH.md"
OWN_DOC="OWNERSHIP.md"

# ── ARCH-001..003 Dokumenty istnieją ─────────────────────────
if repo_file "$ARCH_DOC"; then
  pass "ARCH-001 $ARCH_DOC istnieje" BLOCKING "$ARCH_DOC"
else
  fail "ARCH-001 $ARCH_DOC istnieje" BLOCKING "Brak $ARCH_DOC — dokument architektury nie istnieje."
fi

if repo_file "$SOT_DOC"; then
  pass "ARCH-002 $SOT_DOC istnieje" BLOCKING "$SOT_DOC"
else
  fail "ARCH-002 $SOT_DOC istnieje" BLOCKING "Brak $SOT_DOC — dokument źródła prawdy nie istnieje."
fi

if repo_file "$OWN_DOC"; then
  pass "ARCH-003 $OWN_DOC istnieje" BLOCKING "$OWN_DOC"
else
  fail "ARCH-003 $OWN_DOC istnieje" BLOCKING "Brak $OWN_DOC — dokument własności nie istnieje."
fi

# ── ARCH-004..006 Dokumenty nie są UNDEFINED ─────────────────
# Fail-closed: STATUS: UNDEFINED = architektura niezdefiniowana = FAIL.
# Sprawdzamy tylko jeśli plik istnieje (jeśli nie istnieje, ARCH-001..003
# już zarejestrowały FAIL — nie dublujemy).
if repo_file "$ARCH_DOC"; then
  if grep -qE 'STATUS:[[:space:]]*UNDEFINED' "$ARCH_DOC"; then
    fail "ARCH-004 $ARCH_DOC nie ma STATUS: UNDEFINED" BLOCKING "$ARCH_DOC ma STATUS: UNDEFINED — architektura niezdefiniowana."
  else
    pass "ARCH-004 $ARCH_DOC nie ma STATUS: UNDEFINED" BLOCKING "$ARCH_DOC ma zdefiniowany status."
  fi
fi

if repo_file "$SOT_DOC"; then
  if grep -qE 'STATUS:[[:space:]]*UNDEFINED' "$SOT_DOC"; then
    fail "ARCH-005 $SOT_DOC nie ma STATUS: UNDEFINED" BLOCKING "$SOT_DOC ma STATUS: UNDEFINED — źródło prawdy niezdefiniowane."
  else
    pass "ARCH-005 $SOT_DOC nie ma STATUS: UNDEFINED" BLOCKING "$SOT_DOC ma zdefiniowany status."
  fi
fi

if repo_file "$OWN_DOC"; then
  if grep -qE 'STATUS:[[:space:]]*UNDEFINED' "$OWN_DOC"; then
    fail "ARCH-006 $OWN_DOC nie ma STATUS: UNDEFINED" BLOCKING "$OWN_DOC ma STATUS: UNDEFINED — własność niezdefiniowana."
  else
    pass "ARCH-006 $OWN_DOC nie ma STATUS: UNDEFINED" BLOCKING "$OWN_DOC ma zdefiniowany status."
  fi
fi

# ── ARCH-007 Spójność: ARCHITECTURE.md linkuje do SoT i OWNERSHIP ──
# WARNING — nie blokuje, ale sygnalizuje brak wzajemnych odwołań.
if repo_file "$ARCH_DOC"; then
  LINKS_SOT=0; LINKS_OWN=0
  grep -qE 'SOURCE-OF-TRUTH\.md' "$ARCH_DOC" && LINKS_SOT=1
  grep -qE 'OWNERSHIP\.md' "$ARCH_DOC" && LINKS_OWN=1
  if [ "$LINKS_SOT" -eq 1 ] && [ "$LINKS_OWN" -eq 1 ]; then
    pass "ARCH-007 Spójność: $ARCH_DOC linkuje do $SOT_DOC i $OWN_DOC" WARNING "Oba dokumenty są odwołane."
  else
    MISSING=""
    [ "$LINKS_SOT" -eq 0 ] && MISSING="$MISSING $SOT_DOC"
    [ "$LINKS_OWN" -eq 0 ] && MISSING="$MISSING $OWN_DOC"
    warn "ARCH-007 Spójność: $ARCH_DOC linkuje do $SOT_DOC i $OWN_DOC" "Brak odwołania do:$MISSING"
  fi
fi

# ── ARCH-008 Epistemic governance (INFORMATIONAL) ────────────
# Podsumowanie statusów dokumentów architektury.
UNDEF_N=0; DEF_N=0
for doc in "$ARCH_DOC" "$SOT_DOC" "$OWN_DOC"; do
  if repo_file "$doc"; then
    if grep -qE 'STATUS:[[:space:]]*UNDEFINED' "$doc"; then
      UNDEF_N=$((UNDEF_N+1))
    else
      DEF_N=$((DEF_N+1))
    fi
  fi
done
info "ARCH-008 Epistemic governance" "Dokumenty architektury: zdefiniowane=$DEF_N UNDEFINED=$UNDEF_N (INFORMATIONAL)."

# ── Evidence ─────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:architecture:FAIL" "verify" "architecture/architecture.sh"
else
  evidence_record "verify:architecture:PASS" "verify" "architecture/architecture.sh"
fi

verify_module_exit
