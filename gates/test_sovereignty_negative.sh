#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/test_sovereignty_negative.sh — TEST NEGATYWNY dla gate'a
#  sovereignty-fitness (LAW-O1/O2).
#
#  KANON REPO: „test negatywny obowiazkowy — bramka bez testu negatywnego
#  nie istnieje". Ten test WSTRZYKUJE symulowaną ODMOWĘ wobec Suwerena i
#  sprawdza, że bramka ją ZŁAPIE (exit 1 = FAIL).
#
#  METODA: buduje katalog-fikcję z plikiem .py zawierającym TWARDĄ ODMOWĘ
#  (blokada rozkazu Suwerena, zwrócona na zewnątrz, bez żadnego mechanizmu
#  override) i kieruje bramkę na TĘ fikcję przez AIGON_SOVEREIGN_ROOTS.
#  Jeśli bramka zwróci exit 1 i wypisze ten plik jako kandydat-P0 → PASS
#  testu (bramka ŻYJE). Jeśli exit != 1 → test się NIE UDAŁ (bramka nie
#  łapie odmowy = nie istnieje).
#
#  BEZ SIECI, BEZ CARGO, BEZ DOCKERA — wyłącznie fixture katalogi.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sovereignty-fitness.sh"
[ -x "$GATE" ] || [ -f "$GATE" ] || { echo "brak gate: $GATE"; exit 2; }

TMP="$(mktemp -d /tmp/sovereignty-neg.XXXXXX)"
PASS=0; FAILED=0
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Fixture A: TWARDA odmowa wobec Suwerena (bez obejścia) ─────────────
# Deklaratywna symulacja — miejsce, które system POTRAFI wykorzystać do
# zablokowania rozkazu Suwerena. To jest to, co bramka MUSI wykryć.
FIX_A="$TMP/injected_refusal"
mkdir -p "$FIX_A"
cat > "$FIX_A/decision.py" << 'EOF'
"""Stub scenariusza: podsystem potrafi ODRZUCIĆ polecenie Suwerena.
Jest to P0 dla LAW-O2, jeżeli zostanie osiągnięte w runtime bez obejścia."""
from typing import Any


def execute_command_for_sovereign(action: str, *, authenticated: bool) -> Any:
    if not authenticated:
        # twarda odmowa (zakazana wg LAW-O2)
        raise PermissionError(
            "denied: request access denied for unauthenticated caller"
        )
    if action == "delete_prod":
        # odmowa mimo poprawnej autoryzacji — KANDYDAT P0
        return {"error": "forbidden", "reason": "cannot comply: destructive op"}
    return {"ok": True, "action": action}
EOF

# ── Fixture B: plik ZGODNY (brak odmowy) — kontrola, że bramka NIE
# ── pałuje czystego kodu (bez tego test strzelałby do własnych nóg). ───
FIX_B="$TMP/clean"
mkdir -p "$FIX_B"
cat > "$FIX_B/clean.py" << 'EOF'
def ping() -> str:
    return "pong"


def add(a: int, b: int) -> int:
    return a + b
EOF

# ── CASE 1: bramka MUSI złapać wstrzykniętą odmowę → exit 1 (FAIL) ─────
OUT_A=$(AIGON_SOVEREIGN_ROOTS="$FIX_A" bash "$GATE" 2>&1); RC_A=$?
if [ "$RC_A" = "1" ]; then
  HIT=$(printf '%s\n' "$OUT_A" | grep -c "decision.py" || true)
  if [ "$HIT" -ge 1 ]; then
    echo "PASS: 1. bramka ZŁAPAŁA wstrzykniętą odmowę (exit=$RC_A, {$HIT} m. decision.py)"
    PASS=$((PASS+1))
  else
    echo "FAIL: 1. exit=1 ale brak wzmianki o decision.py w raporcie"
    FAILED=$((FAILED+1))
  fi
else
  echo "FAIL: 1. bramka NIE złapała odmowy (chciano exit=1, jest exit=$RC_A)"
  printf '%s\n' "$OUT_A" | tail -5
  FAILED=$((FAILED+1))
fi

# ── CASE 2: czysty kod → bramka NIE może FAIL z powodu braku odmowy ────
# (czysty plik nie ma trafień — może zwrócić PASS(0) lub WARN(2), byle nie
#  FAIL z powodu tego pliku)
OUT_B=$(AIGON_SOVEREIGN_ROOTS="$FIX_B" bash "$GATE" 2>&1); RC_B=$?
if [ "$RC_B" != "1" ]; then
  echo "PASS: 2. czysty kod nie daje FAIL (exit=$RC_B — brak odmowy)"
  PASS=$((PASS+1))
else
  echo "FAIL: 2. czysty kod dostał FAIL (exit=$RC_B) — fałszywy pozytyw"
  printf '%s\n' "$OUT_B" | tail -8
  FAILED=$((FAILED+1))
fi

# ── CASE 3: BRAK skanowanych korzeni → exit 2 (ERROR), nie FAIL ────────
OUT_C=$(AIGON_SOVEREIGN_ROOTS="$TMP/__brak_dir__" bash "$GATE" 2>&1); RC_C=$?
if [ "$RC_C" = "2" ]; then
  echo "PASS: 3. brak korzeni → exit 2 (ERROR srodowiska, nie FAIL)"
  PASS=$((PASS+1))
else
  echo "FAIL: 3. brak korzeni — chciano exit=2, jest exit=$RC_C"
  printf '%s\n' "$OUT_C" | tail -5
  FAILED=$((FAILED+1))
fi

# ── Podsumowanie ───────────────────────────────────────────────────────
echo "────────────────────────────────────────────"
echo "WYNIK: $PASS pass, $FAILED fail"
[ "$FAILED" -eq 0 ] || exit 1
exit 0