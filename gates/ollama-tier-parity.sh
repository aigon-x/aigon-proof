#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/ollama-tier-parity.sh — gate ollama-tier-parity (hook-runner)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja żyje w
#  tools/verify/gates/domains/ollama-tier-parity.sh. Ten plik przekazuje
#  sterowanie do kanonicznego źródła, więc istnieje JEDNA implementacja.
#
#  PO CO (KANON 2026-09-22): GATE-124 OLLAMA-TIER-PARITY figurował w rejestrze
#  jako critical + blocking + IMPLEMENTED, ale NIE MIAŁ TRIGGERA ani wejściówki
#  w tools/gates/ — czyli był zadeklarowany i nieosiągalny (dokładnie ta sama
#  klasa defektu, którą opisuje nagłówek adaptera state-ratchet). Wykryła to
#  bramka gate-reachability: ratchet pokrycia spadł (ci_only 20 -> 21) i
#  zablokował push. Teraz bramka ma I trigger w config/canonical/hooks.yaml
#  (git:pre-push), I adapter tutaj.
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/tools/verify/gates/domains/ollama-tier-parity.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "FAIL ollama-tier-parity (brak kanonicznej implementacji: $CANONICAL)"
  exit 1
fi

cd "$ROOT" || exit 1
exec bash "$CANONICAL" "$@"
