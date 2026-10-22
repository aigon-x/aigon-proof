#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/lesson-audit.sh — gate lesson-audit (hook-runner)
#
#  SAMO-UZUPEŁNIANIE BRAMEK (kanon Suwerena 2026-09-07): „bramki powinny
#  się SAME uzupełniać po wykryciu czegoś nowego w trakcie pracy".
#
#  Każda lekcja w runtime/knowledge/08-lessons/ z sekcją "## Gate" deklaruje:
#    Gate: <id>            — bramka, która ma pokrywać klasę problemu
#    Status: COVERED|OPEN  — COVERED = bramka istnieje; OPEN = luka jawna
#
#  Ten gate pilnuje SPÓJNOŚCI rejestru lekcji z implementacjami:
#    1. Lekcja z "Status: COVERED" i "Gate: <id>" — skrypt
#       tools/gates/<id>.sh MUSI istnieć (inaczej FAIL: zapowiedziana
#       bramka nie powstała — samo-uzupełnianie nie zadziałało).
#    2. Lekcja z "Status: OPEN" — WARN (exit 2): znana luka, do pokrycia
#       nowym gate'em (lekcja jest JAWNĄ instrukcją uzupełnienia).
#    3. Lekcja "## Gate" bez linii Gate:/Status: — FAIL (zły szablon).
#
#  Cykl życia (samo-uzupełnianie):
#    praca → nowa klasa problemu → zapisz lekcję (08-lessons, sekcja Gate,
#    Status: OPEN) → lesson-audit WARNuje → dodaj tools/gates/<id>.sh +
#    wpis hooks.yaml → zmień Status: COVERED → lesson-audit PASS.
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS, 1 = FAIL, 2 = WARN.
#  Analiza STATYCZNA (grep) — bezpieczna w hooku. Read-only.
#  Env do testów: AIGON_LA_LESSONS (katalog lekcji), AIGON_LA_GATES (katalog gate'ów).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LESSONS="${AIGON_LA_LESSONS:-$ROOT/runtime/knowledge/08-lessons}"
GATES="${AIGON_LA_GATES:-$ROOT/tools/gates}"

[ -d "$LESSONS" ] || { echo "lesson-audit: brak $LESSONS"; exit 2; }
[ -d "$GATES" ]   || { echo "lesson-audit: brak $GATES"; exit 2; }

FAILS=0; WARNS=0; PASSES=0
for f in "$LESSONS"/*.md; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  # Sekcja ## Gate — tylko tam obowiązuje kontrakt
  if ! grep -q '^## Gate' "$f"; then
    continue  # lekcja bez sekcji Gate = poza kontraktem (czysta wiedza)
  fi
  gate_id="$(grep -m1 '^Gate: ' "$f" | sed 's/^Gate: //' | tr -d '[:space:]')"
  status="$(grep -m1 '^Status: ' "$f" | sed 's/^Status: //' | tr -d '[:space:]')"
  if [ -z "$gate_id" ] || [ -z "$status" ]; then
    echo "FAIL lesson-audit: $base — sekcja Gate bez 'Gate: <id>' i 'Status: COVERED|OPEN'"
    FAILS=$((FAILS+1)); continue
  fi
  case "$status" in
    COVERED)
      if [ -x "$GATES/$gate_id.sh" ] || [ -f "$GATES/$gate_id.sh" ]; then
        echo "PASS lesson-audit: $base → COVERED przez $gate_id.sh"
        PASSES=$((PASSES+1))
      else
        echo "FAIL lesson-audit: $base — Status: COVERED, ale brak $GATES/$gate_id.sh (samo-uzupełnianie nie zadziałało)"
        FAILS=$((FAILS+1))
      fi ;;
    OPEN)
      echo "WARN lesson-audit: $base — luka jawna (Gate: $gate_id); uzupełnij tools/gates/$gate_id.sh + hooks.yaml, potem Status: COVERED"
      WARNS=$((WARNS+1)) ;;
    *)
      echo "FAIL lesson-audit: $base — nieznany Status: '$status' (oczekiwane COVERED|OPEN)"
      FAILS=$((FAILS+1)) ;;
  esac
done

echo "lesson-audit: PASS=$PASSES WARN=$WARNS FAIL=$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
[ "$WARNS" -eq 0 ] || exit 2
exit 0
