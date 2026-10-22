#!/usr/bin/env bash
# Schema PASS is not live constitutional verification; --closure rederives evidence.
set -euo pipefail
ROOT="${AIGON_ROOT:-/srv/aigon}"
CONTRACT_FILE="${CONTRACT_FILE:-$ROOT/config/canonical/constitution-status-contract.yaml}"
mode=contract
args=()
case "${1:-}" in
  --closure) mode=closure; args=(--input "${2:?closure JSON required}");;
  --input) mode=evaluate; args=(--input "${2:?evaluation JSON required}" --human);;
  --contract) CONTRACT_FILE="${2:?contract YAML required}";;
  '') ;;
  *) echo "FAIL: unsupported option $1" >&2; exit 1;;
esac
exec timeout 50 python3 "$ROOT/tools/canon/constitution-status.py" "$mode" --contract "$CONTRACT_FILE" "${args[@]}"
