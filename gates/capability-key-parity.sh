#!/usr/bin/env bash
# GATE-239: CAPABILITY-KEY-PARITY — manifest == katalog runtime po ZNORMALIZOWANYM kluczu.
# Powód (2026-10-17): porównanie po pełnej nazwie dawało 91/146 i 53 fałszywe „sieroty",
# bo manifest używa `backend:nazwa`, a runtime publikuje samo `name`. `domain` w runtime
# bywa kategorią (AI/API/Architecture), więc kluczem jest nazwa(lower) + krotność.
# Kontrakt: 0=PASS, 1=FAIL, 2=WARN (runtime nieosiągalny — pomiar niemożliwy).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
SCAN="$ROOT/scripts/capability-key-parity.py"
echo "── GATE-239 capability-key-parity ──"
[ -r "$SCAN" ] || { echo "FAIL: brak $SCAN"; exit 1; }
if [ "${1:-}" = "--selftest" ]; then
  out="$(python3 "$SCAN" --selftest 2>&1)"; rc=$?
  echo "$out" | tail -2
  [ "$rc" -eq 0 ] || { echo "SELFTEST: FAIL"; exit 1; }
  exit 0
fi
out="$(python3 "$SCAN" 2>&1)"; rc=$?
echo "$out" | head -4
case "$rc" in
  0) echo "PASS capability-key-parity" ;;
  2) echo "WARN capability-key-parity (runtime nieosiągalny)" ;;
  *) echo "FAIL capability-key-parity (zbiory capability się rozjechały)" ;;
esac
exit "$rc"
