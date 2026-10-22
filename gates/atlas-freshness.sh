#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/atlas-freshness.sh — gate GATE-128 (hook-runner)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja zyje w
#  tools/verify/gates/domains/atlas-freshness.sh (GATE-128 wg
#  config/canonical/gate-registry.yaml: severity critical, pipeline_stage
#  push, blocking true).
#
#  PO CO: atlas skryptow i bramek (encyklopedia + manifest + KANON.md) jest
#  GENEROWANY z SSOT; bez bramki rozjezdzalby sie z inwentarzem cicho —
#  dokumentacja wygladalaby na zrodlo prawdy, a klamalaby.
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$ROOT/tools/verify/gates/domains/atlas-freshness.sh" "$@"
