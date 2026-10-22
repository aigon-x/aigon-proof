#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  GATE: aio-okolic-products — kanoniczna warstwa CI/CD produktu „AI dla Okolic"
#
#  PO CO: produkt (products/aio-okolic) ma wlasny potok bramek
#  (tools/gates.sh: testy + compose + design + production-ready + kanon),
#  ale ZADEN tor go nie wolal — warstwa gotowa, lezala bezuzyteczna
#  (defekt klasy „napisane bez wpiecia", LAW: written-must-be-wired).
#
#  Ta bramka to jedyny kanoniczny punkt wejscia: wolana przez hook-runner
#  (tools/gates/aio-okolic-products.sh -> tu) i widoczna w rejestrze.
#
#  Kontrakt hook-runnera: exit 0 = PASS/WARN, exit 1 = FAIL.
#  Budzet: AIO_PRODUCT_GATE_TIMEOUT (domyslnie 280 s — suite ~120 s + reszta).
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
KANON="${AIGON_PROJECT_ROOT:-/opt/PROD}"
PRODUKT="${AIO_PRODUKT_DIR:-$KANON/products/aio-okolic}"
. "$(dirname "${BASH_SOURCE[0]}")/../../../../scripts/lib/gate-params.sh"
TIMEOUT="$(gp GATE-234 aio_product_gate_timeout_s 280)"

echo "aio-okolic-products: potok bramek produktu ($PRODUKT)"

if [ ! -d "$PRODUKT" ]; then
  echo "  [FAIL] brak katalogu produktu: $PRODUKT"
  echo "WYNIK: FAIL — aio-okolic-products"
  exit 1
fi
if [ ! -f "$PRODUKT/tools/gates.sh" ]; then
  echo "  [FAIL] brak potoku bramek: $PRODUKT/tools/gates.sh"
  echo "WYNIK: FAIL — aio-okolic-products"
  exit 1
fi

out="$(mktemp)"
if timeout "$TIMEOUT" bash "$PRODUKT/tools/gates.sh" "$@" >"$out" 2>&1; then
  rc=0
else
  rc=$?
fi
sed 's/^/    /' "$out"
rm -f "$out"

if [ "$rc" -eq 0 ]; then
  echo "WYNIK: PASS — aio-okolic-products"
  exit 0
elif [ "$rc" -eq 2 ]; then
  echo "WYNIK: WARN — aio-okolic-products (tylko SKIP: brak srodowiska, nie defekt)"
  exit 0
elif [ "$rc" -eq 124 ]; then
  echo "WYNIK: FAIL — aio-okolic-products (TIMEOUT > ${TIMEOUT}s)"
  exit 1
else
  echo "WYNIK: FAIL — aio-okolic-products (rc=$rc)"
  exit 1
fi
