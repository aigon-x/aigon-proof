#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/ha-failover.sh — BRAMKA HA: FAILOVER + REPLIKACJA
#
#  ROZKAZ Suwerena (2026-09-30): „a to nie miało być HA? frameworkiem? z
#  automatycznym przepinaniem cloudflare itd i replikacją na inne nodey?
#  zapisz to jako kanon, jak ma wyglądać prawdziwe HA, dla jakich usług,
#  i musimy od tego zrobić gate'a… ma też być przetestowany w gejcie failover
#  i replikacja na 3,4,5 węzeł" oraz „dlaczego tego nie ma w pipeline".
#
#  PROBLEM: kanon HA istniał (config/canonical/ha-topology.yaml, LAW-HA-1), ale
#  NIE BYŁ NIGDZIE EGZEKWOWANY — żadna bramka nie sprawdzała, czy repliki żyją
#  ani czy failover NAPRAWDĘ przełącza. Kanon bez egzekucji = intencja bez
#  realizacji (klasa ux-watchdog). Dlatego awaria LB na 3 węzłach była cicha.
#
#  CO SPRAWDZA (trzy niezależne warunki, każdy z dowodem):
#    A. REPLIKACJA   — usługa ma >= MIN_REPLICAS żywych backendów per kanon.
#    B. FAILOVER     — przy ZATRZYMANYM lokalnym backendzie kanał agenta
#                      (adres, który agent zna) DALEJ odpowiada 200.
#    C. PRZYWRÓCENIE — backend wraca po teście (trap EXIT gwarantuje restore
#                      nawet przy błędzie; brak restore = FAIL, nie WARN).
#
#  BEZPIECZEŃSTWO TESTU FAILOVERU:
#    Domyślnie audyt jest tylko odczytem (WARN bez dowodu aktywnego testu).
#    AIGON_HA_EXECUTE_FAILOVER=1 uruchamia świadomy test w oknie konserwacji.
#    Test zatrzymuje backend WYŁĄCZNIE na węźle lokalnym (DEV) i tylko ten,
#    który ma co najmniej jeden żywy peer w kanonie. Na PROD test jest
#    POMIJANY (wynik SKIP z powodem) — nie zatrzymujemy produkcji w bramce.
#
#  KONTRAKT: 0=PASS, 1=FAIL, 2=WARN (jak pozostałe bramki repo).
#  SSOT: config/canonical/ha-topology.yaml — zero list w tym skrypcie.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_PROJECT_ROOT:-/opt/PROD}"
SSOT="${AIGON_HA_SSOT:-$ROOT/config/canonical/ha-topology.yaml}"
MIN_REPLICAS="${AIGON_HA_MIN_REPLICAS:-2}"
# Węzeł, na którym WOLNO zatrzymać backend w teście failoveru (DEV).
TEST_NODE="${AIGON_HA_TEST_NODE:-local-aigon}"
SELF_HOST="$(hostname)"
ALLOW_FAILOVER="${AIGON_HA_EXECUTE_FAILOVER:-0}"
[ "$SELF_HOST" != "$TEST_NODE" ] && ALLOW_FAILOVER=0

fail() { echo "ha-failover: FAIL $*"; exit 1; }
warn() { echo "ha-failover: WARN $*"; exit 2; }

# ── KRYTERIUM „KANAŁ ŻYJE" (KOREKTA 2026-09-30, zmierzona) ────────────────
# PIERWSZA wersja wymagała HTTP **200**. Pomiar pokazał, że `/mcp` zwraca raz
# 401 (wymaga auth/nagłówków), raz 200 — więc bramka ogłaszała FAIL na ZDROWEJ
# usłudze i „backend NIE wrocil" na działającym kontenerze. To dokładnie klasa
# „bramka mierzy nie tę rzecz": 401/403 dowodzi, że LB + backend ODPOWIADAJĄ
# (usługa żyje, tylko wymaga logowania); martwe są 000 (brak połączenia)
# i 5xx (błąd serwera). Kontrakt: ŻYJE = kod spoza {000,5xx}.
channel_alive() { # <url> → 0 gdy kanał odpowiada
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$1" 2>/dev/null || echo 000)"
  case "$code" in
    [234][0-9][0-9]) echo "  (kanał $1: HTTP $code = ZYJE)"; return 0 ;;
    *) echo "  (kanał $1: HTTP $code = MARTWY)"; return 1 ;;
  esac
}

[ -r "$SSOT" ] || fail "brak SSOT $SSOT — kanon HA nie istnieje"

# ── odczyt kanonu (bez zgadywania list w skrypcie) ────────────────────────
read_ssot() {
  python3 - "$SSOT" <<'PY'
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
out = {"services": {}}
for name, s in (d.get("services") or {}).items():
    if not isinstance(s, dict):
        continue
    be = s.get("backends") or []
    out["services"][name] = {
        "adres": s.get("adres_agenta") or s.get("adres") or "",
        "ha": s.get("ha") or "",
        "status": s.get("status") or "",
        "backends": [{"node": b.get("node"), "url": b.get("url")} for b in be if isinstance(b, dict)],
    }
print(json.dumps(out, ensure_ascii=False))
PY
}

JSON="$(read_ssot)" || fail "nie moge odczytac SSOT"
[ -n "$JSON" ] || fail "SSOT pusty"

# ── A. REPLIKACJA: ile backendów zyje per usluga ──────────────────────────
echo "== A. REPLIKACJA (min $MIN_REPLICAS zywych backendow) =="
FAILS=""
# Budżet pomiaru replikacji: 7 backendów × probe + narzut musi zmieścić się
# w limicie fitness (60s). Domyślnie probe 4s, budżet 35s (env). Przekroczenie
# budżetu = BRAK POMIARU (WARN), nie FAIL (środowisko, nie złamanie prawa).
# Wcześniej: probe 6s × 7 backendów = 42s BEZ górnego ograniczenia budżetu.
PROBE_T="${AIGON_HA_PROBE_TIMEOUT_S:-4}"
REPL_BUDGET="${AIGON_HA_REPL_BUDGET_S:-35}"
REPLICATION="$(timeout "$REPL_BUDGET" python3 - "$JSON" "$MIN_REPLICAS" "$PROBE_T" <<'PY'
import json, sys, urllib.request, ssl
d = json.loads(sys.argv[1]); mn = int(sys.argv[2]); pto = float(sys.argv[3])
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
bad = []
for name, s in d["services"].items():
    be = s["backends"]
    if not be:
        print(f"  {name:<14} BEZ LISTY BACKENDOW w SSOT (ha: {s['ha'][:28]})")
        continue
    up = 0; det = []
    for b in be:
        try:
            with urllib.request.urlopen(b["url"], timeout=pto, context=ctx) as r:
                ok = 200 <= r.status < 300
        except Exception:
            ok = False
        up += 1 if ok else 0
        det.append(f"{b['node']}={'up' if ok else 'DOWN'}")
    flag = "OK " if up >= mn else "FAIL"
    print(f"  {name:<14} {flag} zywych={up}/{len(be)}  {' '.join(det)}")
    if up < mn and s["ha"] and "NA" not in s["ha"].upper():
        bad.append(name)
print("BAD=" + ",".join(bad))
PY
)"; REPL_RC=$?
if [ "$REPL_RC" = "124" ]; then
  echo "  UWAGA — pomiar replikacji przekroczyl budzet ${REPL_BUDGET}s (brak pomiaru, nie FAIL)"
  FAILS="${FAILS}replikacja-niemierzona(budzet); "
  REPLICATION=""
fi
[ "$REPL_RC" = "0" ] || [ "$REPL_RC" = "124" ] || fail "pomiar replikacji nie powiodl sie (rc=$REPL_RC)"
if [ -n "$REPLICATION" ]; then
  printf '%s\n' "$REPLICATION" | grep -v '^BAD='
  printf '%s\n' "$REPLICATION" | grep -q '^BAD=' || fail "pomiar replikacji bez werdyktu"
  BAD="$(printf '%s\n' "$REPLICATION" | grep '^BAD=' | cut -d= -f2-)"
  [ -n "$BAD" ] && FAILS="${FAILS}replikacja<${MIN_REPLICAS}: ${BAD}; "
fi

# ── B+C. FAILOVER: zatrzymaj lokalny backend, kanal agenta ma dzialac ─────
echo
echo "== B. FAILOVER (kanal agenta zyje przy zatrzymanym lokalnym backendzie) =="
if [ -n "${AIGON_HA_DRILL_EVIDENCE:-}" ]; then
  # Validate an explicit scoped completed drill without repeating service stops.
  # Missing, skipped, stale, or partial evidence never proves execution.
  DRILL_OUT=$(python3 - "$AIGON_HA_DRILL_EVIDENCE" "$JSON" "${AIGON_HA_DRILL_TTL:-86400}" <<'PY'
import json, sys, time
def require(condition):
    if not condition:
        raise ValueError('invalid drill observation')
try:
    e = json.load(open(sys.argv[1], encoding='utf-8'))
    topology = json.loads(sys.argv[2])['services']
    ttl = float(sys.argv[3])
    require(ttl > 0)
    require(e.get('schema_version') == 1)
    require(e.get('status') == 'executed')
    require(e.get('duration_ns', 0) > 0)
    require(e.get('evidence_id'))
    age = time.time() - float(e['timestamp'])
    require(0 <= age <= ttl)
    service = e['service']
    require(service in topology)
    s = topology[service]
    require(e.get('channel_url') == s['adres'])
    require(e.get('backend_url') in {b['url'] for b in s['backends']})
    backend_node = next(b['node'] for b in s['backends'] if b['url'] == e['backend_url'])
    peer_nodes = {b['node'] for b in s['backends'] if b['url'] != e['backend_url']}
    observations = e.get('observations') or []
    require([o.get('phase') for o in observations] == ['before', 'stopped', 'restored'])
    for o in observations:
        require(isinstance(o.get('channel_http'), int) and 200 <= o['channel_http'] < 500)
    require(200 <= observations[0]['backend_http'] < 300)
    require(observations[0].get('served_by') == backend_node)
    require(observations[1]['backend_http'] == 0)
    require(observations[1].get('served_by') != observations[0].get('served_by'))
    require(observations[1].get('served_by') in peer_nodes)
    require(200 <= observations[2]['backend_http'] < 300)
    require(observations[2].get('served_by') == backend_node)
    print('recorded failover drill: PASS (stopped backend, peer served channel, backend restored)')
except Exception as exc:
    print('recorded failover drill: FAIL (' + type(exc).__name__ + ')')
    sys.exit(1)
PY
  ) || fail "$DRILL_OUT"
  echo "$DRILL_OUT"
  ALLOW_FAILOVER=1
elif [ "$ALLOW_FAILOVER" != "1" ]; then
  echo "  SKIP — aktywny test wymaga AIGON_HA_EXECUTE_FAILOVER=1 na $TEST_NODE."
  echo "         Automatyczny audyt nie zatrzymuje kanalu uzytkownika."
else
  [ -z "$FAILS" ] || fail "$FAILS — brak warunkow do zatrzymania backendu"
  exec 8</run/lock/aigon-stack-mutate.lock || fail "brak wspolnego mutexa"
  flock -n 8 || warn "mutacja stosu trwa; aktywny test odroczony"
  # Bierzemy usluge mcp_gate (kanal MCP agenta) — ma backends i adres agenta.
  read -r GATE_ADDR GATE_BACKEND_URL GATE_BACKEND_NODE <<<"$(python3 - "$JSON" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
s = (d["services"].get("mcp_gate") or {})
be = s.get("backends") or []
local = [b for b in be if b.get("url") and "100.98.144.70" in b["url"]]
if local:
    print(s.get("adres",""), local[0]["url"], local[0]["node"])
else:
    print("", "", "")
PY
)"
  if [ -z "${GATE_BACKEND_URL:-}" ]; then
    echo "  WARN — brak lokalnego backendu mcp_gate w SSOT (nie mam czego zatrzymac)"
    FAILS="${FAILS}failover-nieprzetestowany (brak lokalnego backendu w SSOT); "
  else
    # Kanal agenta PRZED — kryterium „zyje", nie „==200" (patrz channel_alive)
    GATE_URL="${GATE_ADDR%/mcp}"
    echo "  sprawdzam kanal agenta: $GATE_ADDR"
    if channel_alive "$GATE_URL"; then
      :
    else
      fail "kanal agenta MARTWY przed testem — backend pozostaje uruchomiony"
    fi

    # Zatrzymujemy backend; trap gwarantuje restore nawet przy bledzie
    RESTORED=0
    CNAME="$(sudo docker ps --format '{{.Names}}' | grep -E 'code-server' | head -1)"
    restore() {
      [ "$RESTORED" = "1" ] && return 0
      if [ -n "${CNAME:-}" ]; then
        timeout 30 sudo docker start "$CNAME" >/dev/null 2>&1 || return 1
        sleep 10
        timeout 15 sudo docker exec "$CNAME" true >/dev/null 2>&1 || return 1
      fi
      RESTORED=1
    }
    trap 'restore' EXIT INT TERM
    if [ -z "${CNAME:-}" ]; then
      echo "  WARN — brak kontenera *code-server* lokalnie; pomijam test"
      FAILS="${FAILS}failover-nieprzetestowany (brak kontenera backendu); "
    else
      echo "  zatrzymuje backend '$CNAME' (to DEV; restore przez trap)"
      timeout 30 sudo docker stop "$CNAME" >/dev/null 2>&1 || fail "zatrzymanie backendu nie powiodlo sie"
      sleep 6
      echo "  kanal agenta przy ZATRZYMANYM lokalnym backendzie:"
      if channel_alive "$GATE_URL"; then
        echo "  FAILOVER: PASS — LB przelaczyl na peera"
      else
        echo "  FAILOVER: FAIL — LB nie przelaczyl, kanal padl razem z backendem"
        FAILS="${FAILS}failover nie zadzialal (kanal martwy przy zatrzymanym lokalnym backendzie); "
      fi
      restore || fail "backend nie wrocil po tescie"
      echo "  po przywroceniu:"
      if channel_alive "$GATE_URL"; then
        :
      else
        FAILS="${FAILS}kanal nie wrocil po tescie; "
      fi
    fi
  fi
fi

# ── werdykt ──────────────────────────────────────────────────────────────
echo
if [ -n "$FAILS" ]; then
  fail "$FAILS"
fi
[ "$ALLOW_FAILOVER" = 1 ] || warn "replikacja zmierzona; aktywny failover NIE przetestowany"
echo "ha-failover: PASS (replikacja >=${MIN_REPLICAS} OK; failover przetestowany)"
exit 0
