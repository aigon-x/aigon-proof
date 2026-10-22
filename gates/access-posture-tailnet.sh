#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/access-posture-tailnet.sh — BRAMKA (owijka) GATE-229
#  Woła strażnika płaszczyzny dostępu i mapuje jego kod wyjścia na kontrakt
#  bramki: 0 = OK, 2 = DEFEKT (mierzone naruszenie), 3 = BRAK POMIARU
#  (brak poświadczenia API — jawna odmowa, NIGDY cicha zieleń).
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail
SKRYPT="/srv/aigon/scripts/access-posture-tailnet.py"
[ -x "$SKRYPT" ] || { echo "access-posture-tailnet: BRAK SKRYPTU $SKRYPT"; exit 3; }
WYJ=$(mktemp)
python3 "$SKRYPT" --csv >"$WYJ" 2>&1
rc=$?
case "$rc" in
  0) echo "access-posture-tailnet: PASS (ACL bez allow-all, gość 1 grant bez ssh, tagi w normie)"; sed 's/^/  /' "$WYJ" | head -8; ;;
  2) echo "access-posture-tailnet: DEFEKT (zmierzone naruszenie)"; sed 's/^/  /' "$WYJ" | tail -4; ;;
  *) echo "access-posture-tailnet: BRAK POMIARU (rc=$rc) — nie ogłaszam zieleni"; sed 's/^/  /' "$WYJ" | tail -3; ;;
esac
rm -f "$WYJ"
exit "$rc"
