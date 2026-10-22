#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/kernel-health.sh — gate GATE-126 (hook-runner)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja żyje w
#  tools/verify/gates/domains/kernel-health.sh (GATE-126 wg
#  config/canonical/gate-registry.yaml: severity critical, pipeline_stage
#  push, blocking true).
#
#  PO CO: kernel zarejestrowany w manifescie (`enabled: true`) a
#  niezainicjalizowany raportuje Pending i nic tego nie podnosi — jedynym
#  sladem była stala w logu ("{n}/12 kernels initialized" przy 34 kernelach
#  w SSOT). Bramka mierzy healthy == total per node z Prometheusa, a liczby
#  bierze z SSOT (runtime/manifests/kernels.yaml + config/mesh-nodes.yaml).
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$ROOT/tools/verify/gates/domains/kernel-health.sh" "$@"
