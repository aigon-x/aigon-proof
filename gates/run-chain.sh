#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/run-chain.sh — gate `run-chain` (hook-runner: pre-push)
#
#  Wpiecie pieczeci integralnosci rekordu (scripts/run-chain.py) w bramke
#  pre-push. Wczesniej skrypt pieczeci ISTNIAL, ale nie mial ZADNEGO
#  konsumenta (0 wystapien w cronie, bramkach i hookach) — "zapisane"
#  nie znaczylo "nienaruszone", bo nikt nigdy nie weryfikowal lancucha.
#
#  Trzy wyniki (kontrakt hook-runner.sh: 0 = PASS, 2 = WARN, 1 = FAIL):
#    0 PASS — pieczec istnieje i lancuch sie zgadza (linie == magazyn).
#    2 WARN — NIKT NIE PIECZETOWAL (brak pliku pieczeci) ALBO pieczec jest
#             nieaktualna (w magazynie sa linie jeszcze nieopieczetowane).
#             To zaleglosc pieczetowania, NIE dowod manipulacji — nie blokuje.
#    1 FAIL — pieczec istnieje, a lancuch jest PRZERWANY: zmieniona tresc
#             opieczetowanej linii, usunieta linia, znikniete zrodlo albo
#             uszkodzona linia pieczeci. To realny dowod manipulacji.
#
#  Env: AIGON_RUN_CHAIN (sciezka pieczeci), AIGON_RUN_CHAIN_TIMEOUT (dom. 60s).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHAIN="${AIGON_RUN_CHAIN:-$ROOT/artifacts/chain/chain.ndjson}"
# Limit fitness = 60s. Verify 6 MB łańcucha trwa ~5s; 25s to zapas, a twardy
# sufit 45s gwarantuje, że bramka NIGDY nie przekroczy limitu (nawet gdy env
# poda więcej). Wcześniej domyślne 60s = bramka dokładnie na granicy timeoutu.
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/gate-params.sh"
TIMEOUT="$(gp GATE-163 run_chain_timeout_s 25)"
(( TIMEOUT > 45 )) && TIMEOUT=45
SEALER="$ROOT/scripts/run-chain.py"

if [ ! -f "$SEALER" ]; then
  echo "run-chain: WARN — brak $SEALER (nie ma czym weryfikowac)"
  exit 2
fi
if [ ! -f "$CHAIN" ]; then
  echo "run-chain: WARN — brak pieczeci $CHAIN (nikt nie pieczetowal: python3 scripts/run-chain.py seal)"
  exit 2
fi

# Zrodla magazynu: domyslnie rr.store_paths() (kanoniczny dziennik przebiegow).
# AIGON_RUN_CHAIN_SOURCES (spacja) pozwala wskazac inne pliki — uzywane przez
# testy bramki i przez wywolania per-node.
SRC_ARGS=()
if [ -n "${AIGON_RUN_CHAIN_SOURCES:-}" ]; then
  for src in ${AIGON_RUN_CHAIN_SOURCES}; do SRC_ARGS+=(--source "$src"); done
fi

ERRF="$(mktemp)"
trap 'rm -f "$ERRF"' EXIT
OUT="$(cd "$ROOT" && timeout "$TIMEOUT" python3 scripts/run-chain.py verify --json \
  --chain "$CHAIN" ${SRC_ARGS[@]+"${SRC_ARGS[@]}"} 2>"$ERRF")"

# Parsowanie wyniku — WYLACZNIE z JSON-a verify (zero zgadywania po tekście).
PARSED="$(printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
probs = d.get("problems") or []
first = probs[0].get("kind", "-") if probs else "-"
conf = [k for k in ("chain_break", "line_mismatch", "missing_line",
                    "missing_source", "chain_corrupt") if k in
        {p.get("kind") for p in probs}]
print("VERDICT=%s" % d.get("verdict", "FAIL"))
print("TAMPER=%s" % ("1" if d.get("tamper") else "0"))
print("UNSEALED=%d" % int(d.get("unsealed") or 0))
print("SEALED=%d" % int(d.get("sealed_lines") or 0))
print("INSTORE=%d" % int(d.get("lines_in_store") or 0))
print("CLASSES=%s" % (",".join(conf) or first))
' 2>/dev/null)"
PARSED_RC=$?

if [ "$PARSED_RC" -ne 0 ] || [ -z "$PARSED" ]; then
  echo "run-chain: WARN — nie umiem odczytac wyniku verify (pieczec NIEZWERYFIKOWANA)"
  [ -s "$ERRF" ] && sed 's/^/  /' "$ERRF" | head -5
  echo "  surowe wyjscie: $(printf '%s' "$OUT" | tail -1 | cut -c1-200)"
  exit 2
fi
eval "$PARSED"

if [ "${VERDICT:-FAIL}" = "PASS" ]; then
  echo "run-chain: PASS — pieczec zgodna ($SEALED linii pieczeci == $INSTORE linii magazynu)"
  exit 0
fi

if [ "${TAMPER:-0}" = "1" ]; then
  echo "run-chain: FAIL — LANCUCH PRZERWANY ($CLASSES): magazyn rozni sie od pieczeci"
  printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for p in (d.get("problems") or [])[:5]:
    print("  ! [%s] %s: %s" % (p.get("kind"), p.get("source"), p.get("detail")))
' 2>/dev/null
  exit 1
fi

echo "run-chain: WARN — pieczec istnieje, ale $UNSEALED linii magazynu nie jest opieczetowanych (uruchom: python3 scripts/run-chain.py seal)"
exit 2
