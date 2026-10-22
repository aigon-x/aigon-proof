#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/placement.sh — gate GATE-127 (hook-runner)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja żyje w
#  tools/verify/gates/domains/placement.sh (GATE-127 wg
#  config/canonical/placement.yaml: reguły P1..P5).
#
#  PO CO: GATE-127 powstał 2026-09-22 po tym, jak się okazało, że skrypt
#  krytyczny (failover Cloudflare) leżał w katalogu domowym operatora, a 4
#  skrypty wołane z crona leżały poza scripts/. Bez adaptera hook wskaże
#  w prożnię — czyli powtórzy klasę "zadeklarowane, nie wpięte".
#
#  NUMER: GATE-126 należy do kernel-health (kernel-health, hooks.yaml).
#  Zawsze sprawdź hooks.yaml PRZED nadaniem numeru.
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$ROOT/tools/verify/gates/domains/placement.sh" "$@"
