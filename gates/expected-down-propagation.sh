#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/expected-down-propagation.sh — GATE LAW-GRAPH-REMOVAL-1
#  „Removal at the top of the graph propagates”
#
#  ROZKAZ SUWERENA 2026-10-18 (dosłownie): „jak coś wypierdalamy u góry grafu,
#  to zależności od wypierdolonego też nie” — usunięty węzeł (np. mail) NIE MOŻE
#  wracać jako AWARIA w warstwach pochodnych.
#
#  POWÓD ISTNIENIA: prawo zadeklarowało bramkę tools/gates/expected-down-propagation.sh,
#  której plik nie istniał — law-gate-closure C2/C7 wskazywał martwy egzekutor.
#
#  CO MIERZY (na ŻYWYM /api/v1/mesh + SSOT):
#    P1  SSOT config/mesh-nodes.yaml parsuje się i ma wpisy `expected_down: true`,
#    P2  dla każdego takiego węzła: ŻADEN alert w /api/v1/mesh nie wskazuje go
#        jako „expected but DOWN”/missing (propagacja usunięcia),
#    P3  żaden wiersz macierzy nie ma status=missing dla usług tego węzła,
#    P4  węzeł nie jest liczony w ha.runtime_nodes_* jako brakujący.
#
#  KONTRAKT: 0 = PASS, 1 = FAIL, 2 = UNKNOWN (brak SSOT/API — nie udajemy zielonego).
#  --selftest: dowód negatywny — wstrzykuje fałszywy alert dla węzła expected_down
#  i bramka MUSI go wykryć.
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_ROOT:-/srv/aigon}"
SSOT="$ROOT/config/mesh-nodes.yaml"
SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1

[ -f "$SSOT" ] || { echo "expected-down-propagation: UNKNOWN — brak $SSOT"; exit 2; }

# ── SSOT: lista węzłów wyłączonych świadomie ─────────────────────────────
EXPDOWN="$(python3 - "$SSOT" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
out = []
nodes = d.get("nodes") or {}
items = nodes.items() if isinstance(nodes, dict) else enumerate(nodes)
for k, v in items:
    if not isinstance(v, dict):
        continue
    name = v.get("name") or (k if isinstance(k, str) else "")
    if v.get("expected_down") is True or v.get("expected_up") is False:
        out.append(str(name))
print("\n".join(sorted(set(out))))
PY
)" || { echo "expected-down-propagation: UNKNOWN — SSOT nieparsowalny"; exit 2; }

if [ -z "$EXPDOWN" ]; then
    echo "expected-down-propagation: UNKNOWN — SSOT nie ma żadnego wpisu expected_down (nie ma czego mierzyć)"
    exit 2
fi

# ── żywy snapshot ────────────────────────────────────────────────────────
MESH=""
if [ "$SELFTEST" = "1" ]; then
    FIRST="$(printf '%s\n' "$EXPDOWN" | head -1)"
    MESH="$(mktemp /tmp/expdown-selftest.XXXXXX.json)"
    python3 - "$MESH" "$FIRST" <<'PY'
import json, sys
p, node = sys.argv[1], sys.argv[2]
json.dump({
    "nodes": [],
    "matrix": [{"node": "N9", "node_name": node, "service": "runtime",
                "status": "missing", "expected": True, "observed": False}],
    "alerts": [{"severity": "critical", "node": "N9", "service": "runtime",
                "summary": "%s:runtime expected but DOWN" % node}],
    "ha": {"runtime_nodes_up": 1, "runtime_nodes_total": 1},
}, open(p, "w"))
PY
else
    ENV_FILE="${AIGON_ENV_FILE:-/srv/aigon/.env}"
    KEY="$(sed -n 's/^RUNTIME_SHARED_SECRET=//p' "$ENV_FILE" 2>/dev/null | head -1 | tr -d '"')"
    [ -n "$KEY" ] || KEY="$(sed -n 's/^AIGON_RUNTIME_SHARED_SECRET=//p' "$ENV_FILE" 2>/dev/null | head -1 | tr -d '"')"
    API="${AIGON_MESH_API:-https://prod.mesh.internal:7000}"
    MESH="$(mktemp /tmp/expdown.XXXXXX.json)"
    timeout 25 curl -sk -H "X-API-Key: ${KEY}" "${API}/api/v1/mesh" > "$MESH" 2>/dev/null || true
    if [ ! -s "$MESH" ]; then
        echo "expected-down-propagation: UNKNOWN — /api/v1/mesh nie odpowiedzial (brak pomiaru != PASS)"
        rm -f "$MESH"; exit 2
    fi
fi

RESULT="$(python3 - "$MESH" <<PY
import json, sys
mesh = json.load(open(sys.argv[1], encoding="utf-8"))
expdown = [l.strip() for l in """$EXPDOWN""".splitlines() if l.strip()]
fails = []
for node in expdown:
    alerts = [a for a in (mesh.get("alerts") or [])
              if node in str(a.get("summary", "")) + str(a.get("node_name", "")) + str(a.get("node", ""))]
    if alerts:
        fails.append("P2 %s: %d alert(y) traktuja usuniety wezel jako awarie" % (node, len(alerts)))
    rows = [r for r in (mesh.get("matrix") or [])
            if str(r.get("node_name")) == node and r.get("status") == "missing"]
    if rows:
        fails.append("P3 %s: %d wiersz(y) macierzy status=missing" % (node, len(rows)))
    miss = [n for n in (mesh.get("nodes") or [])
            if str(n.get("name")) == node and (n.get("expected_missing") or [])]
    if miss:
        fails.append("P4 %s: expected_missing niepuste (węzeł usunięty wrócił jako brak)" % node)
print("\n".join(fails))
PY
)"

if [ "$SELFTEST" = "1" ]; then
    rm -f "$MESH"
    if [ -n "$RESULT" ]; then
        echo "expected-down-propagation selftest: PASS (wstrzyknięty alert/missing dla węzła expected_down wykryty)"
        exit 0
    fi
    echo "expected-down-propagation selftest: FAIL — bramka NIE wykrywa awarii usuniętego węzła (martwy warunek)"
    exit 1
fi

rm -f "$MESH"
if [ -n "$RESULT" ]; then
    echo "expected-down-propagation: FAIL (LAW-GRAPH-REMOVAL-1) — usunięte węzły wracają jako awarie:"
    printf '%s\n' "$RESULT" | sed 's/^/  /'
    exit 1
fi

echo "expected-down-propagation: PASS (LAW-GRAPH-REMOVAL-1) — $(printf '%s' "$EXPDOWN" | tr '\n' ' ')nie raportowane jako awaria"
exit 0
