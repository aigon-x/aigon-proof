#!/usr/bin/env bash
# GATE-D3: verify a canonical snapshot against an existing, independently managed
# baseline. This post-check does not authorize a write or prevent a later write.
# Exit codes: 0 integrity PASS; 1 FAIL; 2 advisory posture WARN.
# --selftest uses only its own temporary tree, never /opt/PROD.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)" || exit 1
ENGINE="$ROOT/tools/quality/canonical_integrity_gate.py"
if [[ ! -f "$ENGINE" ]]; then
  printf '%s\n' 'canonical-write-guard: FAIL — missing integrity verifier' >&2
  exit 1
fi
exec python3 -I "$ENGINE" --root "$ROOT" "$@"
