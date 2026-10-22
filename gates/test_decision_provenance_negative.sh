#!/usr/bin/env bash
# Test negatywny S1-T1: kompletny ledger => PASS; rekord bez causation_id => FAIL;
# przywrócenie => PASS. Wyłącznie na kopii w mktemp -d.
set -uo pipefail
GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/law-decision-provenance.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
now=$(date -u +%Y-%m-%dT%H:%M:%S)
rec() { printf '{"id":"%s","ts":"%s","run_id":"r%s","actor":"claude","tools":["Bash"],"evidence":["e"],"outcome":"done","trace_id":"t%s"%s}\n' "$1" "$now" "$1" "$1" "$2"; }
{ rec 1 ',"causation_id":"c0"'; rec 2 ',"causation_id":"r1"'; rec 3 ',"causation_id":"r2"'; } > "$T/good.ndjson"
cp "$T/good.ndjson" "$T/orig"
export PROV_LEDGER_DIR="$T" PROV_MIN_PCT=100
fail=0
"$GATE" >/dev/null; [[ $? -eq 0 ]] && echo "ok 1 kompletny => PASS" || { echo "NOT OK 1 kompletny nie przeszedł"; fail=1; }
sed -i '2s/,"causation_id":"r1"//' "$T/good.ndjson"
"$GATE" >/dev/null; [[ $? -eq 1 ]] && echo "ok 2 brak causation_id => FAIL" || { echo "NOT OK 2 bramka przepuściła rekord bez causation_id"; fail=1; }
cp "$T/orig" "$T/good.ndjson"
"$GATE" >/dev/null; [[ $? -eq 0 ]] && echo "ok 3 przywrócony => PASS" || { echo "NOT OK 3 po przywróceniu FAIL"; fail=1; }
rm -f "$T"/*.ndjson
"$GATE" >/dev/null; [[ $? -eq 1 ]] && echo "ok 4 pusty ledger => ERROR (nie PASS)" || { echo "NOT OK 4 pusty ledger dał PASS"; fail=1; }
exit $fail
