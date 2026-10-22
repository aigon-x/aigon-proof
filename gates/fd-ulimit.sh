#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/fd-ulimit.sh — gate fd-ulimit (cyclic:6h)
#
#  Wykrywa ryzyko "os error 24 (too many open files)" z CANONICAL-STRUCTURE
#  2026-08-21 (S7):
#    - twardy limit FD na hoście poniżej progu (default 65536)
#    - użycie FD (liczba otwartych deskryptorów procesów) blisko limitu
#    - limity FD kontenerów Docker bez jawnego Ulimit (dziedziczą host)
#
#  Exit: 0 = PASS, 1 = FAIL (ryzyko wyczerpania FD), 2 = WARN (brak
#  możliwości sprawdzenia). Ostatnia linia stdout = komunikat.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

failures=0
found=""

report() {
  found="${found}${1}"$'\n'
  failures=$((failures + 1))
}

FD_THRESHOLD="${FD_ULIMIT_THRESHOLD:-65536}"

# ── twardy limit FD (host) ────────────────────────────────────────────
hard=$(ulimit -Hn 2>/dev/null || echo "")
host_hard="$hard"
if [ -z "$hard" ]; then
  report "S7: nie można odczytać ulimit -Hn (WARN: sprawdzenie niemożliwe)"
else
  if [ "$hard" -lt "$FD_THRESHOLD" ]; then
    report "S7: twardy limit FD hosta = $hard (próg $FD_THRESHOLD) — ryzyko os error 24"
  fi
fi

# ── użycie FD vs limit (top procesy po FD) ────────────────────────────
if [ -r /proc/sys/fs/file-nr ]; then
  read -r allocated unused max < /proc/sys/fs/file-nr 2>/dev/null || true
  if [ -n "${max:-}" ] && [ "$max" -gt 0 ]; then
    pct=$((allocated * 100 / max))
    if [ "$pct" -ge 90 ]; then
      report "S7: użycie FD systemu = $allocated/$max ($pct%) — próg 90% przekroczony"
    fi
  fi
else
  report "S7: brak /proc/sys/fs/file-nr (WARN: sprawdzenie niemożliwe)"
fi

# ── kontenery bez jawnego limitu FD ───────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  no_ulimit=$(docker ps --format '{{.Names}}' 2>/dev/null | while read -r c; do
    [ -n "$c" ] || continue
    u=$(docker inspect --format '{{if .HostConfig.Ulimits}}{{.HostConfig.Ulimits}}{{else}}NONE{{end}}' "$c" 2>/dev/null)
    case "$u" in
      *nofile*) ;;
      *NONE*|"") echo "$c" ;;
    esac
  done)
  if [ -n "$no_ulimit" ]; then
    n=$(echo "$no_ulimit" | grep -c .)
    # RYZYKO = EFEKTYWNY limit < próg, nie „brak klucza w HostConfig".
    # Zmierzone 2026-10-17: host hard nofile = 1 048 576 (16x próg), file-nr 1,8%.
    # Kontener dziedziczy 1M → brak realnego ryzyka; wcześniejsza wersja liczyła
    # samą OBECNOŚĆ klucza i raportowała 72 fałszywe FAIL-e.
    if [ -n "${host_hard:-}" ] && [ "$host_hard" -ge "$FD_THRESHOLD" ]; then
      echo "    WARN S7: $n kontener(ów) dziedziczy limit hosta ($host_hard >= próg $FD_THRESHOLD) — brak jawnego nofile, ale limit efektywny bezpieczny"
    else
      report "S7: $n kontener(ów) bez jawnego limitu nofile, a limit hosta (${host_hard:-?}) < próg $FD_THRESHOLD: $(echo "$no_ulimit" | tr '\n' ' ')"
    fi
  fi
fi

# ── Werdykt ───────────────────────────────────────────────────────────
if [ "$failures" -gt 0 ]; then
  echo "FAIL: ryzyko wyczerpania FD (${failures}):"
  echo -n "$found" | sed 's/^/  /'
  exit 1
fi

echo "PASS: limity FD bezpieczne"
exit 0
