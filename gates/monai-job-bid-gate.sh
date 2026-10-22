#!/usr/bin/env bash
# -----------------------------------------------------------------------
#  tools/gates/monai-job-bid-gate.sh - ADAPTER hook-runnera (os A) dla bramki MONAI.
#  Zero duplikacji: deleguje do kanonicznego dyskretora
#  products/monai/tools/monai-gate.sh. Wzorzec: tools/gates/monai-channel-job.sh.
#  Bramka świadomej weryfikacji kanału job (kanon 2026-10-13): bid_allowed()
#  (realna weryfikacja konta Freelancer przez API) + cost-stop jako druga bramka
#  + metryki monai_job_bid_gate{reason}/monai_job_account_verified + span OTel.
#  Kontrakt hook-runnera: exit 0 = PASS/WARN, exit 1 = FAIL.
# -----------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMPL="$ROOT/products/monai/tools/monai-gate.sh"
[ -f "$IMPL" ] || { echo "FAIL monai-job-bid-gate (brak implementacji: $IMPL - brak dowodu nie jest PASS)"; exit 1; }
exec bash "$IMPL" "monai-job-bid-gate" "$@"
