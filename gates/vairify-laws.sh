#!/usr/bin/env bash
# -----------------------------------------------------------------------
#  tools/gates/vairify-laws.sh - ADAPTER hook-runnera (os A) dla bramki vairify.
#  Zero duplikacji: deleguje do kanonicznego dyskretora
#  tools/gates/product-wiring.sh. Wzorzec: tools/gates/monai-laws.sh.
#  PRAWA produktu: config/canonical/product-vairify.yaml
#  Kontrakt hook-runnera: exit 0 = PASS/WARN, exit 1 = FAIL.
# -----------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$ROOT/tools/gates/product-wiring.sh" "vairify" "$@"
