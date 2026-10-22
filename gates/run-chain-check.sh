#!/usr/bin/env bash
# ============================================================================
# run-chain-check.sh — RUN-CHAIN GATE (pieczec integralnosci rekordu)
# ============================================================================
# Wpiecie scripts/run-chain.py w silnik certyfikacji (profil full = pre-push,
# release/genesis). Wczesniej pieczec NIE MIALA KONSUMENTA: nikt jej nie
# weryfikowal, wiec "zapisane" nie znaczylo "nienaruszone".
#
# Semantyka (swiadomie asymetryczna):
#   RUN-CHAIN-01  brak pieczeci  -> WARNING (nikt nie pieczetowal; to nie
#                 manipulacja, nie blokujemy commitow innych agentow).
#   RUN-CHAIN-01  pieczec istnieje, a lancuch PRZERWANY -> FAIL BLOCKING
#                 (zmieniona tresc opieczetowanej linii / usunieta linia /
#                 znikniete zrodlo / uszkodzona linia pieczeci = dowod
#                 manipulacji na magazynie rekordu).
#   RUN-CHAIN-02  pieczec nieaktualna (nowe linie nieopieczetowane)
#                 -> WARNING (zaleglosc pieczetowania, nie manipulacja).
#
# Uruchomienie: bash tools/verify/run-chain-check.sh
# Env: AIGON_RUN_CHAIN (sciezka pieczeci), AIGON_RUN_CHAIN_SOURCES (zrodla).
# ============================================================================
set -u

# shellcheck source=core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say ""
say "=== GATE RUN-CHAIN (pieczec integralnosci rekordu, append-only) ==="

CHAIN="${AIGON_RUN_CHAIN:-$ROOT/artifacts/chain/chain.ndjson}"
SEALER="$ROOT/scripts/run-chain.py"

if [ ! -f "$SEALER" ]; then
  fail "RUN-CHAIN-01 weryfikator pieczeci istnieje" BLOCKING \
    "Brak $SEALER — pieczec bez weryfikatora jest dekoracja."
  evidence_record "verify:run-chain-check:FAIL" "verify" "run-chain-check.sh"
  verify_module_exit
fi

if [ ! -f "$CHAIN" ]; then
  warn "RUN-CHAIN-01 pieczec istnieje" \
    "Brak pieczeci $CHAIN — nikt nie pieczetowal (python3 scripts/run-chain.py seal). WARNING, nie blokada."
  evidence_record "verify:run-chain-check:WARN-BRAK-PIECZECI" "verify" "run-chain-check.sh"
  verify_module_exit
fi

SRC_ARGS=()
if [ -n "${AIGON_RUN_CHAIN_SOURCES:-}" ]; then
  for src in ${AIGON_RUN_CHAIN_SOURCES}; do SRC_ARGS+=(--source "$src"); done
fi

ERRF="$(mktemp)"
trap 'rm -f "$ERRF"' EXIT
OUT="$(timeout 60 python3 "$SEALER" verify --json --chain "$CHAIN" \
  ${SRC_ARGS[@]+"${SRC_ARGS[@]}"} 2>"$ERRF")"

PARSED="$(printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
probs = d.get("problems") or []
conf = [k for k in ("chain_break", "line_mismatch", "missing_line",
                    "missing_source", "chain_corrupt") if k in
        {p.get("kind") for p in probs}]
print("VERDICT=%s" % d.get("verdict", "FAIL"))
print("TAMPER=%s" % ("1" if d.get("tamper") else "0"))
print("UNSEALED=%d" % int(d.get("unsealed") or 0))
print("SEALED=%d" % int(d.get("sealed_lines") or 0))
print("INSTORE=%d" % int(d.get("lines_in_store") or 0))
print("CLASSES=%s" % (",".join(conf) or "-"))
' 2>/dev/null)"
PARSED_RC=$?

if [ "$PARSED_RC" -ne 0 ] || [ -z "$PARSED" ]; then
  warn "RUN-CHAIN-01 wynik weryfikacji czytelny" \
    "Nie umiem odczytac wyniku verify (pieczec NIEZWERYFIKOWANA): $(printf '%s' "$OUT" | tail -1 | cut -c1-160)"
  evidence_record "verify:run-chain-check:WARN-PARSE" "verify" "run-chain-check.sh"
  verify_module_exit
fi
eval "$PARSED"

if [ "${VERDICT:-FAIL}" = "PASS" ]; then
  pass "RUN-CHAIN-01 lancuch integralny" BLOCKING \
    "Pieczec zgodna z magazynem ($SEALED == $INSTORE linii)."
elif [ "${TAMPER:-0}" = "1" ]; then
  fail "RUN-CHAIN-01 lancuch integralny" BLOCKING \
    "PRZERWANIE LANCUCHA (klasy: $CLASSES) — magazyn rekordu rozni sie od pieczeci. To dowod manipulacji."
  printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for p in (d.get("problems") or [])[:5]:
    print("       ! [%s] %s: %s" % (p.get("kind"), p.get("source"), p.get("detail")))
' 2>/dev/null
else
  warn "RUN-CHAIN-02 pieczec aktualna" \
    "Pieczec istnieje, ale $UNSEALED linii magazynu nie jest opieczetowanych (python3 scripts/run-chain.py seal)."
fi

if verify_blocked; then
  evidence_record "verify:run-chain-check:FAIL" "verify" "run-chain-check.sh"
else
  evidence_record "verify:run-chain-check:PASS" "verify" "run-chain-check.sh"
fi

verify_module_exit
