#!/usr/bin/env bash
# LAW-AKC-HEALTH — /health grants-svc odpowiada 200, nie „kontener running".
#
# Dwa tryby:
#   --structural  deklaracja prawa + sonda /health w kanonie (bez sieci)
#   (domyślnie)   struktura + ŻYWA sonda HTTP 200 na AIGON_AKC_HEALTH_URL
#   --selftest    dowód negatywny: brak deklaracji prawa MUSI dać FAIL
#
# UWAGA: sonda żywa NIE jest wpisana do pre-commit (bramka żywego stanu
# blokowałaby wszystkie commity przy awarii usługi). C7 sprawdza tylko,
# że implementacja istnieje; żywą sondę uruchamia monitoring/runbook.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAW="$ROOT/config/canonical/product-akceleratory.yaml"
URL="${AIGON_AKC_HEALTH_URL:-http://127.0.0.1:3001/health}"

struktura() {
  local plik="$1"
  [ -f "$plik" ] || { echo "FAIL law-akc-health: brak $plik"; return 1; }
  grep -q 'id: LAW-AKC-HEALTH' "$plik" \
    || { echo "FAIL law-akc-health: brak deklaracji LAW-AKC-HEALTH"; return 1; }
  grep -q 'gate: curl' "$plik" \
    || { echo "FAIL law-akc-health: brak sondy /health w kanonie"; return 1; }
  echo "PASS law-akc-health: deklaracja + sonda /health"
  return 0
}

zywo() {
  local url="$1" kod
  kod="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || echo 000)"
  if [ "$kod" = "200" ]; then
    echo "PASS law-akc-health: $url -> HTTP 200"
    return 0
  fi
  echo "FAIL law-akc-health: $url -> HTTP $kod (nie 200)"
  return 1
}

case "${1:-}" in
  --structural)
    struktura "$LAW"
    ;;
  --selftest)
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    cp "$LAW" "$tmp"
    sed -i 's/id: LAW-AKC-HEALTH/id: LAW-AKC-OTHER/' "$tmp"
    if struktura "$tmp" >/dev/null 2>&1; then
      echo "FAIL law-akc-health: selftest — brak prawa zaakceptowany"
      exit 1
    fi
    struktura "$LAW" || exit 1
    echo "PASS law-akc-health: selftest (brak prawa wykryty)"
    ;;
  *)
    struktura "$LAW" && zywo "$URL"
    ;;
esac
