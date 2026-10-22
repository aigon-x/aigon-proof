#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/world-model-coverage.sh — gate world-model-coverage (GATE-130)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja GATE-130
#  żyje w tools/verify/gates/domains/world-model-coverage.sh. Ten plik
#  przekazuje sterowanie do kanonicznego źródła, więc istnieje JEDNA
#  implementacja.
#
#  PO CO: GATE-130 (WORLD-MODEL-COVERAGE, high) mierzy ŻYWY stan world
#  modelu runtime'u — C0/C3 żywotność (przyrost obserwacji), domknięcie
#  pętli (predykcje MIERZONE, nie tylko liczone), spójność powierzchni
#  (health vs metryka: jedna prawda) i przypisanie źródeł. Bramka istniała
#  w rejestrze bez triggera, więc ratchet tools/gates/gate-reachability.sh
#  słusznie blokował push: nowa bramka bez ścieżki wykonania jest
#  deklaracją, nie kontrolą.
#
#  Trigger: cyclic:hourly (pomiar żywego stanu — jak system-twin i
#  state-ratchet; block_on_fail: false, więc dryf raportuje, nie blokuje
#  ruchu wszystkich agentów).
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/gates/domains/world-model-coverage.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL world-model-coverage (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
