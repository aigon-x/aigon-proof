#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/mesh-mirror.sh — gate mesh-mirror (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  Lustro config/mesh.yaml == runtime/manifests/mesh.yaml — manifest
#  runtime'u NIE może dryfować od SSOT configu (incydent mesh split-brain).
#
#  Kontrakt: exit 0 = PASS, exit 1 = FAIL (lustro rozjechane).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if diff -q "$ROOT/config/mesh.yaml" "$ROOT/runtime/manifests/mesh.yaml" >/dev/null 2>&1; then
  echo "mesh-mirror: PASS (lustro zgodne)"
  exit 0
fi
echo "mesh-mirror: FAIL (lustro rozjechane: config/mesh.yaml != runtime/manifests/mesh.yaml)"
exit 1
