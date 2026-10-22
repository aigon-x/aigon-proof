#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/law-operator-hold.sh — S3-T4 (rozszerza LAW-Ω1, LAW-96)
#
#  PRAWO: operator może „przytrzymać" POJEDYNCZY zasób (kontener/usługę),
#  a KAŻDY automat leczący (self-heal, stack-health, docker-protect) go
#  pomija i liczy pominięcie (outcome=skipped reason=operator_hold).
#  Bez tego ręczna konserwacja przegrywa z automatem, który „naprawia"
#  celowo zatrzymaną usługę w ciągu minuty.
#
#  POMIAR (w źródle): każdy healer musi odwoływać się do mechanizmu hold.
#    per-zasób  : wzorzec operator_hold / OPERATOR_HOLD          -> PASS
#    globalny   : tylko plik maintenance (wszystko albo nic)     -> PARTIAL (FAIL)
#    brak       : żadnego mechanizmu                             -> FAIL
#  Override: LAW_HOLD_HEALERS (lista plików). exit 0 = PASS, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
R=/srv/aigon/scripts
HEALERS="${LAW_HOLD_HEALERS:-$R/self-heal.sh $R/stack-health-check.sh $R/docker-protect.sh}"
fail=0
for f in $HEALERS; do
  n=$(basename "$f")
  if [ ! -f "$f" ]; then echo "[UNKNOWN] $n — brak pliku"; continue; fi
  if grep -qE 'operator_hold|OPERATOR_HOLD' "$f"; then
    echo "[PASS]    $n — honoruje hold per-zasób"
  elif grep -qiE 'maintenance|MAINT=' "$f"; then
    echo "[PARTIAL] $n — tylko globalne okno maintenance (bez hold per-zasób)"; fail=1
  else
    echo "[FAIL]    $n — żadnego mechanizmu hold: automat leczy zasób trzymany przez operatora"; fail=1
  fi
done
[ $fail -eq 0 ] && { echo "law-operator-hold: PASS"; exit 0; }
echo "law-operator-hold: FAIL"; exit 1
