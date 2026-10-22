#!/usr/bin/env bash
# GATE-D1: explicit v1 contract + evidence gate, not prose/keyword scoring.
# Normal use: skill-determinism.sh FILE.json
# Alternative input: AIGON_QUALITY_CONTRACT_FILE=FILE.json skill-determinism.sh
# --validate-contract-only checks structure and emits CONTRACT_VALID, not PASS.
# --schema / --example document the deliberately narrow supported interface.
# MAX_VIOLATIONS has no effect. No default canonical Markdown file is assumed.
set -euo pipefail

gate_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$gate_root/tools/quality/skill_contract_gate.py"

if [[ ! -f "$validator" ]]; then
  printf '%s\n' '{"schema":"aigon.quality-result/v1","state":"UNVERIFIED","reason":"contract validator unavailable"}'
  exit 2
fi

# Select a document from the environment only when no positional input exists.
# Do not interpolate/evaluate file contents or allow an environment success flag.
if [[ "$#" -eq 0 ]]; then
  if [[ -n "${AIGON_QUALITY_CONTRACT_FILE:-}" ]]; then
    set -- -- "$AIGON_QUALITY_CONTRACT_FILE"
  fi
elif [[ "$#" -eq 1 && "$1" == "--validate-contract-only" && -n "${AIGON_QUALITY_CONTRACT_FILE:-}" ]]; then
  set -- "$1" -- "$AIGON_QUALITY_CONTRACT_FILE"
fi

exec python3 -I "$validator" "$@"
