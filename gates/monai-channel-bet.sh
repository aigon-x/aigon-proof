#!/usr/bin/env bash
# -----------------------------------------------------------------------
#  tools/gates/monai-channel-bet.sh - ADAPTER hook-runnera (os A) dla bramki MONAI.
#  Zero duplikacji: deleguje do kanonicznego dyskretora
#  products/monai/tools/monai-gate.sh. Wzorzec: tools/gates/aio-okolic-products.sh.
#  Kontrakt hook-runnera: exit 0 = PASS/WARN, exit 1 = FAIL.
# -----------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMPL="$ROOT/products/monai/tools/monai-gate.sh"
[ -f "$IMPL" ] || { echo "FAIL monai-channel-bet (brak implementacji: $IMPL - brak dowodu nie jest PASS)"; exit 1; }
exec bash "$IMPL" "monai-channel-bet" "$@"
