#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  GATE: optiq-products — kanoniczna warstwa CI/CD projektow OPTIQ
#
#  PO CO: kazdy z 4 projektow OPTIQ (magazyn, construction, fenix, employes)
#  ma wlasna warstwe jakosci (Makefile: test/verify/lint + tools/verify/verify.sh),
#  ale ZADEN tor jej nie wolal — warstwa gotowa 2026-09-29 lezala bezuzyteczna
#  (defekt klasy "napisane bez wpiecia", LAW: written-must-be-wired).
#
#  ZMIERZONE 2026-09-30: `make verify` wisialo >120 s, bo verify.sh bralo
#  `git rev-parse --show-toplevel` -> /srv/aigon (nadrzedne repo) i skanowalo
#  CALE drzewo. Po przypieciu ROOT do katalogu projektu: PASS w ~7 s.
#
#  Bramka przechodzi tylko, gdy WSZYSTKIE 4 projekty przejda `make verify`.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="${AIGON_PROJECT_ROOT:-/srv/aigon}/products/optiq"
PROJECTS="${OPTIQ_PROJECTS:-magazyn construction fenix employes}"
TIMEOUT="${OPTIQ_VERIFY_TIMEOUT:-120}"
FAIL=0

echo "optiq-products: warstwa CI/CD projektow OPTIQ ($ROOT)"
for p in $PROJECTS; do
  if [ ! -d "$ROOT/$p" ]; then
    echo "  [FAIL] brak katalogu projektu: $p"
    FAIL=1
    continue
  fi
  if out=$(timeout "$TIMEOUT" make -C "$ROOT/$p" verify 2>&1); then
    echo "  [OK]   $p: $(printf '%s' "$out" | grep -o 'WYNIK: .*' | head -1)"
  else
    rc=$?
    echo "  [FAIL] $p (make verify, rc=$rc):"
    printf '%s\n' "$out" | tail -6 | sed 's/^/         /'
    FAIL=1
  fi
done

# ── Warstwa ARTEFAKTÓW frontendu (2026-10-19) ────────────────────────────────
# `make verify` NIE kompiluje frontendu, więc nie widzi, że z bundla wypadł
# arkusz CSS komponentów (Carbon). Zmierzone 2026-10-19: construction przeszedł
# bramkę kolorów, a renderował się BEZ arkusza Carbon (header 159 px zamiast 48,
# modale w przepływie strony, strona 3107 px) — bo link do unpkg usunięto,
# a importu do bundla nie dodano. Ta bramka mierzy WLASNIE to.
ASSETS_GATE="$ROOT/tools/check-frontend-assets.sh"
if [ -f "$ASSETS_GATE" ]; then
  if out=$(timeout 60 bash "$ASSETS_GATE" 2>&1); then
    echo "  [OK]   arkusze komponentów/CDN: $(printf '%s' "$out" | grep -o 'Wynik: .*' | tail -1)"
  else
    echo "  [FAIL] arkusze komponentów/CDN:"
    printf '%s\n' "$out" | grep '^\[FAIL\]' | sed 's/^/         /'
    FAIL=1
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "WYNIK: PASS — optiq-products (4/4 projektow)"
else
  echo "WYNIK: FAIL — optiq-products"
fi
exit "$FAIL"
