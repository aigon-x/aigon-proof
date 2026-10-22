#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/verify/gates/domains/map-graph-artifact.sh
#  GATE: artefakt mapy połączeń (panel mesh.aigon.dev/map)
#
#  DLACZEGO POWSTAŁA (zmierzone 2026-10-19, zgłoszenie Suwerena):
#    Panel „Mapa połączeń" dostał HTTP 503 „Nie udało się pobrać grafu".
#    Handler /api/v1/map/graph zwraca 503 `graph_unavailable`, gdy brak pliku
#    <AMO_DATA_DIR>/map/graph.json. Plik istniał TYLKO na prod-aigon, bo powstał
#    z ręcznej konwersji artefaktu; na contabo-aigon (druga replika w upstreamie
#    nginx `amo_backend`) nie było go wcale.
#
#  CZEGO NIE ZŁAPAŁY ISTNIEJĄCE BRAMKI (pomiar, nie opinia):
#    * health-truth-guard mierzy RUNTIME (/api/v1/health, /api/v1/mesh), a nie
#      panel; /api/health panelu zwracał 200 na OBU replikach mimo 503 na grafie
#      → klasyczny false-green (miernik sprawdzał proces, nie funkcję);
#    * grep po tools/verify + tools/gates: ZERO wystąpień `map/graph`
#      i `graph.json` — artefakt nie miał żadnej bramki;
#    * nic nie porównywało replik w upstreamie, więc awaria backupu była
#      niewidoczna do pierwszego żądania trafiającego w balans.
#
#  CO MIERZY (na węźle, na którym działa):
#    C1 plik artefaktu istnieje w kontenerze (przez docker exec — volume jest
#       root-only, `test -f` jako nie-root kłamie „brak");
#    C2 JSON parsuje się i ma nodes > 0;
#    C3 wiek artefaktu <= limit (AMO_MAP_MAX_AGE, domyślnie 24 h);
#    C4 odświeżanie jest ZADEKLAROWANE w config/cron.yaml (bez tego artefakt
#       zamarznie i bramka będzie zielona na trupie — dokładnie ten defekt).
#
#  Kontrakt runnera: 0 = PASS, 1 = FAIL, 2 = WARN/UNKNOWN.
#  --selftest: dowód negatywny (uszkodzony JSON, pusty graf, brak pliku).
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_ROOT:-/opt/PROD}"
CONTAINER="${AMO_CONTAINER:-aigon-mesh-observatory}"
MAX_AGE="${AMO_MAP_MAX_AGE:-86400}"
ART="/var/lib/mesh-observatory/map/graph.json"
FAILS=0
WARNS=0

fail() { echo "FAIL $*"; FAILS=$((FAILS+1)); }
warn() { echo "WARN $*"; WARNS=$((WARNS+1)); }
pass() { echo "PASS $*"; }

probe_artifact() { # <container> <ścieżka>  -> "mtime size nodes"
  docker exec -u 0 "$1" python3 -c "
import json,os,sys
p=sys.argv[1]
try: st=os.stat(p)
except OSError as e:
    print('MISSING',e); sys.exit(3)
try: n=len(json.load(open(p)).get('nodes') or [])
except Exception as e:
    print('CORRUPT',type(e).__name__); sys.exit(4)
print(int(st.st_mtime), st.st_size, n)
" "$2" 2>/dev/null
}

# ── selftest: dowód negatywny na kopiach (nie dotyka produkcji) ────────────
if [ "${1:-}" = "--selftest" ]; then
  rc=0
  td="$(mktemp -d)"
  printf '{"nodes":[{"id":"a"}]}' > "$td/ok.json"
  printf '{"nodes":['            > "$td/corrupt.json"
  printf '{"nodes":[]}'          > "$td/empty.json"

  chk() { # <plik> <oczekiwany: HEALTHY|REJECT>
    python3 - "$1" <<'PY' >/dev/null 2>&1
import json,sys
try:
    n=len(json.load(open(sys.argv[1])).get('nodes') or [])
except Exception:
    sys.exit(1)
sys.exit(0 if n>0 else 1)
PY
  }
  if chk "$td/ok.json";      then echo "selftest 1/4 PASS (zdrowy artefakt akceptowany)"; else echo "selftest 1/4 FAIL"; rc=1; fi
  if chk "$td/corrupt.json"; then echo "selftest 2/4 FAIL (uszkodzony JSON przepuszczony)"; rc=1; else echo "selftest 2/4 PASS (uszkodzony JSON odrzucony)"; fi
  if chk "$td/empty.json";   then echo "selftest 3/4 FAIL (pusty graf przepuszczony)"; rc=1; else echo "selftest 3/4 PASS (pusty graf odrzucony)"; fi
  # C4: deklaracja odświeżania musi istnieć, inaczej bramka świeci na trupie
  if grep -q 'map-graph-refresh' "$ROOT/config/cron.yaml" 2>/dev/null; then
    echo "selftest 4/4 PASS (odswiezanie zadeklarowane w cron.yaml)"
  else
    echo "selftest 4/4 FAIL (brak map-graph-refresh w cron.yaml — artefakt zamarznie)"; rc=1
  fi
  rm -rf "$td"; exit $rc
fi

# ── C1/C2/C3: artefakt w kontenerze ───────────────────────────────────────
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  warn "kontener $CONTAINER nie istnieje na tym wezle — brak panelu do zmierzenia (UNKNOWN)"
  echo "RESULT: WARN ($WARNS)"; exit 2
fi

out="$(probe_artifact "$CONTAINER" "$ART")"
case "$out" in
  MISSING*)
    fail "C1 brak $ART w $CONTAINER — /api/v1/map/graph zwroci 503 (panel: 'Nie udało się pobrać grafu')"
    ;;
  CORRUPT*)
    fail "C2 artefakt nieparsowalny ($out) — panel zwroci 500 graph_corrupt"
    ;;
  "")
    fail "C1 pomiar niezweryfikowany: docker exec nie zwrocil danych (brak dowodu != zdrowy)"
    ;;
  *)
    read -r mtime size nodes <<< "$out"
    pass "C1 artefakt istnieje (${size}B)"
    if [ "${nodes:-0}" -gt 0 ]; then
      pass "C2 JSON poprawny, wezlow=$nodes"
    else
      fail "C2 graf pusty (nodes=0)"
    fi
    age=$(( $(date +%s) - mtime ))
    if [ "$age" -le "$MAX_AGE" ]; then
      pass "C3 wiek artefaktu ${age}s <= ${MAX_AGE}s"
    else
      fail "C3 artefakt nieświeży (${age}s > ${MAX_AGE}s) — odswiezanie nie dziala"
    fi
    ;;
esac

# ── C4: odświeżanie zadeklarowane w SSOT (inaczej zamarznie) ──────────────
if grep -q 'map-graph-refresh' "$ROOT/config/cron.yaml" 2>/dev/null; then
  pass "C4 odswiezanie zadeklarowane w config/cron.yaml"
else
  fail "C4 brak 'map-graph-refresh' w cron.yaml — artefakt nie bedzie odswiezany"
fi

# ── C5: PARITY replik z upstreamu nginx (amo_backend) ─────────────────────
# ZMIERZONE 2026-10-19: bramka mierzyla TYLKO lokalny wezel, a nginx balansuje
# prod-aigon (master) + contabo-aigon. Master nie mial graph.json -> 503 dla
# czesci zadan, mimo ze lokalnie bramka swiecila na zielono. Brak parity to
# ten sam defekt co przy UI: artefakt istnieje, ale nie na kazdej replice.
REPLICAS="${AIGON_MAP_REPLICAS:-prod-aigon contabo-aigon}"
KEY="${AIGON_SSH_KEY:-/home/sniegul/.ssh/id_aigon_local}"
SSH_OPTS="-o ConnectTimeout=8 -o IdentitiesOnly=yes -i $KEY -o StrictHostKeyChecking=accept-new"
for h in $REPLICAS; do
  if ! ssh $SSH_OPTS "root@$h" 'true' 2>/dev/null; then
    warn "C5 $h nieosiagalny po SSH — parity niezmierzona (UNKNOWN, nie PASS)"
    continue
  fi
  rout="$(ssh $SSH_OPTS "root@$h" "docker exec -u 0 aigon-mesh-observatory python3 -c \"
import json,os
p='/var/lib/mesh-observatory/map/graph.json'
try: print(len(json.load(open(p)).get('nodes') or []))
except Exception: print('-')
\"" 2>/dev/null | tail -1)"
  if [ -n "$rout" ] && [ "$rout" != "-" ] && [ "${rout:-0}" -gt 0 ]; then
    pass "C5 $h artefakt obecny (wezlow=$rout)"
  else
    fail "C5 $h BRAK/niepoprawny graph.json — /api/v1/map/graph zwroci 503 na tej replice"
  fi
done

echo "RESULT: FAIL=$FAILS WARN=$WARNS"
[ "$FAILS" -eq 0 ] && exit 0
exit 1
