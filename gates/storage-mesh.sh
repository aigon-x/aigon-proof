#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/storage-mesh.sh — BRAMKA warstwy STORAGE (storage-aigon)
#
#  ROZKAZ SUWERENA 2026-10-17: „na pve dodaliśmy VMkę storage, podłącz ją do
#  mesha jako storage" + „zaplanuj strukturę kanoniczną" + „katalog repozytoriów".
#
#  CO WERYFIKUJE (read-only, FAIL-closed):
#    H1  manifest SSOT: config/canonical/storage-mesh.yaml parsuje się, id=storage-mesh,
#    H2  DNS: external_hosts.storage w mesh-dns.yaml + getent == adres tailnet,
#    H3  macierz SSH: scripts/storage-ssh-trust.py --check rc=0 (węzeł <-> storage),
#    H4  montaże lokalne: 5 tierów w /proc/self/mountinfo, źródło w 100.x (nie LAN),
#    H5  eksporty NFS na storage: 5 ścieżek (nfs/backup/shared/cold/repos),
#    H6  Prometheus: target job=pve-storage-node w stanie up,
#    H7  alerty: grupa „Storage tier (storage-aigon)" z >= 7 regułami,
#    H8  metryki: aigon_storage_pool_health == 1 (pula ONLINE) w Prometheusie,
#    H9  cron: wpisy storage-mount-truth + storage-inventory w config/cron.yaml,
#    H10 dokumentacja: plan + inwentarz istnieją, inwentarz świeży (< 48 h),
#    H11 brak montażu po LAN (192.168.1.180) jako źródła czegokolwiek.
#
#  UŻYCIE:
#    bash tools/gates/storage-mesh.sh                 # PASS/FAIL
#    bash tools/gates/storage-mesh.sh --selftest      # dowód negatywny (sabotaż)
#    AIGON_STORAGE_GATE_OFFLINE=1 …                   # pomiń H3/H5/H6/H8 (bez sieci)
#
#  EXIT: 0 = PASS, 1 = FAIL (każdy FAIL ma nazwany powód).
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${AIGON_STORAGE_MANIFEST:-${ROOT}/config/canonical/storage-mesh.yaml}"
DNS_YAML="${ROOT}/config/canonical/mesh-dns.yaml"
RULES_YML="${ROOT}/observability/prometheus/rules.yml"
CRON_YAML="${ROOT}/config/cron.yaml"
PROM="${AIGON_PROM_URL:-http://127.0.0.1:49091}"
STORAGE_HOST_IP="100.115.90.62"
STORAGE_SSH="root@${STORAGE_HOST_IP}"
OFFLINE="${AIGON_STORAGE_GATE_OFFLINE:-0}"
FAIL=0
note() { printf '  %-6s %s\n' "$1" "$2"; }
fail() { note FAIL "$1"; FAIL=1; }
ok()   { note OK   "$1"; }

py() { python3 - "$@"; }

# ── DOWÓD NEGATYWNY (--selftest) ───────────────────────────────────────────
# Bramka bez dowodu negatywnego NIE ISTNIEJE (kanon: sabotuj → FAIL, przywróć → PASS).
if [ "${1:-}" = "--selftest" ]; then
  echo "== SELFTEST: sabotaż manifestu (zły id) =="
  tmp="$(mktemp)"
  cp "$MANIFEST" "$tmp"
  python3 - "$tmp" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(re.sub(r'^id: .*$', 'id: NIE-STORAGE', s, count=1, flags=re.M))
PY
  AIGON_STORAGE_MANIFEST="$tmp" AIGON_STORAGE_GATE_OFFLINE=1 bash "${BASH_SOURCE[0]}" >/dev/null 2>&1
  rc_bad=$?
  echo "== SELFTEST: sabotaż DNS (usunięta nazwa) =="
  tmpd="$(mktemp)"
  grep -v "storage.aigon.consul" "$DNS_YAML" > "$tmpd"
  AIGON_STORAGE_DNS_YAML="$tmpd" AIGON_STORAGE_GATE_OFFLINE=1 bash "${BASH_SOURCE[0]}" >/dev/null 2>&1
  rc_dns=$?
  rm -f "$tmp" "$tmpd"
  if [ "$rc_bad" = 1 ] && [ "$rc_dns" = 1 ]; then
    echo "SELFTEST PASS (sabotaż manifestu=FAIL, sabotaż DNS=FAIL)"
    exit 0
  fi
  echo "SELFTEST FAIL (rc_bad=$rc_bad rc_dns=$rc_dns — bramka przepuszcza sabotaż)"
  exit 1
fi
[ -n "${AIGON_STORAGE_DNS_YAML:-}" ] && DNS_YAML="$AIGON_STORAGE_DNS_YAML"

# H1 — manifest
if [ ! -f "$MANIFEST" ]; then
  fail "H1 brak manifestu $MANIFEST"
else
  if py "$MANIFEST" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
sys.exit(0 if d.get("id") == "storage-mesh" and d.get("identity", {}).get("hostname") == "storage-aigon" else 1)
PY
  then ok "H1 manifest SSOT (id=storage-mesh, host=storage-aigon)"
  else fail "H1 manifest nieparsowalny albo zły id/hostname"; fi
fi

# H2 — DNS
dns_ok=1
py "$DNS_YAML" <<'PY' || dns_ok=0
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
ext = d.get("external_hosts") or {}
st = ext.get("storage") or {}
names = st.get("names") or []
sys.exit(0 if st.get("ip") == "100.115.90.62" and "storage.aigon.consul" in names else 1)
PY
resolved="$(getent hosts storage.aigon.consul 2>/dev/null | awk '{print $1; exit}')"
if [ "$dns_ok" = 1 ] && [ "$resolved" = "$STORAGE_HOST_IP" ]; then
  ok "H2 DNS external_hosts.storage + getent = $resolved"
else
  fail "H2 DNS: external_hosts.storage brak/zły ALBO getent='${resolved:-nic}' (oczekiwane $STORAGE_HOST_IP)"
fi

if [ "$OFFLINE" != "1" ]; then
  # H3 — macierz SSH.
  # UWAGA (2026-10-17): bramka mierzy STORAGE, nie żywotność mesha. Węzeł, który
  # jest OFFLINE w tailnecie (albo expected_down w SSOT), raportuje osobny alert
  # (MeshPresence/RuntimeNodeDown) — tutaj liczy się jako POMINIĘTY z powodem,
  # inaczej awaria noda robiłaby „czerwień" na warstwie, która działa.
  SKIP_NODES="$(python3 - "${ROOT}" <<'PY2' 2>/dev/null || true
import json, subprocess, sys, yaml
root = sys.argv[1]
mesh = (yaml.safe_load(open(root + "/config/mesh-nodes.yaml", encoding="utf-8")) or {}).get("nodes") or {}
skip = {n for n, spec in mesh.items() if isinstance(spec, dict) and spec.get("expected_down")}
try:
    ts = json.loads(subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=15).stdout or "{}")
except Exception:
    ts = {}
by_ip = {}
for p in (ts.get("Peer") or {}).values():
    for ip in (p.get("TailscaleIPs") or []):
        by_ip[ip] = p
for n, spec in mesh.items():
    if not isinstance(spec, dict):
        continue
    ip = str(spec.get("ip") or "")
    p = by_ip.get(ip)
    if p is not None and not p.get("Online", True):
        skip.add(n)
print(",".join(sorted(skip)))
PY2
)"
  [ -n "$SKIP_NODES" ] && note INFO "H3 pomijam offline/expected_down: $SKIP_NODES"
  if timeout 240 python3 "${ROOT}/scripts/storage-ssh-trust.py" --check --skip "$SKIP_NODES" >/tmp/storage-gate-ssh.$$ 2>&1; then
    ok "H3 macierz SSH węzeł <-> storage (rc=0)"
  else
    fail "H3 macierz SSH: $(grep -c LUKA /tmp/storage-gate-ssh.$$ 2>/dev/null || echo '?') luk — $(grep LUKA /tmp/storage-gate-ssh.$$ 2>/dev/null | head -2 | tr '\n' ' ')"
  fi
  rm -f /tmp/storage-gate-ssh.$$
fi

# H4 — montaże lokalne (4 tiery, źródło 100.x)
miss=""
for t in /mnt/aigon-store /mnt/aigon-backup /mnt/aigon-shared /mnt/aigon-cold /mnt/aigon-repos; do
  src="$(findmnt -n -o SOURCE --target "$t" 2>/dev/null || true)"
  case "$src" in
    *100.*) : ;;
    "") miss="$miss $t(brak)" ;;
    *) miss="$miss $t(zle_zrodlo:$src)" ;;
  esac
done
if [ -z "$miss" ]; then ok "H4 montaże 5 tierów z adresu mesha (100.x)"
else fail "H4 montaże:$miss"; fi

if [ "$OFFLINE" != "1" ]; then
  # H5 — eksporty NFS
  ex="$(timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=8 "$STORAGE_SSH" 'exportfs -s 2>/dev/null | grep -c "^/"' 2>/dev/null || echo 0)"
  want=5
  if [ "${ex:-0}" -ge "$want" ]; then ok "H5 eksporty NFS: $ex (>= $want)"
  else fail "H5 eksporty NFS: ${ex:-0} < $want (oczekiwane nfs/backup/shared/cold/repos)"; fi

  # H6 — target Prometheusa
  up="$(curl -s --max-time 8 "${PROM}/api/v1/query?query=up%7Bjob%3D%22pve-storage-node%22%7D" 2>/dev/null \
        | python3 -c "import json,sys;d=json.load(sys.stdin);r=d['data']['result'];print(r[0]['value'][1] if r else '')" 2>/dev/null || true)"
  if [ "$up" = "1" ]; then ok "H6 Prometheus: pve-storage-node up"
  else fail "H6 Prometheus: pve-storage-node up='${up:-brak}'"; fi

  # H8 — metryka puli ONLINE
  hl="$(curl -s --max-time 8 "${PROM}/api/v1/query?query=aigon_storage_pool_health" 2>/dev/null \
        | python3 -c "import json,sys;d=json.load(sys.stdin);r=d['data']['result'];print(r[0]['value'][1] if r else '')" 2>/dev/null || true)"
  if [ "$hl" = "1" ]; then ok "H8 metryka aigon_storage_pool_health=1 (pula ONLINE)"
  else fail "H8 metryka aigon_storage_pool_health='${hl:-brak}'"; fi
fi

# H7 — grupa alertów
n_rules="$(py "$RULES_YML" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
n = 0
for g in d.get("groups", []):
    if g.get("name") == "Storage tier (storage-aigon)":
        n = len(g.get("rules") or [])
print(n)
PY
)"
if [ "${n_rules:-0}" -ge 7 ]; then ok "H7 alerty: grupa Storage tier ($n_rules reguł)"
else fail "H7 alerty: grupa Storage tier ma ${n_rules:-0} reguł (oczekiwane >= 7)"; fi

# H9 — cron
c1="$(grep -c "storage-mount-truth" "$CRON_YAML" 2>/dev/null || true)"
c2="$(grep -c "storage-inventory" "$CRON_YAML" 2>/dev/null || true)"
if [ "${c1:-0}" -ge 1 ] && [ "${c2:-0}" -ge 1 ]; then
  ok "H9 cron: storage-mount-truth + storage-inventory obecne"
else
  fail "H9 cron: brak wpisów (mount=${c1:-0}, inventory=${c2:-0})"
fi

# H10 — dokumentacja + świeżość inwentarza
DOC_PLAN="${ROOT}/docs/STORAGE-CANONICAL-PLAN.md"
DOC_INV="${ROOT}/docs/STORAGE-INVENTORY.md"
if [ -f "$DOC_PLAN" ] && [ -f "$DOC_INV" ]; then
  age_h=$(( ( $(date +%s) - $(stat -c %Y "$DOC_INV") ) / 3600 ))
  if [ "$age_h" -le 48 ]; then ok "H10 dokumentacja: plan + inwentarz (wiek ${age_h} h)"
  else fail "H10 inwentarz nieświeży: ${age_h} h (cron storage-inventory 04:20)"; fi
else
  fail "H10 brak dokumentacji (plan=$([ -f "$DOC_PLAN" ] && echo jest || echo brak), inwentarz=$([ -f "$DOC_INV" ] && echo jest || echo brak))"
fi

# H11 — żaden montaż tieru nie idzie po LAN storage
lan_bad="$(awk '$5 ~ /^\/mnt\/aigon-(store|backup|shared|cold|repos)$/ && $0 ~ /192\.168\.1\.180/ {print $5}' /proc/self/mountinfo 2>/dev/null | tr '\n' ' ')"
if [ -z "$lan_bad" ]; then ok "H11 zero montaży tierów po LAN 192.168.1.180"
else fail "H11 montaż po LAN: $lan_bad"; fi

echo
if [ "$FAIL" = 0 ]; then echo "storage-mesh: PASS"; exit 0; fi
echo "storage-mesh: FAIL"; exit 1
