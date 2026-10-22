#!/usr/bin/env bash
# GATE-260: FIREWALL-SINGLE-WRITER — firewall ma JEDNEGO pisarza (generator iptables),
#          a `nftables.service` NIE MOŻE być uzbrojoną, martwą drugą warstwą.
#
# POWÓD (zmierzone 2026-10-20, dwa różne defekty tej samej klasy):
#   1) TRUJĄCA POZOSTAŁOŚĆ: `nftables.service` był `enabled` a `failed` na prod,
#      monitor, site, optiq (+ poligon). Na monitor/optiq conf zawierał
#      `table inet filter` z `policy drop` i SZEROKĄ allowlistą (7000, 38080, 31704
#      z KAŻDEGO źródła) oraz BEZ Vaulta :58200. Naprawa „na szybko" (iif → iifname)
#      włączyłaby ruleset, który JEDNOCZEŚNIE otwiera porty publicznie i ucina Vault.
#   2) STOP = WIPE: `systemctl stop nftables` na Debianie uruchamia
#      `ExecStop=/usr/sbin/nft flush ruleset`, co kasuje CAŁY ruleset —
#      także łańcuchy Dockerа (DOCKER/DOCKER-USER/NAT) i reguły kanonu.
#      Zmierzone na poligonie 2026-10-20: 0 reguł `aigon:` w INPUT, brak MASQUERADE,
#      INPUT policy ACCEPT — kontenery żyły bez plątaniny NAT/FORWARD.
#      Dlatego „revert" przez stop jest ZAKAZANY; wolno tylko `nft delete table`.
#
# KANON (jeden pisarz): config/canonical/firewall.yaml →
#   scripts/aigon-firewall-generate.py (reguły z komentarzem `aigon:<id>`) + ufw/rules.v4
#   dla polityki INPUT. `nftables.service` NIE jest częścią kanonu — ma być
#   wyłączony, a /etc/nftables.conf zarchiwizowany.
#
# Kontrakt: 0=PASS, 1=FAIL (trap albo brak kanonu), 2=WARN (dług: polityka ACCEPT
#           albo węzeł NIEZMIERZONY — brak zasobów ≠ defekt, LAW-NOFALL-1)
# Użycie:   firewall-single-writer.sh [--selftest] [--node <nazwa,nazwa>] [--json]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
NODES_YAML="${AIGON_MESH_NODES:-$ROOT/config/mesh-nodes.yaml}"
SELFTEST=0
ONLY=""
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) SELFTEST=1; shift ;;
    --node) ONLY="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "nieznany argument: $1" >&2; exit 2 ;;
  esac
done

# ── Ocena JEDNEJ linii pomiaru (czysta funkcja — testowalna bez SSH) ────────
# Format linii: enabled|active|inet_filter|aigon_input|policy|aigon_docker_user
ocen() { # $1=linia $2=nazwa węzła  -> rc 0=PASS 1=FAIL, WARN wypisuje ale nie failuje
  local linia="$1" node="$2"
  local en ac tb ain pol adu
  IFS='|' read -r en ac tb ain pol adu <<<"$linia"
  local fail=0

  # (1) TRAP: nftables uzbrojony/zapowiedziany = druga warstwa obok kanonu
  if [ "$en" = "enabled" ] || [ "$ac" = "active" ]; then
    echo "  FAIL $node — nftables.service en=$en ac=$ac (drugi pisarz firewalla; kanon = aigon-firewall-generate.py)"
    fail=1
  fi
  # (2) TRAP: żywa tabela inet filter = reguły spoza kanonu w kernelu
  if [ "$tb" = "1" ]; then
    echo "  FAIL $node — żywa tabela 'inet filter' w kernelu (reguły poza kanonem)"
    fail=1
  fi
  # (3) BRAK KANONU: zero reguł generatora w INPUT
  if [ -z "$ain" ] || [ "$ain" -lt 1 ] 2>/dev/null; then
    echo "  FAIL $node — 0 reguł 'aigon:' w INPUT (kanon firewalla NIE wdrożony; uruchom aigon-firewall-generate.py --apply)"
    fail=1
  fi
  # (4) DŁUG (nie fail): polityka INPUT ACCEPT — kanon hosts.default mówi DROP
  if [ "$pol" = "ACCEPT" ]; then
    echo "  WARN $node — INPUT policy ACCEPT (kanon: DROP); dług warstwy ufw/rules.v4, nie blokuje"
  fi
  # (5) Informacja: segmentacja kontenerów (tylko gdy docker jest)
  if [ -n "$adu" ] && [ "$adu" = "0" ] && [ "$ain" -ge 1 ] 2>/dev/null; then
    echo "  INFO $node — 0 reguł 'aigon:' w DOCKER-USER (brak łańcucha Dockerа na węźle?)"
  fi
  return "$fail"
}

# ── SELFTEST: dowód negatywny (sabotaż → FAIL) ─────────────────────────────
if [ "$SELFTEST" = "1" ]; then
  rc_all=0
  check() { # $1=opis $2=linia $3=oczekiwany_rc
    local opis="$1" linia="$2" oczek="$3" out rc
    out="$(ocen "$linia" "selftest" 2>&1)"; rc=$?
    if [ "$rc" = "$oczek" ]; then
      echo "  PASS selftest: $opis (rc=$rc)"
    else
      echo "  FAIL selftest: $opis — oczekiwano rc=$oczek, jest rc=$rc"; rc_all=1
    fi
  }
  check "czysty węzeł"                     "disabled|inactive|0|15|DROP|35"   0
  check "trap: nftables enabled+failed"    "enabled|failed|0|15|DROP|35"      1
  check "trap: nftables aktywny"           "disabled|active|0|15|DROP|35"     1
  check "trap: żywa tabela inet filter"    "disabled|inactive|1|15|DROP|35"   1
  check "brak kanonu (0 reguł aigon)"      "disabled|inactive|0|0|DROP|0"     1
  check "polityka ACCEPT = tylko WARN"     "disabled|inactive|0|15|ACCEPT|35" 0
  echo "SELFTEST: $([ "$rc_all" = 0 ] && echo 'PASS 6/6' || echo 'FAIL')"
  exit "$rc_all"
fi

# ── Lista węzłów z kanonu ─────────────────────────────────────────────────
mapfile -t NODES < <(python3 - "$NODES_YAML" <<'PY'
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
nodes = d.get("nodes") or {}
for name, v in nodes.items():
    if not isinstance(v, dict):
        continue
    if v.get("expected_down") is True:      # kanon: węzeł świadomie martwy
        continue
    ip = str(v.get("ip") or "").strip()
    if ip:
        print(f"{name} {ip}")
PY
)
if [ "${#NODES[@]}" -eq 0 ]; then
  echo "FAIL: nie odczytałem listy węzłów z $NODES_YAML" >&2
  exit 1
fi

rc_final=0; ile_ok=0; ile_fail=0; ile_niem=0
for wpis in "${NODES[@]}"; do
  set -- $wpis; name="$1"; ip="$2"
  if [ -n "$ONLY" ] && ! printf ',%s,' "$ONLY" | grep -q ",$name,"; then continue; fi

  # 3 próby: pod obciążeniem (suite/build na węźle) SSH potrafi nie odpowiedzieć
  # w 6 s — pojedyncza próba dawała FAŁSZYWY CZERWONY (zmierzone 2026-10-20).
  linia=""
  for proba in 1 2 3; do
    linia="$(timeout 20 ssh -o ConnectTimeout=6 -o BatchMode=yes -o LogLevel=ERROR "root@$ip" '
      en=$(systemctl is-enabled nftables 2>/dev/null || true)
      ac=$(systemctl is-active nftables 2>/dev/null || true)
      tb=$(nft list table inet filter >/dev/null 2>&1 && echo 1 || echo 0)
      ain=$(iptables -S INPUT 2>/dev/null | grep -c "aigon:" || true)
      pol=$(iptables -S INPUT 2>/dev/null | head -1 | sed "s/^-P INPUT //" || true)
      adu=$(iptables -S DOCKER-USER 2>/dev/null | grep -c "aigon:" || true)
      printf "%s|%s|%s|%s|%s|%s" "${en:-?}" "${ac:-?}" "$tb" "${ain:-0}" "${pol:-?}" "${adu:-0}"
    ' 2>/dev/null)"
    [ -n "$linia" ] && break
    [ "$proba" -lt 3 ] && sleep 4
  done

  if [ -z "$linia" ]; then
    echo "  WARN $name ($ip) — NIEZMIERZONY (3 próby SSH bez odpowiedzi; nie klasyfikuję jako defekt)"
    ile_niem=$((ile_niem+1)); continue
  fi
  out="$(ocen "$linia" "$name ($ip)")"; rc=$?
  [ -n "$out" ] && echo "$out"
  if [ "$rc" = 0 ]; then ile_ok=$((ile_ok+1)); else rc_final=1; ile_fail=$((ile_fail+1)); fi
done

[ "$rc_final" = 0 ] && [ "$ile_niem" -gt 0 ] && rc_final=2
if [ "$JSON" = "1" ]; then
  printf '{"gate":"GATE-260","ok":%d,"fail":%d,"unmeasured":%d,"verdict":"%s"}\n' \
    "$ile_ok" "$ile_fail" "$ile_niem" "$(case $rc_final in 0) echo PASS;; 1) echo FAIL;; *) echo WARN;; esac)"
else
  echo "GATE-260 firewall-single-writer: ok=$ile_ok fail=$ile_fail niezmierzone=$ile_niem → $(case $rc_final in 0) echo PASS;; 1) echo FAIL;; *) echo WARN;; esac)"
fi
exit "$rc_final"
