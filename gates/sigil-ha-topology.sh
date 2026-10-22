#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  GATE — sigil-ha-topology (żywy stan natywnej HA produktu SIGIL)
#
#  KLASA DEFEKTU (zmierzona 2026-10-17): topologia HA ISTNIEJE w praktyce,
#  ale NIE JEST NIGDZIE ZADEKLAROWANA — więc gdy monitor zniknął, nikt tego
#  nie zauważył. Skutek: prod krążył w pętli 14 952 restartów (node DB nie
#  mógł dosięgnąć monitora), contabo trzymał standby bez primary, aplikacja
#  SIGIL nie miała dokąd pisać. Bramka domyka to: deklaracja w
#  config/canonical/sigil-ha.yaml MUSI zgadzać się z żywym stanem.
#
#  CO MIERZY (na węzłach z deklaracji, przez ssh):
#   H1 monitor: kontener running + `pg_autoctl show state` daje dokładnie
#      1 primary i (N-1) secondary dla N zadeklarowanych node'ów DB,
#   H2 każdy node DB: kontener running, RestartCount == 0,
#      PG_AUTOCTL_MONITOR wskazuje zadeklarowany monitor (ip:port),
#   H3 zasada topologii: monitor NIE stoi na węźle, który jest node'em DB
#      (awaria takiego węzła zabiera primary i monitor naraz).
#
#  KONTRAKT RC:
#   0 = PASS, 1 = FAIL (z cytatem), 2 = NOT_ESTABLISHED (brak SSOT/pomiaru)
#
#  Użycie:
#    tools/gates/sigil-ha-topology.sh
#    tools/gates/sigil-ha-topology.sh --selftest
#    AIGON_SIGIL_PROBE_FILE=<plik>   — wstrzyknięcie pomiaru (selftest)
#    AIGON_SIGIL_HA_CONFIG=<plik>    — inny SSOT
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="${AIGON_SIGIL_HA_CONFIG:-${ROOT}/config/canonical/sigil-ha.yaml}"
NODES_CONFIG="${AIGON_MESH_NODES_CONFIG:-${ROOT}/config/mesh-nodes.yaml}"
SSH_TIMEOUT="${AIGON_SIGIL_SSH_TIMEOUT:-8}"

die() { echo "NOT_ESTABLISHED: $*" >&2; exit 2; }
[ -f "$CONFIG" ] || die "brak SSOT ${CONFIG}"

# ── Pomiar: jedna linia na węzeł ───────────────────────────────────────────
# Format (do pliku, parsowane przez analyze):
#   MONITOR_IP=<ip>
#   MONITOR_PORT=<port>
#   NODE:<ip>|status=<running|exited|...>|restarts=<n>|monitor_env=<url|brak>
#   STATE:<linia pg_autoctl show state>
collect() {
  if [ -n "${AIGON_SIGIL_PROBE_FILE:-}" ]; then
    [ -f "$AIGON_SIGIL_PROBE_FILE" ] || die "brak AIGON_SIGIL_PROBE_FILE"
    cat "$AIGON_SIGIL_PROBE_FILE"
    return 0
  fi
  local meta
  meta="$(python3 - "$CONFIG" "$NODES_CONFIG" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
nodes = (yaml.safe_load(open(sys.argv[2])) or {}).get('nodes') or {}
alias = {}
for name, nd in nodes.items():
    if isinstance(nd, dict) and nd.get('ip'):
        ssh = nd.get('ssh')
        alias[str(nd['ip'])] = (ssh.get('host') or ssh.get('alias') or name) if isinstance(ssh, dict) else (ssh or name)
m = cfg.get('monitor') or {}
print("MONITOR_IP=%s" % m.get('ip'))
print("MONITOR_PORT=%s" % m.get('port'))
print("MONITOR_NODE=%s" % m.get('node'))
print("MONITOR_CONTAINER=%s" % m.get('container'))
for ip, a in alias.items():
    print("ALIAS=%s|%s" % (ip, a))
for n in (cfg.get('nodes') or []):
    ip = str(n.get('ip'))
    print("DNODE=%s|%s|%s|%s" % (ip, n.get('container'), alias.get(ip, n.get('node')), n.get('node')))
PY
)"
  echo "$meta" | sed -n 's/^MONITOR_IP=/MONITOR_IP=/p; s/^MONITOR_PORT=/MONITOR_PORT=/p; s/^MONITOR_NODE=/MONITOR_NODE=/p; s/^MONITOR_CONTAINER=/MONITOR_CONTAINER=/p; s/^ALIAS=/ALIAS=/p'
  local m_ip m_port m_container
  m_ip="$(echo "$meta" | sed -n 's/^MONITOR_IP=//p')"
  m_port="$(echo "$meta" | sed -n 's/^MONITOR_PORT=//p')"
  m_container="$(echo "$meta" | sed -n 's/^MONITOR_CONTAINER=//p')"
  local m_alias
  m_alias="$(echo "$meta" | sed -n "s/^ALIAS=${m_ip}|\(.*\)/\1/p")"
  [ -z "$m_alias" ] && m_alias="$(echo "$meta" | sed -n "s/^MONITOR_NODE=//p")"

  # monitor: stan kontenera + formacja
  local out
  out="$(timeout "$SSH_TIMEOUT" ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$m_alias" \
        "sudo -n docker inspect $m_container --format 'state={{.State.Status}} restarts={{.RestartCount}}' 2>/dev/null; echo ---; sudo -n docker exec $m_container pg_autoctl show state 2>/dev/null | tail -n +3" 2>/dev/null)"
  echo "MONITOR_STATE_BEGIN"
  echo "$out"
  echo "MONITOR_STATE_END"

  # node'y DB
  echo "$meta" | sed -n 's/^DNODE=//p' | while IFS='|' read -r ip container halias nname; do
    [ -n "$ip" ] || continue
    local r
    r="$(timeout "$SSH_TIMEOUT" ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$halias" \
         "sudo -n docker inspect $container --format 'status={{.State.Status}}|restarts={{.RestartCount}}' 2>/dev/null; sudo -n docker inspect $container --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -m1 '^PG_AUTOCTL_MONITOR='" 2>/dev/null)"
    local st rs env
    st="$(echo "$r" | sed -n 's/.*status=\([^|]*\).*/\1/p')"
    rs="$(echo "$r" | sed -n 's/.*restarts=\([0-9]*\).*/\1/p')"
    env="$(echo "$r" | grep -m1 '^PG_AUTOCTL_MONITOR=' | sed 's/^PG_AUTOCTL_MONITOR=//')"
    echo "NODE:${ip}|status=${st:-BRAK}|restarts=${rs:-BRAK}|monitor_env=${env:-brak}"
  done
}

# ── Analiza ────────────────────────────────────────────────────────────────
analyze() {
  local probe="$1"
  python3 - "$CONFIG" "$probe" <<'PY'
import re, sys, yaml

cfg = yaml.safe_load(open(sys.argv[1])) or {}
lines = open(sys.argv[2]).read().splitlines()
text = "\n".join(lines)

m = cfg.get('monitor') or {}
m_ip, m_port = str(m.get('ip')), str(m.get('port'))
dnodes = cfg.get('nodes') or []
if not m_ip or not dnodes:
    print("NOT_ESTABLISHED: SSOT bez monitor.ip lub bez nodes", file=sys.stderr)
    raise SystemExit(2)

has_probe = any(l.startswith('NODE:') for l in lines)
if not has_probe:
    print("NOT_ESTABLISHED: brak pomiaru node'ow (0 linii NODE:)", file=sys.stderr)
    raise SystemExit(2)

fails, warns = [], []

# H3: monitor nie moze stac na wezle DB
db_ips = {str(n.get('ip')) for n in dnodes}
if m_ip in db_ips:
    fails.append("H3 monitor stoi na wezle DB (%s) — awaria wezla zabiera primary i monitor naraz" % m_ip)

# H1: monitor zyje + formacja ma 1 primary i (N-1) secondary
block = []
if 'MONITOR_STATE_BEGIN' in text:
    block = text.split('MONITOR_STATE_BEGIN', 1)[1].split('MONITOR_STATE_END', 1)[0].splitlines()
estate = next((l for l in lines if l.startswith('MONITOR_ESTATE:')), None)
if estate:
    st = estate.split(':', 1)[1]
elif 'MONITOR_STATE_BEGIN' in text:
    st = "running" if block else "BRAK"
else:
    st = "BRAK"
if st != 'running':
    fails.append("H1 monitor (%s:%s, kontener %s) nie dziala: state=%s" % (m_ip, m_port, m.get('container'), st))
if block:
    rowa = [l for l in block if l.strip() and not set(l.strip()) <= set('-+ ')]
    primary = sum(1 for l in rowa if re.search(r'\|\s*primary\s*\|', l))
    secondary = sum(1 for l in rowa if re.search(r'\|\s*secondary\s*\|', l))
    want_sec = max(0, len(dnodes) - 1)
    if primary != 1:
        fails.append("H1 formacja: primary=%d (oczekiwane 1) — cytat: %s" % (primary, ' / '.join(x.strip()[:60] for x in rowa[:3])))
    if secondary != want_sec:
        fails.append("H1 formacja: secondary=%d (oczekiwane %d)" % (secondary, want_sec))
else:
    fails.append("H1 brak odczytu formacji z monitora (pg_autoctl show state puste/niedostępne)")

# H2: kazdy node DB zyje, bez restartow, wskazuje zadeklarowany monitor
by_ip = {}
for l in lines:
    if l.startswith('NODE:') and '|' in l:
        ip, rest = l[5:].split('|', 1)
        kv = dict(p.split('=', 1) for p in rest.split('|') if '=' in p)
        by_ip[ip] = kv
for n in dnodes:
    ip = str(n.get('ip'))
    kv = by_ip.get(ip)
    if not kv:
        fails.append("H2 node %s (%s): BRAK POMIARU (nieosiągalny)" % (n.get('name'), ip))
        continue
    if kv.get('status') != 'running':
        fails.append("H2 node %s (%s): status=%s" % (n.get('name'), ip, kv.get('status')))
    try:
        rc = int(kv.get('restarts', '-1'))
    except ValueError:
        rc = -1
    if rc != 0:
        fails.append("H2 node %s (%s): RestartCount=%s (restart-loop)" % (n.get('name'), ip, kv.get('restarts')))
    env = kv.get('monitor_env', '')
    if env == 'brak' or not env:
        fails.append("H2 node %s (%s): brak PG_AUTOCTL_MONITOR (node nie zna monitora)" % (n.get('name'), ip))
    elif ('@%s:%s/' % (m_ip, m_port)) not in env:
        fails.append("H2 node %s (%s): monitor_env wskazuje inny adres niż %s:%s" % (n.get('name'), ip, m_ip, m_port))

print("sigil-ha-topology: monitor=%s:%s nodes=%d" % (m_ip, m_port, len(dnodes)))
for w in warns:
    print("WARN " + w)
if fails:
    print("FAIL:")
    for f in fails:
        print("  - " + f)
    raise SystemExit(1)
print("PASS: monitor zyje, formacja 1 primary + %d secondary, node'y czyste, wskaźniki zgodne z SSOT" % max(0, len(dnodes) - 1))
raise SystemExit(0)
PY
}

# ── Selftest ───────────────────────────────────────────────────────────────
selftest() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  cat > "$tmp/cfg.yaml" <<'YAML'
version: 1
monitor: {node: optiq, ip: 100.79.105.36, port: 31433, container: sigil-ha-pg-monitor}
nodes:
  - {name: sigil-contabo, ip: 100.77.55.117, container: sigil-ha-pg}
  - {name: sigil-prod, ip: 100.99.59.100, container: sigil-ha-pg}
YAML
  cat > "$tmp/good.txt" <<'P'
MONITOR_STATE_BEGIN
sigil-contabo | 50 | 100.77.55.117:31432 | 1: 0/3 | read-write | primary | primary
sigil-prod | 51 | 100.99.59.100:31432 | 1: 0/3 | read-only | secondary | secondary
MONITOR_STATE_END
MONITOR_ESTATE:running
NODE:100.77.55.117|status=running|restarts=0|monitor_env=postgres://autoctl_node@100.79.105.36:31433/pg_auto_failover?sslmode=require
NODE:100.99.59.100|status=running|restarts=0|monitor_env=postgres://autoctl_node@100.79.105.36:31433/pg_auto_failover?sslmode=require
P
  cat > "$tmp/bad_restart.txt" <<'P'
MONITOR_STATE_BEGIN
sigil-contabo | 50 | 100.77.55.117:31432 | 1: 0/3 | read-write | primary | primary
sigil-prod | 51 | 100.99.59.100:31432 | 1: 0/3 | read-only | secondary | secondary
MONITOR_STATE_END
MONITOR_ESTATE:running
NODE:100.77.55.117|status=running|restarts=0|monitor_env=postgres://autoctl_node@100.79.105.36:31433/pg_auto_failover?sslmode=require
NODE:100.99.59.100|status=restarting|restarts=8|monitor_env=postgres://autoctl_node@100.98.144.70:31433/pg_auto_failover?sslmode=require
P
  cat > "$tmp/bad_monitor.txt" <<'P'
MONITOR_STATE_BEGIN
MONITOR_STATE_END
MONITOR_ESTATE:exited
NODE:100.77.55.117|status=running|restarts=0|monitor_env=postgres://autoctl_node@100.79.105.36:31433/pg_auto_failover?sslmode=require
NODE:100.99.59.100|status=running|restarts=0|monitor_env=postgres://autoctl_node@100.79.105.36:31433/pg_auto_failover?sslmode=require
P
  cat > "$tmp/monitor_on_dbnode.yaml" <<'YAML'
version: 1
monitor: {node: contabo, ip: 100.77.55.117, port: 31433, container: sigil-ha-pg-monitor}
nodes:
  - {name: sigil-contabo, ip: 100.77.55.117, container: sigil-ha-pg}
  - {name: sigil-prod, ip: 100.99.59.100, container: sigil-ha-pg}
YAML

  run() { AIGON_SIGIL_HA_CONFIG="$1" AIGON_SIGIL_PROBE_FILE="$2" bash "$0" 2>&1; }

  out="$(run "$tmp/cfg.yaml" "$tmp/good.txt")"; rc_ok=$?
  if [ "$rc_ok" -eq 0 ] && echo "$out" | grep -q '^PASS'; then
    echo "selftest 1/4 PASS: zdrowa formacja -> PASS(0)"
  else
    echo "selftest 1/4 FAIL: oczekiwano rc=0 + PASS, jest rc=$rc_ok"; echo "$out" | sed 's/^/    /'; rc=1
  fi

  out="$(run "$tmp/cfg.yaml" "$tmp/bad_restart.txt")"; rc_bad=$?
  if [ "$rc_bad" -eq 1 ] && echo "$out" | grep -q 'restart-loop' && echo "$out" | grep -q 'inny adres'; then
    echo "selftest 2/4 PASS: restart-loop + zły monitor -> FAIL(1)"
  else
    echo "selftest 2/4 FAIL: oczekiwano rc=1 + restart-loop + inny adres, jest rc=$rc_bad"; echo "$out" | sed 's/^/    /'; rc=1
  fi

  out="$(run "$tmp/cfg.yaml" "$tmp/bad_monitor.txt")"; rc_mon=$?
  if [ "$rc_mon" -eq 1 ] && echo "$out" | grep -q 'H1 monitor'; then
    echo "selftest 3/4 PASS: martwy monitor -> FAIL(1)"
  else
    echo "selftest 3/4 FAIL: oczekiwano rc=1 + H1, jest rc=$rc_mon"; echo "$out" | sed 's/^/    /'; rc=1
  fi

  out="$(run "$tmp/monitor_on_dbnode.yaml" "$tmp/good.txt")"; rc_h3=$?
  if [ "$rc_h3" -eq 1 ] && echo "$out" | grep -q 'H3 monitor stoi na wezle DB'; then
    echo "selftest 4/4 PASS: monitor na wezle DB -> FAIL(1)"
  else
    echo "selftest 4/4 FAIL: oczekiwano rc=1 + H3, jest rc=$rc_h3"; echo "$out" | sed 's/^/    /'; rc=1
  fi

  rm -rf "$tmp"
  return "$rc"
}

case "${1:-}" in
  --selftest) selftest ;;
  --help|-h) sed -n '1,40p' "$0" ;;
  '') pf="$(mktemp)"; collect > "$pf" || { rm -f "$pf"; exit 2; }; analyze "$pf"; rc=$?; rm -f "$pf"; exit "$rc" ;;
  *) echo "nieznany argument: $1" >&2; exit 2 ;;
esac
