#!/usr/bin/env bash
# tools/gates/law-56a-secret-channel.sh — ADAPTER hook-runnera dla GATE-139 (LAW-56a).
#
# PO CO TEN PLIK (zmierzone 2026-09-29):
#   hook-runner uruchamia WYŁĄCZNIE `tools/gates/<id>.sh` (gate-reachability.sh:14).
#   Faktyczna implementacja GATE-139 leży w `tools/verify/law-56a-secret-channel.sh`
#   (tak wskazuje `command:` w gate-registry.yaml), więc wpisanie samej nazwy
#   `law-56a-secret-channel` do hooks.yaml NIE WYSTARCZYŁO — hook-runner raportował
#   `WARN law-56a-secret-channel (brak implementacji tools/gates/law-56a-secret-channel.sh)`.
#   To ta sama klasa defektu co „manifest != rejestracja": deklaracja bez dowodu
#   wykonania. Ten adapter jest tym brakującym ogniwem.
#
# KONTRAKT: przekazuje rc 1:1 (0 = brak naruszeń, 1 = naruszenie P0), bez zmiany
# semantyki i bez tlumienia wyjscia — bramka ma krzyczec, gdy znajdzie sekret.
set -uo pipefail

REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/verify/law-56a-secret-channel.sh"

if [[ ! -x "$REAL" ]]; then
  # Brak implementacji != brak naruszen. Nie udajemy sukcesu (LAW-011).
  echo "FAIL law-56a-secret-channel (brak implementacji: $REAL)"
  exit 1
fi

exec "$REAL" "$@"
