#!/usr/bin/env bash
# fleet-role-guard.sh — bramka LAW-FLEET-ROLE-1 (zasoby wg roli, nie „domyślnie lokal").
#
# MIERZY STRUKTURĘ I POMIAR, NIE DEKLARACJE:
#   C1  prawo istnieje i ma law_id LAW-FLEET-ROLE-1
#   C2  builders.yaml parsuje się i ma >=1 builder LIVE
#   C3  każdy LIVE builder ma zadeklarowaną rolę (rola/role/zadania)
#   C4  ciężki build (gradle/cargo/nix/docker/mksquashfs) na local-aigon > PROG_MIN
#       minut => FAIL (naruszenie LAW-BUILD-PLACEMENT-1 / LAW-FLEET-ROLE-1)
#   C5  local load1 >= rdzenie => WARN z nazwą wolnego ogniwa (nie FAIL: przeciążenie
#       bywa chwilowe, ale musi być WIDOCZNE)
#
# UŻYCIE:
#   bash tools/gates/fleet-role-guard.sh
#   bash tools/gates/fleet-role-guard.sh --selftest
#   PROG_MIN=10 FLEET_ROLE_PS_FILE=/tmp/ps.txt bash tools/gates/fleet-role-guard.sh  # fixture
set -uo pipefail
export LC_ALL=C

ROOT="${AIGON_GATE_ROOT:-/opt/PROD}"
LAW="$ROOT/config/canonical/law-fleet-role-1.yaml"
BUILDERS="$ROOT/config/canonical/builders.yaml"
PROG_MIN="${PROG_MIN:-10}"
PS_FILE="${FLEET_ROLE_PS_FILE:-}"
FAILS=0; PASSES=0; WARNS=0
ok(){ PASSES=$((PASSES+1)); printf 'PASS  %s\n' "$1"; }
bad(){ FAILS=$((FAILS+1)); printf 'FAIL  %s\n' "$1"; }
warn(){ WARNS=$((WARNS+1)); printf 'WARN  %s\n' "$1"; }

check() {
  FAILS=0; PASSES=0; WARNS=0

  # C1 — prawo zarejestrowane
  if [ -f "$LAW" ] && grep -q '^law: LAW-FLEET-ROLE-1' "$LAW"; then
    ok "C1 prawo: LAW-FLEET-ROLE-1 ($(basename "$LAW"))"
  else
    bad "C1 brak prawa LAW-FLEET-ROLE-1 w $LAW"
  fi

  # C2/C3 — flota i role
  if [ -f "$BUILDERS" ] && python3 -c 'import yaml,sys;yaml.safe_load(open(sys.argv[1]))' "$BUILDERS" 2>/dev/null; then
    read -r live missing <<<"$(python3 - "$BUILDERS" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
bs = d.get("builders") or []
live = [b for b in bs if str(b.get("status", "")).upper() == "LIVE"]
missing = [b.get("hostname") or b.get("id") for b in live
           if not (b.get("rola") or b.get("role") or b.get("zadania"))]
print(len(live), len(missing))
PY
)"
    [ "${live:-0}" -ge 1 ] && ok "C2 buildery LIVE: $live" || bad "C2 zero builderów LIVE"
    [ "${missing:-1}" = "0" ] && ok "C3 każdy LIVE builder ma rolę" \
      || bad "C3 buildery bez roli: $missing"
  else
    bad "C2/C3 brak lub nieparsowalny $BUILDERS"
  fi

  # C4 — ciężkie buildy na local-aigon
  local heavy psf="${FLEET_ROLE_PS_FILE:-$PS_FILE}"
  if [ -n "$psf" ] && [ -f "$psf" ]; then
    # Fixture ma etimes w pierwszej kolumnie (format: "<etimes> <reszta...>").
    heavy=$(awk -v p="$PROG_MIN" '
      BEGIN{IGNORECASE=1}
      /gradlew|gradle |cargo build|nix build|docker build|mksquashfs|assembleRelease|assembleDebug|compileDebugKotlin|:app:test/ {
        if ($1+0 >= p*60) print $0
      }' "$psf" | head -5)
  else
    heavy=$(ps -eo etimes,args 2>/dev/null | awk -v p="$PROG_MIN" '
      BEGIN{IGNORECASE=1}
      /gradlew|gradle |cargo build|nix build|docker build|mksquashfs|assembleRelease|assembleDebug|compileDebugKotlin|:app:test/ {
        if ($1+0 >= p*60) print
      }' | grep -v 'fleet-role-guard' | head -5)
  fi
  if [ -z "$heavy" ]; then
    ok "C4 brak ciężkich buildów na lokalnym ogniwie (próg ${PROG_MIN} min)"
  else
    bad "C4 CIĘŻKI BUILD NA LOCAL-AIGON (>=${PROG_MIN} min) — powinien iść na builder:"
    printf '%s\n' "$heavy" | sed 's/^/      /'
  fi

  # C5 — przeciążenie lokalne vs flota
  local cores load1
  cores=$(nproc)
  load1=$(cut -d' ' -f1 /proc/loadavg)
  local over
  over=$(awk -v l="$load1" -v c="$cores" 'BEGIN{print (l+0 >= c+0) ? "1" : "0"}')
  if [ "$over" = "1" ]; then
    warn "C5 lokalne ogniwo przeciążone: load1=$load1 na $cores rdzeniach — pracę ciężką kieruj na builder (config/canonical/builders.yaml)"
  else
    ok "C5 lokalne ogniwo w normie: load1=$load1 / $cores"
  fi

  printf '\n-- PODSUMOWANIE: %d PASS, %d WARN, %d FAIL --\n' "$PASSES" "$WARNS" "$FAILS"
  [ "$FAILS" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  echo "=== SELFTEST: stan bieżący ==="
  check || echo "(stan bieżący czerwony — to może być prawdziwe naruszenie, nie błąd testu)"

  T=$(mktemp -d)
  trap 'rm -rf "$T"' EXIT
  # Fixture 1: symulowany build 42 min na local -> musi dać FAIL C4
  printf '75000 0:00 0 0 0 0 2520 gradlew :app:assembleRelease\n' > "$T/ps_heavy.txt"
  echo
  echo "=== SELFTEST: sabotaz (build 20h na local) -> oczekiwany FAIL C4 ==="
  if FLEET_ROLE_PS_FILE="$T/ps_heavy.txt" check >/dev/null 2>&1; then
    echo "SELFTEST FAIL: bramka NIE wykryla ciężkiego builda (fałszywy zielony)"
    exit 1
  fi
  echo "OK: ciężki build wykryty jako FAIL"

  # Fixture 2: brak ciężkich procesów -> C4 PASS
  : > "$T/ps_light.txt"
  echo
  echo "=== SELFTEST: brak ciężkich procesów -> oczekiwany PASS C4 ==="
  out=$(FLEET_ROLE_PS_FILE="$T/ps_light.txt" check 2>&1)
  if grep -q 'PASS  C4' <<<"$out"; then echo "OK: C4 PASS bez ciężkich buildów"; else
    echo "SELFTEST FAIL: C4 nie dał PASS na czystym fixture"; exit 1; fi
  echo "SELFTEST: PASS"
  exit 0
fi

check
