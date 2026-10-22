#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/health-local.sh — gate health-local (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  Lokalny runtime :7000/health == 200. Runtime serwuje HTTPS-only
#  (kanon 2026-08-08), health jest otwarty (bez auth).
#
#  Kontrakt: exit 0 = PASS, exit 1 = FAIL (health != 200).
#  Zmienne env: AIGON_RUNTIME_URL (default https://127.0.0.1:7000).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

RUNTIME_URL="${AIGON_RUNTIME_URL:-https://127.0.0.1:7000}"

H=$(curl -sk -m 8 "$RUNTIME_URL/health" -o /dev/null -w "%{http_code}" 2>/dev/null)
if [ "$H" = "200" ]; then
  echo "health-local: PASS ($RUNTIME_URL/health=200)"
  exit 0
fi
echo "health-local: FAIL (health=$H na $RUNTIME_URL)"
exit 1
