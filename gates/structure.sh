#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/structure.sh — adapter osi A (hook-runner / GATE-006)
#
#  WYGENEROWANY przez tools/gates/reconcile-gate-wiring.sh — NIE edytuj ręcznie.
#  Źródła: config/canonical/gate-registry.yaml (GATE-006, profil rejestru: LOCAL_FAST)
#          config/canonical/hooks.yaml (trigger: cyclic:hourly)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja żyje w
#  tools/verify/gates/domains/structure.sh. Ten plik przekazuje sterowanie do kanonicznego źródła,
#  więc istnieje JEDNA implementacja.
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/gates/domains/structure.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL structure (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
