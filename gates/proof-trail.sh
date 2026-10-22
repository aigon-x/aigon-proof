#!/usr/bin/env bash
# shellcheck disable=SC2086  # swiadome przypadki FOUNDATION (patrz commit 2026-09-22)
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/proof-trail.sh — gate proof-trail (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  Patch Governor (LAW-009/LAW-PATCH-001): ProofTrail — dowód że gate'y
#  widziały konkretny stan staged/worktree/HEAD. TWARDY GATE (L9):
#  brak binarki → auto-build (crate std-only); build fail → FAIL.
#
#  Kontrakt: exit 0 = PASS, exit 1 = FAIL (build nieudany / check FAIL).
#  Zmienne env:
#    AIGON_PG_SCOPE   — scope check (default pre-commit)
#    AIGON_PG_GATES   — wyniki poprzednich gate'ów "gid=STATUS gid=STATUS..."
#                       (hook-runner przekazuje kontekst całego triggera;
#                       izolowane wywołanie działa bez — check --scope sam)
#    AIGON_PG_NOBUILD — 1 = nie buduj automatycznie (testy)
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCOPE="${AIGON_PG_SCOPE:-pre-commit}"
PG_BIN="$ROOT/runtime/target/release/patch-governor"

if [ ! -x "$PG_BIN" ]; then
  if [ "${AIGON_PG_NOBUILD:-0}" = "1" ]; then
    echo "proof-trail: FAIL (patch-governor niezbudowany, auto-build wyłączony)"
    exit 1
  fi
  export PATH="$HOME/.cargo/bin:$PATH"
  # Fix 2026-09-23: build MUSI mieć limit. Bez timeoutu ten gate wisiał
  # bezterminowo wewnątrz hooka pre-commit (zmierzone: 10+ min na obciążonym
  # hoście, commit nie mógł się zakończyć). 300 s to górna granica sensownego
  # builda patch-governora; przekroczenie = FAIL z jasnym powodem, nie zawieszenie.
  (cd "$ROOT" && timeout 300 cargo build --release -p patch-governor) >/dev/null 2>&1 || true
fi

if [ ! -x "$PG_BIN" ]; then
  echo "proof-trail: FAIL (patch-governor niezbudowany i cargo build nieudany — L9 twardy gate)"
  exit 1
fi

GATE_ARGS=""
if [ -n "${AIGON_PG_GATES:-}" ]; then
  for gr in $AIGON_PG_GATES; do
    GATE_ARGS="$GATE_ARGS --gate $gr"
  done
fi

OUT=$(cd "$ROOT" && runtime/target/release/patch-governor check --scope "$SCOPE" $GATE_ARGS 2>&1)
RC=$?
if [ $RC -eq 0 ]; then
  echo "proof-trail: PASS ($(echo "$OUT" | tail -1 | cut -c1-120))"
  exit 0
fi
echo "proof-trail: FAIL ($(echo "$OUT" | tail -1 | cut -c1-200))"
exit 1
