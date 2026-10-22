#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/effective-config.sh — adapter osi A (hook-runner / GATE-025)
#
#  WYGENEROWANY przez tools/gates/reconcile-gate-wiring.sh — NIE edytuj ręcznie.
#  Źródła: config/canonical/gate-registry.yaml (GATE-025, profil rejestru: RELEASE)
#          config/canonical/hooks.yaml (trigger: cyclic:daily)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja żyje w
#  tools/verify/gates/domains/effective-config.sh. Ten plik przekazuje sterowanie do kanonicznego źródła,
#  więc istnieje JEDNA implementacja.
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/gates/domains/effective-config.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL effective-config (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
