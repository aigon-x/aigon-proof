#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  llm-flow-optimizer.sh — BRAMKA LAW-102 (Optimal LLM Flow)
#
#  Pilnuje, żeby optymalizacja przepływu LLM nie była deklaracją:
#    C1 PRAWO      — law-llm-flow.yaml + LAW-102 w konstytucji (proza lub rejestr)
#    C2 KATALOG    — models-catalog.yaml istnieje i jest ŚWIEŻY (< TTL)
#    C3 MACIERZ    — model-matrix.yaml świeża; każda klasa >= min_links ogniw i redundant=true
#    C4 POKRYCIE   — katalog ma >=1 model ok=true; każdy wiersz ma providera
#    C5 PRODUKCJA  — odświeżanie wpięte w cron (/etc/cron.d/aigon-cron)
#    C6 PLAN 100%  — config/canonical/plan-opt-llm.yaml: WSZYSTKIE pozycje done=true
#                    (rozkaz Suwerena 2026-10-17: brak certyfikacji przed 100%)
#
#  Kontrakt: exit 0 = PASS, exit 1 = FAIL.  --selftest = dowód negatywny C3.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${PROD_ROOT:-/opt/PROD}"
LAW="$ROOT/config/canonical/law-llm-flow.yaml"
CAT="$ROOT/config/canonical/models-catalog.yaml"
MAT="$ROOT/config/canonical/model-matrix.yaml"
PLAN="$ROOT/config/canonical/plan-opt-llm.yaml"
CONST1="$ROOT/runtime/knowledge/01-canon/AIGON_CONSTITUTION.md"
CONST2="$ROOT/config/canonical/constitution.generated.yaml"
CRON=/etc/cron.d/aigon-cron
TTL="${LLM_FLOW_TTL_SECS:-86400}"
MIN_LINKS="${LLM_FLOW_MIN_LINKS:-4}"
SELFTEST=0; [ "${1:-}" = "--selftest" ] && SELFTEST=1

checks=(); f=0
add() { checks+=("$1"); }
fail() { add "[FAIL] $1"; f=1; }
pass() { add "[PASS] $1"; }

# ── C1 PRAWO ────────────────────────────────────────────────────────────────
[ -f "$LAW" ] && pass "C1a prawo wykonawcze: law-llm-flow.yaml" || fail "C1a brak $LAW"
if grep -q "LAW-102" "$CONST1" 2>/dev/null || grep -q "LAW-102" "$CONST2" 2>/dev/null; then
  pass "C1b LAW-102 obecne w konstytucji"
else
  fail "C1b LAW-102 nieobecne w konstytucji (proza i rejestr)"
fi

# ── C2 KATALOG ──────────────────────────────────────────────────────────────
if [ -f "$CAT" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$CAT") ))
  if [ "$age" -le "$TTL" ]; then pass "C2 katalog świeży (${age}s <= ${TTL}s)"
  else fail "C2 katalog przestarzały (${age}s > ${TTL}s) — odśwież llm_flow_matrix.py"; fi
else
  fail "C2 brak katalogu $CAT"
fi

# ── C3 MACIERZ + C4 POKRYCIE ────────────────────────────────────────────────
if [ -f "$MAT" ] && [ -f "$CAT" ]; then
  if MAT="$MAT" CAT="$CAT" MIN_LINKS="$MIN_LINKS" TTL="$TTL" python3 "$ROOT/tools/gates/llm-flow-structure.py"; then
    pass "C3/C4 macierz + pokrycie katalogu OK"
  else
    fail "C3/C4 macierz lub katalog niezgodne z kontraktem (szczegóły wyżej)"
  fi
else
  fail "C3/C4 brak macierzy lub katalogu"
fi

# ── C5 PRODUKCJA ────────────────────────────────────────────────────────────
if grep -q "llm_flow_matrix.py" "$CRON" 2>/dev/null; then
  pass "C5 odświeżanie wpięte w cron"
else
  fail "C5 brak wpisu llm_flow_matrix.py w $CRON — macierz nie odświeży się sama"
fi

# ── C6 PLAN 100% ────────────────────────────────────────────────────────────
if [ -f "$PLAN" ]; then
  if PLAN="$PLAN" python3 "$ROOT/tools/gates/llm-flow-plan.py"; then
    pass "C6 plan optymalizacji 100% wykonany"
  else
    fail "C6 plan optymalizacji NIE jest wykonany w 100% (szczegóły wyżej)"
  fi
else
  fail "C6 brak planu $PLAN"
fi

# ── DOWÓD NEGATYWNY (C3) ───────────────────────────────────────────────────
if [ "$SELFTEST" = 1 ]; then
  if MAT="$MAT" MIN_LINKS="$MIN_LINKS" python3 "$ROOT/tools/gates/llm-flow-negtest.py"; then
    pass "SELFTEST: sabotowana macierz -> FAIL (detektor żyje)"
  else
    fail "SELFTEST: detektor ŚLEPY (sabotaż nie wykryty)"
  fi
fi

echo "═══ LAW-102 — OPTIMAL LLM FLOW ═══"
printf '%s\n' "${checks[@]}"
if [ $f -eq 0 ]; then echo "CERTIFICATION: PASS"; exit 0; else echo "CERTIFICATION: FAIL"; exit 1; fi
