#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  GATE-235 — secrets-distribution-coverage
#
#  KLASA DEFEKTU (zmierzona 2026-10-17): sekret zmapowany w config/secrets.yaml
#  nie dociera do węzła, który go REALNIE czyta. Trzy warianty tej samej klasy:
#   (R1) POMINIĘTY KONSUMENT — węzeł czyta wartość (bind-mount działającego
#        kontenera albo zmienna w jego Config.Env), ale nie ma go w `nodes:` →
#        sync go nie dotyka, wartość starzeje się po cichu, a
#        `sync-secrets --check` raportuje spokój (sprawdza tylko listę).
#        ZMIERZONE: AGENT_MCP_TOKEN wygasł 2026-10-16 na local-aigon
#        (sha 886ce9e7, exp 2026-10-16) i na poligon/dev-aigon, gdy Vault
#        trzymał świeży (exp 2027-04-18).
#   (R2) NAZWA ZAMIAST IP — `nodes: [prod, contabo]`. sync-secrets iteruje po
#        IP z mesh-nodes.yaml, więc nazwa NIGDY nie dopasuje → wpis jest
#        cichym no-opem. ZMIERZONE: aigon-x/cloudflare/tunnel → core/.env.
#
#  CO MIERZY (żywy stan, nie deklaracja):
#   - konsumenci: dla KAŻDEGO węzła z config/mesh-nodes.yaml (poza
#     expected_down) — źródła bind-mountów DZIAŁAJĄCYCH kontenerów oraz nazwy
#     zmiennych z ich Config.Env (lokalnie docker; zdalnie ssh, równolegle),
#   - lista nodów: dopasowanie po IP.
#  Węzeł nieosiągalny = NIEZMIERZONY (INFO), nie PASS i nie FAIL.
#  env_file usługi, która na danym węźle NIE działa, NIE jest konsumentem —
#  inaczej bramka zgłasza fałszywe trafienia na poprawnym stanie (companion.env
#  jest celem PROD/Contabo, lokalnie nie ma konsumenta).
#
#  KONTRAKT RC:
#   0 = PASS (FAIL R1 lokalny i R2 nie wystapily; WARN R1-remote nie blokuje),
#   1 = FAIL (R1 LOKALNY albo R2),
#   2 = NOT_ESTABLISHED (brak SSOT albo 0 pomiarów — nigdy PASS z niewiedzy)
#
#  Użycie:
#    tools/gates/secrets-distribution-coverage.sh
#    tools/gates/secrets-distribution-coverage.sh --selftest
#    AIGON_CONSUMERS_FILE=<plik>   — wstrzyknięcie pomiaru (selftest),
#    AIGON_GATE_LOCAL_ONLY=1       — tylko węzeł lokalny (szybki tryb offline)
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# KORZEŃ ANALIZY (ścieżki `targets:` rozwiązują się względem niego). Osobny od
# ROOT, żeby selftest mógł podstawić fixture w katalogu tymczasowym.
SECRETS_ROOT="${AIGON_SECRETS_ROOT:-$ROOT}"
SECRETS_CONFIG="${AIGON_SECRETS_CONFIG:-${ROOT}/config/secrets.yaml}"
NODES_CONFIG="${AIGON_MESH_NODES_CONFIG:-${ROOT}/config/mesh-nodes.yaml}"
SSH_TIMEOUT="${AIGON_GATE_SSH_TIMEOUT:-6}"

die_not_established() { echo "NOT_ESTABLISHED: $*" >&2; exit 2; }

[ -f "$SECRETS_CONFIG" ] || die_not_established "brak SSOT ${SECRETS_CONFIG}"
[ -f "$NODES_CONFIG" ]   || die_not_established "brak SSOT ${NODES_CONFIG}"

# Skrypt mierzący konsumentów NA WĘŹLE (lokalnie i zdalnie). Drukuje
# "MOUNT:<ścieżka>" i "ENV:<NAZWA>". Próbuje docker, potem sudo -n docker.
read -r -d '' PROBE_PY <<'PY'
import os, subprocess, sys
PATHS = __AIGON_PATHS__
def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=25)
def dump(cmd):
    out = run(cmd + ["--format", "{{range .Mounts}}{{if eq .Type \"bind\"}}MOUNT:{{.Source}}{{\"\\n\"}}{{end}}{{end}}"
                                     "{{range .Config.Env}}{{println .}}{{end}}"])
    return out.stdout if out.returncode == 0 else ""
ids = run(["docker", "ps", "-q"]).stdout.split()
if ids:
    txt = dump(["docker", "inspect"] + ids)
    if not txt:
        txt = dump(["sudo", "-n", "docker", "inspect"] + ids)
else:
    out = run(["sudo", "-n", "docker", "ps", "-q"])
    ids = out.stdout.split()
    txt = dump(["sudo", "-n", "docker", "inspect"] + ids) if ids else ""
for line in txt.splitlines():
    if line.startswith("MOUNT:"):
        print(line)
    elif "=" in line:
        name = line.split("=", 1)[0]
        if name and name.replace("_", "").isalnum():
            print("ENV:" + name)
for p in PATHS:
    if os.path.exists(p):
        print("EXISTS:" + p)
PY

node_table() { # "ip|ssh_alias" per node (bez expected_down i bez lokalnego)
  python3 - "$NODES_CONFIG" <<'PY'
import os, sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
nodes = doc.get("nodes") or {}
local_ip = None
for name, nd in nodes.items():
    if isinstance(nd, dict) and (name == "local" or nd.get("local") is True):
        local_ip = str(nd.get("ip") or "")
for name, nd in nodes.items():
    if not isinstance(nd, dict):
        continue
    ip = str(nd.get("ip") or "")
    if not ip or ip == local_ip or nd.get("expected_down") is True:
        continue
    ssh = nd.get("ssh")
    alias = (ssh.get("host") or ssh.get("alias") or name) if isinstance(ssh, dict) else (ssh or name)
    print("%s|%s" % (ip, alias))
print("LOCAL|%s" % (local_ip or ""))
PY
}

# ── Pomiar konsumentów per węzeł: linie "NODE:<ip>|MOUNT:…" / "NODE:<ip>|ENV:…"
collect_consumers() {
  if [ -n "${AIGON_CONSUMERS_FILE:-}" ]; then
    [ -f "$AIGON_CONSUMERS_FILE" ] || die_not_established "brak AIGON_CONSUMERS_FILE=${AIGON_CONSUMERS_FILE}"
    cat "$AIGON_CONSUMERS_FILE"
    return 0
  fi
  local tmpd; tmpd="$(mktemp -d)"
  local table; table="$(node_table)"
  local local_ip; local_ip="$(echo "$table" | sed -n 's/^LOCAL|//p')"
  [ -n "$local_ip" ] || { rm -rf "$tmpd"; die_not_established "mesh-nodes.yaml bez wezla local z ip"; }

  # ścieżki-człony wszystkich wpisów (do weryfikacji „plik istnieje na węźle")
  local paths_json probe_src
  paths_json="$(python3 - "$SECRETS_CONFIG" "$SECRETS_ROOT" <<'PY2'
import json, os, sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
root = sys.argv[2]
out = []
for e in (doc.get('secrets') or doc.get('entries') or []):
    if not isinstance(e, dict):
        continue
    for t in (e.get('targets') or []):
        if isinstance(t, str):
            ap = os.path.normpath(t if os.path.isabs(t) else os.path.join(root, t))
            if ap not in out:
                out.append(ap)
print(json.dumps(out))
PY2
)"
  probe_src="${PROBE_PY/__AIGON_PATHS__/$paths_json}"

  # 1) lokalnie: docker (fallback sudo -n)
  printf '%s' "$probe_src" | python3 - > "$tmpd/local.txt" 2>/dev/null \
    || { rm -rf "$tmpd"; die_not_established "pomiar lokalny nie powiodl sie"; }
  sed "s|^|NODE:${local_ip}\||" "$tmpd/local.txt"

  # 2) zdalnie, równolegle (każdy węzeł → jeden ssh, twardy timeout)
  if [ "${AIGON_GATE_LOCAL_ONLY:-0}" != "1" ]; then
    local ips=() aliases=()
    while read -r rip ralias; do
      [ -n "$rip" ] || continue
      ips+=("$rip"); aliases+=("$ralias")
    done < <(echo "$table" | sed -n 's/^\(.*\)|\(.*\)$/\1 \2/p' | grep -v '^LOCAL ')
    local k
    for k in "${!ips[@]}"; do
      ( printf '%s' "$probe_src" | timeout "$SSH_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout=4 \
          -o StrictHostKeyChecking=accept-new "${aliases[$k]}" 'python3 -' 2>/dev/null > "$tmpd/${ips[$k]}.txt" ) &
    done
    wait
    for f in "$tmpd"/*.txt; do
      [ "$(basename "$f")" = "local.txt" ] && continue
      local ip; ip="$(basename "$f" .txt)"
      if [ -s "$f" ]; then
        sed "s|^|NODE:${ip}\||" "$f"
      else
        echo "UNMEASURED:${ip}" >&2
      fi
    done
  fi
  rm -rf "$tmpd"
}

# ── Analiza pokrycia ───────────────────────────────────────────────────────
analyze() {
  local consumers_file="$1"
  python3 - "$SECRETS_CONFIG" "$NODES_CONFIG" "$SECRETS_ROOT" "$consumers_file" <<'PY'
import collections, os, sys, yaml

secrets_path, nodes_path, root, consumers_file = sys.argv[1:5]

def load(p):
    with open(p) as f:
        return yaml.safe_load(f) or {}

entries = load(secrets_path).get('secrets') or load(secrets_path).get('entries') or []
if not isinstance(entries, list):
    print("NOT_ESTABLISHED: secrets.yaml bez listy wpisow", file=sys.stderr)
    raise SystemExit(2)

node_map = load(nodes_path).get('nodes') or {}
valid_ips, local_ips = {}, set()
for name, nd in node_map.items():
    if isinstance(nd, dict) and nd.get('ip'):
        ip = str(nd['ip'])
        valid_ips[ip] = name
        if name == 'local' or nd.get('local') is True:
            local_ips.add(ip)
if not valid_ips:
    print("NOT_ESTABLISHED: mesh-nodes.yaml bez nodow z ip", file=sys.stderr)
    raise SystemExit(2)

cons = collections.defaultdict(lambda: {'mounts': set(), 'envs': set(), 'exists': set()})
for line in open(consumers_file):
    line = line.strip()
    if not line.startswith('NODE:') or '|' not in line:
        continue
    node, item = line[5:].split('|', 1)
    if item.startswith('MOUNT:'):
        cons[node]['mounts'].add(os.path.normpath(item[6:]))
    elif item.startswith('ENV:'):
        cons[node]['envs'].add(item[4:])
    elif item.startswith('EXISTS:'):
        cons[node]['exists'].add(os.path.normpath(item[7:]))

measured = {n for n, v in cons.items() if v['mounts'] or v['envs']}
if not measured:
    print("NOT_ESTABLISHED: pomiar konsumentow pusty (0 wezlow z danymi)", file=sys.stderr)
    raise SystemExit(2)

def parse_nodes(v):
    if v is None:
        return [], 'all'
    if isinstance(v, str):
        s = v.strip()
        if s in ('', 'all'):
            return [], 'all'
        return [x.strip() for x in s.split(',') if x.strip()], 'list'
    if isinstance(v, list):
        return [str(x).strip() for x in v if str(x).strip()], 'list'
    return [], 'all'

r1_local, r1_remote, r2, pairs = [], [], [], 0

for e in entries:
    if not isinstance(e, dict):
        continue
    path = e.get('vault_path') or '?'
    env_name = e.get('env_name') or ''
    targets = e.get('targets') or []
    if isinstance(targets, str):
        targets = [targets]
    listed, mode = parse_nodes(e.get('nodes'))

    if mode == 'list':
        bad = [t for t in listed if t not in valid_ips]
        if bad:
            r2.append((path, bad))

    covered = set(valid_ips) if mode == 'all' else set(listed)
    for t in targets:
        if not isinstance(t, str):
            continue
        ap = os.path.normpath(t if os.path.isabs(t) else os.path.join(root, t))
        for node in sorted(measured):
            live = ap in cons[node]['mounts']
            # env-file: zmienna JEST w env ORAZ plik istnieje na tym węźle.
            # Bez warunku istnienia pliku „VAULT_TOKEN" (nazwa wspólna wielu
            # wpisom) dawał fałszywe trafienia na węzłach bez tego pliku.
            if not live and env_name and t.endswith('.env') and ap in cons[node]['exists'] and env_name in cons[node]['envs']:
                live = True
            if not live:
                continue
            pairs += 1
            if node not in covered:
                (r1_local if node in local_ips else r1_remote).append((path, t, node))

print("secrets-distribution-coverage: wpisow=%d, wezlow zmierzonych=%d, par-zywych=%d"
      % (len(entries), len(measured), pairs))

rc = 0
# WAGA: konsument LOKALNY = FAIL (to wlasnie tu token wygasl po cichu).
# Konsument ZDALNY = WARN — wezel moze miec WLASNA kopie env produktu
# (zmierzone: contabo ma 17 takich wpisow); dopisanie go do listy lokalnego
# propagatora NADPISALOBY jego wartosci. Decyzja ludzka, nie automat.
if r1_local:
    rc = 1
    print("FAIL R1 (pominiety konsument LOKALNY — wartosc bedzie sie starzala po cichu):")
    for p, t, node in r1_local:
        print("  - %s -> %s : wezel %s czyta, brak go w `nodes:`" % (p, t, node))
if r1_remote:
    print("WARN R1-remote (zdalny konsument poza lista — sprawdz, czy wezel ma wlasna kopie env):")
    for p, t, node in sorted(r1_remote):
        print("  - %s -> %s : wezel %s czyta, brak go w `nodes:`" % (p, t, node))
if r2:
    rc = 1
    print("FAIL R2 (nazwa zamiast IP — sync-secrets NIGDY nie dopasuje, wpis jest no-opem):")
    for p, bad in r2:
        print("  - %s : nodes zawiera %s (dozwolone: 'all' albo IP z config/mesh-nodes.yaml)"
              % (p, ','.join(bad)))
if rc == 0:
    print("PASS: kazdy zmierzony konsument pokryty, kazdy token listy to IP")
raise SystemExit(rc)
PY
}

# ── Selftest ───────────────────────────────────────────────────────────────
selftest() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  cat > "$tmp/secrets.yaml" <<'YAML'
secrets:
  - vault_path: fixture/secret
    field: token
    env_name: FIXTURE_TOKEN
    targets: [config/secrets/fixture.token]
    nodes: [100.99.59.100]
YAML
  cat > "$tmp/mesh-nodes.yaml" <<'YAML'
nodes:
  local:
    ip: 100.98.144.70
    role: worker
  prod:
    ip: 100.99.59.100
    role: worker
YAML
  mkdir -p "$tmp/config/secrets"
  printf 'NODE:100.98.144.70|MOUNT:%s\nNODE:100.98.144.70|ENV:FIXTURE_TOKEN\nNODE:100.98.144.70|EXISTS:%s\nNODE:100.99.59.100|ENV:FIXTURE_TOKEN\nNODE:100.99.59.100|EXISTS:%s\n' \
    "$tmp/config/secrets/fixture.token" "$tmp/config/secrets/fixture.token" "$tmp/config/secrets/fixture.token" > "$tmp/consumers.txt"

  run() { AIGON_SECRETS_ROOT="$tmp" AIGON_SECRETS_CONFIG="$tmp/secrets.yaml" \
          AIGON_MESH_NODES_CONFIG="$tmp/mesh-nodes.yaml" AIGON_CONSUMERS_FILE="$1" bash "$0" 2>&1; }

  out="$(run "$tmp/consumers.txt")"; rc_bad=$?
  if [ "$rc_bad" -eq 1 ] && echo "$out" | grep -q 'FAIL R1' && echo "$out" | grep -q '100.98.144.70 czyta'; then
    echo "selftest 1/5 PASS: R1 pominiety konsument (lokalny) -> FAIL(1)"
  else
    echo "selftest 1/5 FAIL: oczekiwano rc=1 + FAIL R1, jest rc=$rc_bad"; echo "$out" | sed 's/^/    /'; rc=1
  fi

  python3 - "$tmp/secrets.yaml" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read(); open(p, 'w').write(t.replace("nodes: [100.99.59.100]", "nodes: [100.98.144.70, 100.99.59.100]"))
PY
  out="$(run "$tmp/consumers.txt")"; rc_ok=$?
  if [ "$rc_ok" -eq 0 ] && echo "$out" | grep -q '^PASS'; then
    echo "selftest 2/5 PASS: pokryci konsumenci -> PASS(0)"
  else
    echo "selftest 2/5 FAIL: oczekiwano rc=0 + PASS, jest rc=$rc_ok"; echo "$out" | sed 's/^/    /'; rc=1
  fi

  python3 - "$tmp/secrets.yaml" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read(); open(p, 'w').write(t.replace("nodes: [100.98.144.70, 100.99.59.100]", "nodes: [prod]"))
PY
  out="$(run "$tmp/consumers.txt")"; rc_name=$?
  if [ "$rc_name" -eq 1 ] && echo "$out" | grep -q 'FAIL R2'; then
    echo "selftest 3/5 PASS: R2 nazwa zamiast IP -> FAIL(1)"
  else
    echo "selftest 3/5 FAIL: oczekiwano rc=1 + FAIL R2, jest rc=$rc_name"; echo "$out" | sed 's/^/    /'; rc=1
  fi

  # 5) ZDALNY konsument poza lista -> PASS(0) + WARN (nie blokuje pushu)
  python3 - "$tmp/secrets.yaml" <<'PYX'
import sys
p = sys.argv[1]
t = open(p).read(); open(p, 'w').write(t.replace("nodes: [prod]", "nodes: [100.98.144.70]"))
PYX
  printf 'NODE:100.98.144.70|MOUNT:%s\nNODE:100.99.59.100|MOUNT:%s\nNODE:100.99.59.100|EXISTS:%s\n' \
    "$tmp/config/secrets/fixture.token" "$tmp/config/secrets/fixture.token" "$tmp/config/secrets/fixture.token" > "$tmp/consumers-remote.txt"
  out="$(run "$tmp/consumers-remote.txt")"; rc_rem=$?
  if [ "$rc_rem" -eq 0 ] && echo "$out" | grep -q 'WARN R1-remote' && echo "$out" | grep -q '100.99.59.100 czyta'; then
    echo "selftest 5/5 PASS: zdalny konsument -> PASS(0) + WARN"
  else
    echo "selftest 5/5 FAIL: oczekiwano rc=0 + WARN R1-remote, jest rc=$rc_rem"; echo "$out" | sed 's/^/    /'; rc=1
  fi

  : > "$tmp/empty.txt"
  out="$(run "$tmp/empty.txt")"; rc_empty=$?
  if [ "$rc_empty" -eq 2 ] && echo "$out" | grep -q 'NOT_ESTABLISHED'; then
    echo "selftest 4/5 PASS: brak pomiaru -> NOT_ESTABLISHED(2)"
  else
    echo "selftest 4/5 FAIL: oczekiwano rc=2 + NOT_ESTABLISHED, jest rc=$rc_empty"; echo "$out" | sed 's/^/    /'; rc=1
  fi

  rm -rf "$tmp"
  return "$rc"
}

case "${1:-}" in
  --selftest) selftest ;;
  --help|-h) sed -n '1,45p' "$0" ;;
  '') cf="$(mktemp)"; collect_consumers > "$cf" || { rm -f "$cf"; exit 2; } ; analyze "$cf"; rc=$?; rm -f "$cf"; exit "$rc" ;;
  *) echo "nieznany argument: $1" >&2; exit 2 ;;
esac
