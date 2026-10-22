#!/usr/bin/env bash
# dns-first-check.sh — gate DNS-FIRST (LAW-DNS-1)
# ROZKAZ SUWERENA 2026-10-12: adresy nodów mesha MUSZĄ być nazwami aigon.consul,
# NIE gołymi IP (100.x.x.x). Zmierzone naruszenie: AIGON_MESH_MASTER_URLS w .env
# poligonu wpisany IP-ami (https://100.99.59.100:7000,...) zamiast DNS.
# Ta bramka blokuje hardcoded IP nodów mesha w .env / compose / config.
#
# Kontrakt: exit 0 = PASS (DNS-first), exit 1 = FAIL (hardcoded IP mesha).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# IP nodów mesha (SSOT: config/mesh-nodes.yaml ip:) — te NIE mogą być gołe w adresach.
MESH_IPS=$(python3 - "$ROOT/config/mesh-nodes.yaml" << 'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for name, node in (d.get('nodes') or {}).items():
    ip = node.get('ip')
    if ip:
        print(ip)
PY
)
[ -n "$MESH_IPS" ] || MESH_IPS="100.99.59.100 100.98.144.70 100.77.55.117 100.110.245.84 100.106.47.1 100.79.105.36 100.71.177.5 100.70.46.42 100.121.86.42"

FAIL=0
# 1. .env — adresy https://IP / http://IP (nie https://*.aigon.consul)
if [ -f "$ROOT/.env" ]; then
  for ip in $MESH_IPS; do
    hits=$(grep -E "https?://${ip}" "$ROOT/.env" 2>/dev/null | grep -v '#' | head -3)
    if [ -n "$hits" ]; then
      echo "dns-first: FAIL — .env ma goły IP $ip zamiast *.aigon.consul:"
      echo "$hits" | sed 's/^/  /'
      FAIL=1
    fi
  done
fi

# 2. docker-compose.yml — interpolacja z IP w URL (z wyłączeniem bind 0.0.0.0/127.0.0.1)
if [ -f "$ROOT/docker-compose.yml" ]; then
  for ip in $MESH_IPS; do
    hits=$(grep -nE "https?://${ip}" "$ROOT/docker-compose.yml" 2>/dev/null | grep -vE '127\.0\.0\.1|0\.0\.0\.0' | head -3)
    if [ -n "$hits" ]; then
      echo "dns-first: FAIL — docker-compose.yml ma goły IP $ip zamiast *.aigon.consul:"
      echo "$hits" | sed 's/^/  /'
      FAIL=1
    fi
  done
fi

if [ "$FAIL" = "0" ]; then
  echo "dns-first: PASS — adresy nodów mesha = nazwy aigon.consul (bez gołych IP)"
  exit 0
fi
exit 1
