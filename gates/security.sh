#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/security.sh — adapter osi A (hook-runner / GATE-005)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja żyje w
#  tools/verify/gates/domains/security.sh. Ten plik przekazuje sterowanie do kanonicznego źródła,
#  więc istnieje JEDNA implementacja.
#
#  PO CO (2026-10-12): GATE-005 (Brak hardcoded sekretów) był osiągalny TYLKO przez
#  `verify.sh gates` (GitHub Actions → evidence.sh) — nie odpalał się ani
#  z hooków git, ani z crona (luka pokrycia: praca mogła przejść lokalnie
#  bez tej bramki). Wpięty w trigger cyclic:daily (klasa: RELEASE).
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/gates/domains/security.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL security (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
