#!/usr/bin/env bash
# GATE-235: SKILL-REFERENCE-INTEGRITY — skill nie może wskazywać nieistniejącego pliku.
#
# POWÓD (zmierzone 2026-10-17): 2919 SKILL.md, 496 unikalnych referencji do ścieżek,
# których nie ma (853 wystąpienia); 545 skilli (19%) ma co najmniej jedną taką.
# Skill opisujący procedurę z nieistniejącym narzędziem NIE WYKONA SIĘ po instrukcji.
#
# Kontrakt: 0=PASS, 1=FAIL (regresja klasy B), 2=WARN (dług w baseline)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
SCAN="$ROOT/scripts/skill-reference-integrity.py"

echo "── GATE-235 skill-reference-integrity ──"
[ -r "$SCAN" ] || { echo "FAIL: brak $SCAN"; exit 1; }

if [ "${1:-}" = "--selftest" ]; then
  echo "[T1] skan bieżący"
  out="$(python3 "$SCAN" 2>&1)"; rc=$?
  echo "$out" | tail -2
  [ "$rc" -le 2 ] || { echo "SELFTEST: FAIL (skan nie działa)"; exit 1; }

  # DOWÓD NEGATYWNY: wstrzykujemy skill z referencją do nieistniejącego pliku
  # i sprawdzamy, że skan ją WIDZI (bez ruszania repo — katalog tymczasowy).
  tmp_skill="$ROOT/skills/shared/__selftest_ref_integrity__"
  mkdir -p "$tmp_skill"
  printf '%s\n' "---" "name: selftest-ref-integrity" "---" \
    "Uruchom: scripts/nieistniejacy-skrypt-selftest.py --x" > "$tmp_skill/SKILL.md"
  leak="$(python3 "$SCAN" --grep nieistniejacy-skrypt-selftest 2>/dev/null || echo 0)"
  rm -rf "$tmp_skill"
  echo "[T2] wstrzyknięta zła referencja wykryta: $leak (oczekiwane 1)"
  [ "$leak" = "1" ] || { echo "SELFTEST: FAIL (skan jest ŚLEPY na wstrzykniętą referencję)"; exit 1; }

  echo "SELFTEST: PASS (2/2)"
  exit 0
fi

python3 "$SCAN"; rc=$?
case "$rc" in
  0) echo "PASS skill-reference-integrity" ;;
  2) echo "WARN skill-reference-integrity (dług w baseline — nie blokuje, ale rośnie ryzyko)" ;;
  *) echo "FAIL skill-reference-integrity (skill wskazuje nieistniejące pliki)" ;;
esac
exit "$rc"
