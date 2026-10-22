#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/liveness-production.sh — gate liveness-production
#
#  Lekcja 2026-09-07 (drony/AITO): „Health ≠ produkuje — 'Up' bez produkcji
#  jest martwy (healthcheck binarką)". Kontener bez healthchecka pozostaje
#  „Up" przy zawieszeniu; proces z exit 0 + restart = restart-storm.
#
#  Sprawdza kontenery AIGON-X (aigon-*):
#    - KAŻDY ma sondę healthcheck (docker inspect .State.Health) — brak = WARN
#      (nie każdy obraz ma binarkę-sondę; distroless bez shella — patrz lekcja)
#    - żaden zdefiniowany healthcheck nie jest `unhealthy` — unhealthy = FAIL
#    - kontener z wysokim RestartCount (>=50) = WARN (restart-storm)
#
#  Kontrakt z hook-runner.sh: exit 0 = PASS, 1 = FAIL, 2 = WARN.
#  Read-only (docker inspect). Wymaga docker — brak = WARN (diagnoza).
#  Env do testów: AIGON_LL_CONTAINERS (override listy kontenerów).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "WARN liveness-production: docker niedostępny — brak pomiaru (fail-open diagnostyczny)"
  exit 2
fi

CONTAINERS="${AIGON_LL_CONTAINERS:-$(docker ps --format '{{.Names}}' | grep '^aigon-' | sort)}"
[ -n "$CONTAINERS" ] || { echo "liveness-production: brak kontenerów aigon-*"; exit 2; }

FAILS=0; WARNS=0; PASSES=0
for c in $CONTAINERS; do
  has_health="$(docker inspect -f '{{if .State.Health}}1{{else}}0{{end}}' "$c" 2>/dev/null || echo 0)"
  if [ "$has_health" = "0" ]; then
    echo "WARN liveness-production: $c — BRAK sondy healthcheck (zawieszony proces zostanie 'Up')"
    WARNS=$((WARNS+1)); continue
  fi
  st="$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo unknown)"
  rc="$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)"
  case "$st" in
    healthy)  echo "PASS liveness-production: $c — healthy (restarts=$rc)"
              PASSES=$((PASSES+1)) ;;
    unhealthy)
              echo "FAIL liveness-production: $c — UNHEALTHY (sonda bije; restarts=$rc)"
              FAILS=$((FAILS+1)) ;;
    starting) echo "PASS liveness-production: $c — starting (sonda obecna)"
              PASSES=$((PASSES+1)) ;;
    *)        echo "WARN liveness-production: $c — status '$st'"
              WARNS=$((WARNS+1)) ;;
  esac
  if [ "${rc:-0}" -ge 50 ] 2>/dev/null; then
    echo "WARN liveness-production: $c — RestartCount=$rc (restart-storm? proces kończy się exit 0?)"
    WARNS=$((WARNS+1))
  fi
done

echo "liveness-production: PASS=$PASSES WARN=$WARNS FAIL=$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
[ "$WARNS" -eq 0 ] || exit 2
exit 0
