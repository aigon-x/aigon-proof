#!/usr/bin/env bash
# GATE-245: hardware-health — BRAMKA Z DANYCH (config/canonical/gate-specs.yaml).
# NIE EDYTUJ RĘCZNIE: próg i reguła są w specyfikacji; tu jest tylko wrapper.
# Kontrakt: 0=PASS, 1=FAIL, 2=UNKNOWN. --selftest uruchamia fault_probe (dowód negatywny).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
RUN="$ROOT/scripts/gate-run.py"
[ -r "$RUN" ] || { echo "FAIL: brak $RUN"; exit 2; }
if [ "${1:-}" = "--selftest" ]; then
  python3 "$RUN" GATE-245 --fault
  rc=$?
  if [ "$rc" -eq 1 ]; then echo "SELFTEST: PASS (bramka reaguje na fault)"; exit 0; fi
  echo "SELFTEST: FAIL (oczekiwano rc=1 z fault_probe, jest $rc)"; exit 1
fi
python3 "$RUN" GATE-245 "$@"
