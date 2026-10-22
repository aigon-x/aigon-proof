#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/version-identity.sh — gate GATE-125 (hook-runner)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja żyje w
#  tools/verify/gates/domains/version-identity.sh (GATE-125 wg
#  config/canonical/gate-registry.yaml: severity critical, pipeline_stage
#  push, blocking true).
#
#  PO CO: GATE-125 powstał 2026-09-22 i został zarejestrowany, ale NIE miał
#  ani triggera w hooks.yaml, ani adaptera — istniał więc WYŁĄCZNIE na osi
#  CI (`verify.sh gates`), a lokalnie nie odpalał się nigdy. Wykrył to
#  ratchet pokrycia: gate-reachability ci_only 20 -> 21.
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$ROOT/tools/verify/gates/domains/version-identity.sh" "$@"
