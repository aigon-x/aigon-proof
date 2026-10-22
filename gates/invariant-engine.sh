#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/invariant-engine.sh — adapter osi A (hook-runner / GATE-022)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja żyje w
#  tools/verify/gates/domains/invariant-engine.sh. Ten plik przekazuje sterowanie do kanonicznego źródła,
#  więc istnieje JEDNA implementacja.
#
#  PO CO (2026-10-12): GATE-022 (Invariant Engine) był osiągalny TYLKO przez
#  `verify.sh gates` (GitHub Actions → evidence.sh) — nie odpalał się ani
#  z hooków git, ani z crona (luka pokrycia: praca mogła przejść lokalnie
#  bez tej bramki). Wpięty w trigger cyclic:6h (klasa: CONTINUOUS).
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/gates/domains/invariant-engine.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL invariant-engine (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
