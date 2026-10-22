#!/usr/bin/env bash
# GATE-243: STATE-OF-THE-ART-EVIDENCE — LAW-STATE-OF-THE-ART-1 (RESEARCH → DELTA → KOD).
# Kontrakt: 0=PASS, 1=FAIL (nowe feat/arch bez dowodu), 2=WARN (brak repo/baseline)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
SCAN="$ROOT/scripts/state-of-the-art-evidence.py"
echo "── GATE-243 state-of-the-art-evidence ──"
[ -r "$SCAN" ] || { echo "FAIL: brak $SCAN"; exit 1; }
if [ "${1:-}" = "--selftest" ]; then python3 "$SCAN" --selftest; exit $?; fi
python3 "$SCAN" "$@"; rc=$?
case "$rc" in
  0) echo "PASS state-of-the-art-evidence" ;;
  2) echo "WARN state-of-the-art-evidence (brak danych do sprawdzenia)" ;;
  *) echo "FAIL state-of-the-art-evidence (commit feat/arch bez RESEARCH)" ;;
esac
exit "$rc"
