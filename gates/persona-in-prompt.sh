#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/persona-in-prompt.sh — adapter osi A (hook-runner / GATE-139)
#
#  BRAKUJĄCE OGNIWO (naprawa 2026-10-01, audyt bramek):
#  config/canonical/gate-registry.yaml deklaruje GATE-139 (Persona-In-Prompt,
#  LAW-79) jako IMPLEMENTED (profile: RELEASE, command:
#  tools/verify/gates/domains/persona-in-prompt.sh), a config/canonical/hooks.yaml
#  wpina go pod trigger `persona-in-prompt` (cyclic:hourly). ALE w tools/gates/
#  NIE BYŁO pliku tools/gates/persona-in-prompt.sh — a hook-runner.sh uruchamia
#  bramki WYŁĄCZNIE jako tools/gates/<id>.sh. Skutek: wpis w hooks.yaml był
#  deklaracją bez dowodu wykonania — hook-runner raportowałby brak implementacji,
#  a w praktyce GATE-139 nie odpalał się w osi A (cichy martwy trigger — klasa
#  GATE-138, którą komentarz w hooks.yaml miał rzekomo wykluczyć).
#
#  Ten adapter przekazuje sterowanie do kanonicznej implementacji. Jedna
#  implementacja, zero duplikacji logiki.
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/gates/domains/persona-in-prompt.sh"

if [ ! -f "$CANONICAL" ]; then
  # Brak implementacji != sukces (LAW-011 / NO FALSE GREEN).
  echo "FAIL persona-in-prompt (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
