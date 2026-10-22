#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/excellence-loop.sh — LAW-EXC-1 (Excellence Loop)
#
#  Bramka: skille principal/excellence MUSZĄ wykonywać się cyklicznie (pętla),
#  a wynik trafiać do evidence + metryk. FAIL nie może być cichy.
#  Kontrakt z hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

CFG=/opt/PROD/config/excellence-loop.yaml
EVID=/opt/PROD/data/excellence
METRICS="$EVID/excellence.prom"
RUNNER=/opt/PROD/scripts/excellence-loop.py

# 1. rejestr kadencji (SSOT) istnieje
if [ ! -f "$CFG" ]; then
  echo "FAIL excellence-loop: brak rejestru $CFG"
  exit 1
fi

# 2. runner istnieje i jest wykonywalny
if [ ! -x "$RUNNER" ]; then
  echo "FAIL excellence-loop: brak runnera $RUNNER"
  exit 1
fi

# 3. metryki wygenerowane (dowód, że pętla przebiegła co najmniej raz)
if [ ! -f "$METRICS" ]; then
  echo "FAIL excellence-loop: brak metryk $METRICS (pętla jeszcze nie przebiegła)"
  exit 1
fi

# 4. żaden audyt nie jest FAIL (pass=0) ani overdue=1
if grep -q 'aigon_excellence_pass{.*} 0' "$METRICS" 2>/dev/null; then
  echo "FAIL excellence-loop: wykryto skill z pass=0 (patrz $METRICS)"
  exit 1
fi
if grep -q 'aigon_excellence_overdue{.*} 1' "$METRICS" 2>/dev/null; then
  echo "FAIL excellence-loop: wykryto skill overdue (audyt nie doszedł do skutku)"
  exit 1
fi

# 5. runner zarejestrowany w harmonogramie (cykliczność = pętla)
#    UWAGA (2026-10-17): sprawdzanie WYŁĄCZNIE `crontab -l` mierzyło złą
#    powierzchnię — kanoniczny harmonogram AIGON żyje w /etc/cron.d/aigon-cron
#    (generowany z config/cron.yaml przez sync-cron.py), a nie w crontabie
#    użytkownika. Ten WARN fałszywie twierdził „brak cykliczności", gdy wpis
#    był w SSOT. Sprawdzamy OBA źródła.
if ! { crontab -l 2>/dev/null | grep -q "excellence-loop"; \
       grep -qs "excellence-loop" /etc/cron.d/aigon-cron; }; then
  echo "WARN excellence-loop: runner nie jest w harmonogramie (crontab ani /etc/cron.d/aigon-cron)"
fi

echo "PASS excellence-loop: rejestr + runner + metryki OK, brak FAIL/overdue"
exit 0
