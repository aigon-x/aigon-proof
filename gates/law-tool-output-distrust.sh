#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/law-tool-output-distrust.sh — S4-T2 (wynik narzędzia jest niezaufany)
#
#  PRAWO: „exit 0" ani „HTTP 200" NIE dowodzą poprawnego wyniku. Konsument
#  wyniku narzędzia MUSI sprawdzić kod HTTP i format, a strona błędu nie
#  może zostać zaliczona jako treść.
#
#  ZMIERZONY DEFEKT (pamięć scatter-504-html-jako-wynik): scatter wołał
#  ollamę `curl -s` BEZ -f i bez %{http_code}; przy 504 curl dawał exit 0,
#  a HTML HAProxy szedł jako „wynik" podzadania (17/26 `done` ze stroną błędu).
#
#  STRAŻNIK REGRESJI (w źródle kernel_cloning.rs):
#    (1) każde Command::new(curl) ma w argumentach --fail-with-body ORAZ %{http_code};
#    (2) istnieje test z fixture'em "504 Gateway Time-out" (HTML-jako-wynik).
#  Override: LAW_TOD_FILE. exit 0 = PASS, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
F="${LAW_TOD_FILE:-/srv/aigon/runtime/crates/aigon-kernel/src/kernel_cloning.rs}"
[ -f "$F" ] || { echo "[FAIL] brak $F"; exit 1; }
fail=0
ncurl=$(grep -cE 'Command::new\((bin|"(/usr/bin/)?curl")\)' "$F")
nsafe=$(grep -E '\.args\(\[' "$F" | grep -E '"-sS?"' | grep -c -- '--fail-with-body.*http_code')
nraw=$(grep -E '\.args\(\[' "$F" | grep -E '"-sS?"' | grep -vc -- '--fail-with-body')
if (( ncurl > 0 && nsafe >= ncurl && nraw == 0 )); then
  echo "[PASS] $ncurl wywołań curl, $nsafe z --fail-with-body + %{http_code}, 0 surowych"
else
  echo "[FAIL] curl: wywołań=$ncurl bezpiecznych=$nsafe surowych(-s bez -f)=$nraw — strona błędu może przejść jako wynik"; fail=1
fi
if grep -q '504 Gateway Time-out' "$F"; then echo "[PASS] test HTML-504-jako-wynik obecny"
else echo "[FAIL] brak testu regresji HTML-504-jako-wynik"; fail=1; fi
[ $fail -eq 0 ] && { echo "law-tool-output-distrust: PASS"; exit 0; }
echo "law-tool-output-distrust: FAIL"; exit 1
