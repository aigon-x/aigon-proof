#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/verify/gates/domains/mesh-ui-parity.sh
#  GATE: parity artefaktów UI między replikami, które serwują mesh.aigon.dev
#
#  DEFEKT ZMIERZONY 2026-10-19 (zgłoszenie Suwerena): panel mapy raz działał,
#  raz dawał 404 na nowym chunku. Przyczyna: build UI szedł TYLKO na
#  local-aigon, a nginx balansuje między prod-aigon (master 100.99.59.100)
#  i contabo-aigon. prod-aigon miał stary index.html → 404 na nowym
#  NeuralMap-<hash>.js; contabo nie miał go wcale do czasu ręcznego rsync.
#  To TA SAMA klasa co graph.json mapy: artefakt bez dystrybucji na repliki.
#
#  CO MIERZY:
#    C1 każda replika z listy jest osiągalna po SSH,
#    C2 md5 index.html identyczny z lokalnym (jeden build = jedna prawda),
#    C3 chunk NeuralMap-*.js wskazywany przez lokalny dist istnieje na replice,
#    C4 publiczny https://mesh.aigon.dev/assets/<chunk> zwraca 200.
#
#  Kontrakt runnera: 0 = PASS, 1 = FAIL, 2 = WARN/UNKNOWN.
#  --selftest: dowód negatywny (brak dist / brak hashed assets / brak replik).
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_ROOT:-/opt/PROD}"
DIST="$ROOT/products/mesh-observatory/ui/dist"
KEY="${AIGON_SSH_KEY:-/home/sniegul/.ssh/id_aigon_local}"
REPLICAS="${AIGON_UI_REPLICAS:-prod-aigon contabo-aigon}"
SSH_OPTS="-o ConnectTimeout=8 -o IdentitiesOnly=yes -i $KEY -o StrictHostKeyChecking=accept-new"
FAILS=0

if [ "${1:-}" = "--selftest" ]; then
  rc=0
  [ -f "$DIST/index.html" ] && echo "selftest 1/3 PASS (dist istnieje)" || { echo "selftest 1/3 FAIL (brak dist)"; rc=1; }
  grep -q 'assets/index-' "$DIST/index.html" 2>/dev/null && echo "selftest 2/3 PASS (hashed assets w index.html)" || { echo "selftest 2/3 FAIL"; rc=1; }
  n=0; for h in $REPLICAS; do ssh $SSH_OPTS "root@$h" 'true' 2>/dev/null && n=$((n+1)); done
  [ "$n" -ge 1 ] && echo "selftest 3/3 PASS (osiagalnych replik: $n)" || { echo "selftest 3/3 FAIL (0 replik)"; rc=1; }
  exit $rc
fi

if [ ! -f "$DIST/index.html" ]; then
  echo "FAIL C0 brak $DIST/index.html — UI nie zbudowane"
  echo "RESULT: FAIL=1"; exit 1
fi

local_md5="$(md5sum "$DIST/index.html" | cut -d' ' -f1)"
chunk_path="$(ls -1t "$DIST"/assets/NeuralMap-*.js 2>/dev/null | head -1)"
chunk="$(basename "${chunk_path:-}")"
if [ -z "$chunk" ]; then
  echo "FAIL C3 brak chunku NeuralMap-*.js w dist"
  FAILS=$((FAILS+1))
else
  echo "PASS C0 lokalny dist: index=$local_md5 chunk=$chunk"
fi

for h in $REPLICAS; do
  if ! ssh $SSH_OPTS "root@$h" 'true' 2>/dev/null; then
    echo "FAIL C1 $h nieosiagalny po SSH (brak dowodu parity)"
    FAILS=$((FAILS+1)); continue
  fi
  rmd5="$(ssh $SSH_OPTS "root@$h" "md5sum /opt/PROD/products/mesh-observatory/ui/dist/index.html 2>/dev/null | cut -d' ' -f1" 2>/dev/null)"
  if [ "$rmd5" = "$local_md5" ]; then
    echo "PASS C2 $h index.html zgodny"
  else
    echo "FAIL C2 $h: index.html lokalny=$local_md5 zdalny=${rmd5:-BRAK} — replika serwuje INNY build"
    FAILS=$((FAILS+1))
  fi
  if [ -n "$chunk" ]; then
    if ssh $SSH_OPTS "root@$h" "test -f /opt/PROD/products/mesh-observatory/ui/dist/assets/$chunk" 2>/dev/null; then
      echo "PASS C3 $h ma $chunk"
    else
      echo "FAIL C3 $h: brak $chunk — 404 dla czesci zadan w balansie"
      FAILS=$((FAILS+1))
    fi
  fi
done

if [ -n "$chunk" ]; then
  code="$(timeout 20 curl -s -o /dev/null -w '%{http_code}' "https://mesh.aigon.dev/assets/$chunk" 2>/dev/null)"
  if [ "$code" = "200" ]; then
    echo "PASS C4 publiczny /assets/$chunk = 200"
  else
    echo "FAIL C4 publiczny /assets/$chunk = ${code:-brak} (Suweren widzi zepsuty panel)"
    FAILS=$((FAILS+1))
  fi
fi

echo "RESULT: FAIL=$FAILS"
[ "$FAILS" -eq 0 ] && exit 0
exit 1
