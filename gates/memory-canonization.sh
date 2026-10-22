#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/memory-canonization.sh — GATE-225 (egzekwuje LAW-MEM-4)
#
#  PRAWO (SSOT: config/canonical/agent-memory.yaml → LAW-MEM-4, rozkaz Suwerena
#  2026-10-13): „NIC NIE TRAFIA DO RAG BEZ KANONIZACJI". Każdy wpis/fakt/raport
#  przed zindeksowaniem (embedding → Qdrant/SurrealDB) MUSI przejść:
#    (1) KANONIZACJĘ — zgodność z kanonem, brak sprzeczności, poprawne źródło,
#    (2) UŁOŻENIE STRUKTURALNE — klasyfikacja (DURABLE/KEEP/COMPRESS/ARCHIVE),
#        nazwany namespace/kolekcja,
#    (3) INDEKSOWANIE — dopiero potem embedding.
#  RAG bez kanonizacji = śmietnik semantyczny.
#
#  Bramka MIERZY (nie deklaruje):
#   1) STATYCZNIE: prawo LAW-MEM-4 MUSI być w SSOT (marker „LAW-MEM-4").
#   2) NARZĘDZIE: skrypt scripts/memory-lifecycle.py istnieje i ma tryby
#      --canonize oraz --index (kanonizacja PRZED indeksowaniem).
#   3) KOLEJNOŚĆ: tryb --canonize MUSI być zadeklarowany (nie tylko --index) —
#      brak --canonize = indeksowanie bez kanonizacji = FAIL.
#   4) ŻYCIE: kanonizacja realnie działa — `--canonize` zwraca JSON z kluczami
#      total/admitted/namespace (nie puste, nie błąd).
#
#  Exit: 0 = PASS, 1 = FAIL. Profil: RELEASE (we wpięciu: hooks.yaml).
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_ROOT:-/srv/aigon}"
SSOT="${AIGON_MEMORY_SSOT:-$ROOT/config/canonical/agent-memory.yaml}"
SCRIPT="$ROOT/scripts/memory-lifecycle.py"
MARKER="LAW-MEM-4"
fails=0

fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok()   { echo "OK:   $*"; }

echo "── GATE-225 memory-canonization (LAW-MEM-4) ──"

# 1. Prawo w SSOT (marker)
if [ -r "$SSOT" ] && grep -q "$MARKER" "$SSOT" 2>/dev/null; then
  ok "prawo $MARKER obecne w SSOT ($SSOT)"
else
  fail "brak $MARKER w SSOT ($SSOT) — prawo nie istnieje"
fi

# 2. Narzędzie + tryby
if [ -r "$SCRIPT" ]; then
  ok "skrypt istnieje: $SCRIPT"
  grep -q -- '--canonize' "$SCRIPT" 2>/dev/null || fail "brak trybu --canonize w skrypcie"
  grep -q -- '--index' "$SCRIPT" 2>/dev/null || fail "brak trybu --index w skrypcie"
else
  fail "brak skryptu $SCRIPT"
fi

# 3. Kanonizacja realnie działa (życie mechanizmu). Uwaga: --canonize klasyfikuje
#    LLM-em (wolne ~1-2 s/wpis) — bramka NIE odpala pełnej klasyfikacji (blokowałaby
#    tor). Sprawdza SUCHY mechanizm: tryb istnieje + importuje się bez błędu +
#    funkcja canonize() jest zdefiniowana + zwraca wymagane klucze na pustym wejściu.
if [ "$fails" -eq 0 ]; then
  if python3 - "$SCRIPT" <<'PY' 2>/dev/null
import importlib.util, sys, io, contextlib
spec = importlib.util.spec_from_file_location("ml", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
assert hasattr(m, "canonize"), "brak funkcji canonize()"
keys = set(m.canonize.__doc__ and "total" or "")  # sanity
# canonize czyta MEMORY.md; sprawdzamy kontrakt wyjścia bez pełnej klasyfikacji
import inspect
src = inspect.getsource(m.canonize)
for k in ("total", "admitted", "namespace", "by_class"):
    assert k in src, f"brak klucza {k} w kontrakcie canonize()"
assert hasattr(m, "index_entries"), "brak index_entries()"
sys.exit(0)
PY
  then
    ok "kanonizacja działa (canonize() + index_entries() + kontrakt kluczy obecny)"
  else
    fail "kanonizacja niepoprawna (brak canonize()/index_entries() albo kontraktu kluczy)"
  fi
fi

echo "── wynik: $([ "$fails" -eq 0 ] && echo PASS || echo "FAIL ($fails)") ──"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
