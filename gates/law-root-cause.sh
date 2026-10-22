#!/usr/bin/env bash
# law-root-cause.sh — LAW-ROOT-CAUSE (S11-T4, rozszerza LAW-60/LAW-57)
# Każdy raport incydentu docs/incidents/*.md (poza README) ma sekcję
# przyczyny źródłowej (nagłówek albo pole: root cause / przyczyna).
# Read-only. Wejścia: INCIDENTS_DIR.
set -uo pipefail
ROOT="${AIGON_ROOT:-/srv/aigon}"
INCIDENTS_DIR="${INCIDENTS_DIR:-$ROOT/docs/incidents}"
n=0; bad=0
for f in "$INCIDENTS_DIR"/*.md; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in README.md|readme.md|_template*) continue ;; esac
  n=$((n+1))
  if grep -qiE '^(#+.*|\*\*|[-*] *\**)?(root[ _-]?cause|przyczyna)' "$f"; then
    echo "[PASS] $(basename "$f")"
  else
    echo "[FAIL] $(basename "$f"): brak sekcji root cause / przyczyna"; bad=$((bad+1))
  fi
done
if [ $n -eq 0 ]; then echo "[UNKNOWN] 0 raportów incydentów w $INCIDENTS_DIR"; echo "STATUS: UNKNOWN"; exit 1; fi
echo "incydentów=$n bez_przyczyny=$bad"
[ $bad -eq 0 ] && { echo "STATUS: PASS"; exit 0; }
echo "STATUS: FAIL"; exit 1
