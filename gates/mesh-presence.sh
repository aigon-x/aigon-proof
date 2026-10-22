#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/mesh-presence.sh — gate mesh-presence (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  Liczba ONLINE nodów w mesh.nodes (/health runtime) vs mesh-nodes.yaml (8).
#  Runtime nie raportujący mesh = WARN (diagnoza, nie blokada).
#
#  POPRAWKA 2026-10-11 (LAW-29): liczono len(nodes) i czytano nieistniejące pole
#  `status` — nod w stanie `state=Unreachable` (zmierzone: poligon 8 dni offline)
#  był liczony jako obecny = falszywy zielony. Teraz liczymy wyłącznie nody nie
#  będące w stanie złym (Unreachable/Dead/offline/down...), z pola `state`
#  (z fallbackiem na `status`).
#  KOREKTA PROGU 2026-10-12 (rozkaz Suwerena „korekta progu"): próg 6→5.
#  Kworum 8 peerów = 5 (8/2+1); próg 6 był nieosiągalny przy 3 nodach offline
#  (site/optiq/poligon, expected_down 2026-10-12). Po powrocie nodów do sieci
#  próg wraca na wyższy (docelowo: expected_down-aware, nie hardcoded).
#
#  Kontrakt: exit 0 = PASS (>=5), exit 1 = FAIL (<5), exit 2 = WARN.
#  Zmienne env: AIGON_RUNTIME_URL, AIGON_MP_MIN (default 5).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

RUNTIME_URL="${AIGON_RUNTIME_URL:-https://127.0.0.1:7000}"
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/gate-params.sh"
MIN="$(gp GATE-077 mesh_presence_min 5)"

ONLINE=$(curl -sk -m 8 "$RUNTIME_URL/health" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    m=d.get('mesh',{})
    nodes=m.get('nodes',[]) if isinstance(m,dict) else []
    # POPRAWKA 2026-10-11 (LAW-29, pomiar nie lagodzenie): poprzednia wersja
    # czytala pole 'status' i liczyła len(nodes) — a runtime /health podaje stan
    # w polu 'state' (Healthy/Unreachable/Dead). Filtr był MARTWY (status zawsze
    # None => 'online'), więc nod ze state=Unreachable był liczony jako obecny
    # (falszywy ZIELONY: zmierzone — poligon 192.0.2.13 Unreachable 8 dni, a
    # brama raportowala 8/8). Teraz liczymy TYLKO nody nie-bedace w stanie zlym;
    # akceptujemy oba pola ('state' i 'status'), brak pola = online (kompatybilnosc
    # wstepna z fixture'ami). Nody Unreachable/Dead NIE zawyzaja obecnosci.
    BAD={'unreachable','dead','offline','down','unhealthy','stale'}
    def online(n):
        if not isinstance(n,dict):
            return False
        s=(n.get('state') or n.get('status') or '').strip().lower()
        return s not in BAD
    print(len([n for n in nodes if online(n)]))
except Exception:
    print('?')" 2>/dev/null)

if [ "$ONLINE" = "?" ]; then
  echo "mesh-presence: WARN (runtime nie raportuje mesh)"
  exit 2
elif [ "${ONLINE:-0}" -ge "$MIN" ]; then
  echo "mesh-presence: PASS ($ONLINE nodów)"
  exit 0
else
  echo "mesh-presence: FAIL ($ONLINE nodów < $MIN)"
  exit 1
fi
