#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/env-pollution.sh — gate env-pollution (hook-runner/QG)
#
#  Wykrywa zanieczyszczone zmienne środowiskowe (token/sekret pod złą
#  nazwą). Przypadek bazowy (2026-08-28): AIGON_CORE_SKILLS_PORT
#  ustawione na token (klASWqZyf…) zamiast liczby 3193 — compose
#  interpolował env procesu z priorytetem nad .env → kontener dostawał
#  token jako port. Dowód skali: backupi core/.env zawierają tokeny
#  we WSZYSTKICH 7 zmiennych *_PORT.
#
#  Reguły:
#    (i)   *_PORT w środowisku procesu MUSI być liczbą 1-65535
#          (token/sekret pod nazwą portu = FAIL, fail-closed);
#    (ii)  znane *_PORT z SSOT (.env / core/.env) muszą być zgodne —
#          inna LICZBA = WARN (drift), wartość nieliczbowa = FAIL;
#    (iii) *_URL/*_HOST/*_ENDPOINT z białymi znakami lub $ = FAIL;
#          wartość token-like (długa, bez :// i bez .) = WARN.
#
#  Exit: 0 = PASS, 1 = FAIL (naruszenia na stdout), 2 = WARN (drift).
#  SSOT czytany z globalnego configa (.env) — zero hardcoded portów.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FAILED=0
WARNED=0
OUT=""

# ── (i)+(iii): skan środowiska procesu ────────────────────────────────────
while IFS='=' read -r name value; do
  case "$name" in
    *_PORT)
      if ! [[ "$value" =~ ^[0-9]{1,5}$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        FAILED=1
        OUT="${OUT}FAIL  $name=$value — *_PORT musi być liczbą 1-65535 (token/sekret pod złą nazwą?)\n"
      fi
      ;;
    *_URL|*_HOST|*_ENDPOINT)
      if [[ "$value" =~ [[:space:]] ]] || [[ "$value" == *\$* ]]; then
        FAILED=1
        OUT="${OUT}FAIL  $name=$value — niedozwolone znaki (białe spacje/\$) w wartości\n"
      elif [[ "$value" =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
        WARNED=1
        OUT="${OUT}WARN  $name=$value — token-like wartość pod nazwą *_URL/*_HOST/*_ENDPOINT\n"
      fi
      ;;
    AIGON_*_MODE)
      # P0 2026-08-28: sekret w AIGON_RUNTIME_MODE → compose `--mode <token>`
      # → runtime clap exit 2 → :7000 down. Whitelist tylko ról mesha.
      case "$value" in
        standalone|mesh-master|mesh-worker|master|worker) ;;
        *)
          FAILED=1
          OUT="${OUT}FAIL  $name=<len ${#value}> — *_MODE musi być standalone|mesh-master|mesh-worker (token/sekret pod złą nazwą?)\n"
          ;;
      esac
      ;;
    AIGON_NODE_ROLE)
      case "$value" in
        master|worker|scheduler|inference|gateway|observer|mesh-master|mesh-worker) ;;
        *)
          FAILED=1
          OUT="${OUT}FAIL  $name=<len ${#value}> — AIGON_NODE_ROLE musi być master|worker|scheduler|inference|gateway|observer\n"
          ;;
      esac
      ;;
  esac
done < <(env)

# ── (ii): zgodność znanych *_PORT z SSOT (.env) ───────────────────────────
for env_file in "$ROOT/.env" "$ROOT/core/.env"; do
  [ -r "$env_file" ] || continue
  while IFS='=' read -r key sval; do
    [ -z "$key" ] && continue
    val="${!key:-}"
    [ -z "$val" ] && continue
    if [ "$val" != "$sval" ]; then
      if [[ "$val" =~ ^[0-9]{1,5}$ ]]; then
        WARNED=1
        OUT="${OUT}WARN  $key=$val — drift: SSOT ($env_file) ma $sval\n"
      else
        FAILED=1
        OUT="${OUT}FAIL  $key=$val — niezgodne z SSOT ($env_file: $sval)\n"
      fi
    fi
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*_(PORT|URL|HOST|ENDPOINT)=' "$env_file" || true)
done

# ── werdykt (ostatnia linia = wynik dla runnera) ──────────────────────────
if [ "$FAILED" -eq 1 ]; then
  printf "%b" "$OUT"
  echo "FAIL env-pollution: zanieczyszczone zmienne w środowisku"
  exit 1
fi
if [ "$WARNED" -eq 1 ]; then
  printf "%b" "$OUT"
  echo "WARN env-pollution: drift wykryty (szczegóły wyżej)"
  exit 2
fi
echo "PASS env-pollution: środowisko czyste"
exit 0
