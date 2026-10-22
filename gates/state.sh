#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/state.sh — adapter osi A (hook-runner / GATE-019)
#
#  WYGENEROWANY przez tools/gates/reconcile-gate-wiring.sh — NIE edytuj ręcznie.
#  Źródła: config/canonical/gate-registry.yaml (GATE-019, profil rejestru: PRE_PUSH)
#          config/canonical/hooks.yaml (trigger: cyclic:6h)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja żyje w
#  tools/verify/gates/domains/state.sh. Ten plik przekazuje sterowanie do kanonicznego źródła,
#  więc istnieje JEDNA implementacja.
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/gates/domains/state.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL state (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
