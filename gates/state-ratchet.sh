#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/state-ratchet.sh — STATE-RATCHET (bramka na regresję stanu)
#
# „Stan systemu nie może się już nigdy zdegradować" (Suweren 2026-09-21).
#
# Pomiar: scripts/state-measure.py (deterministyczny, zero LLM, read-only)
# Baseline: config/canonical/state-baseline.yaml (ratchet.min / ratchet.max)
#
# Bramka FAIL-uje (BLOCKING) gdy:
#   * klucz z ratchet.min SPADŁ poniżej baseline (node zniknął, kernel
#     przestał tickować, reguła zniknęła, replika zniknęła, target padł),
#   * klucz z ratchet.max WZRÓSŁ (martwe reguły, producenci bez reguły),
#   * pomiar w ogóle się nie udał (fail-closed: brak Prometheus = brak dowodu).
#
# Tryby:
#   --strict   pełne porównanie, regresja = FAIL BLOCKING  (profil release/genesis)
#   --warn     szybki pomiar, regresja = WARN (nie blokuje) (profil fast/full)
#   auto       strict gdy rodzic to verify.sh release|genesis, inaczej warn
#   --quick    pomiar tani (pomija Tempo search/sample)
#   --baseline <plik>   inny baseline (testy regresji)
#
# Exit: 0 = brak regresji • 1 = regresja (tylko w trybie strict)
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

MODE="${AIGON_STATE_RATCHET_MODE:-auto}"
BASELINE="config/canonical/state-baseline.yaml"
QUICK=1

while [ $# -gt 0 ]; do
  case "$1" in
    --strict)   MODE=strict; QUICK=0 ;;
    --warn)     MODE=warn ;;
    --quick)    QUICK=1 ;;
    --full)     QUICK=0 ;;
    --baseline) shift; BASELINE="${1:-}" ;;
    *)          : ;;
  esac
  shift
done

if [ "$MODE" = "auto" ]; then
  parent_cmd="$(ps -o args= -p "${PPID:-0}" 2>/dev/null || true)"
  case "$parent_cmd" in
    *release*|*genesis*) MODE=strict; QUICK=0 ;;
    # KANON 2026-09-21 — TU BYŁ BYPASS. Fallback w trybie `auto` ustawiał
    # `warn`, a ponieważ w `auto` strictness zależy od podsłuchania wiersza
    # poleceń RODZICA, a hook-runner podaje trigger typu `cyclic:daily`
    # (bez słowa „release"), dopasowanie NIGDY nie zachodziło → ratchet
    # wołany z hooka nie blokował niczego. Meta-bramka GATE-INTEGRITY-007
    # nazwała to wprost: „1 skryptów z bypass: state-ratchet.sh".
    # Ratchet z bypassem nie jest ratchetem. Tryb nieblokujący zostaje
    # dostępny WYŁĄCZNIE jawnie: `--warn` (albo env), nigdy jako domyślny.
    *)                   MODE=strict; QUICK=0 ;;
  esac
fi

say "=== STATE-RATCHET (tryb: $MODE, baseline: $BASELINE) ==="

# ── SR-001: baseline istnieje ───────────────────────────────
if [ -f "$BASELINE" ]; then
  pass "SR-001 baseline istnieje" BLOCKING "Baseline: $BASELINE."
else
  fail "SR-001 baseline istnieje" BLOCKING \
    "Brak $BASELINE — nie ma do czego porównywać. Ratchet nieaktywny = stan może się degradować niezauważony."
  verify_module_exit
fi

# ── SR-002: pomiar ──────────────────────────────────────────
TMP_JSON="$(mktemp -t state-ratchet.XXXXXX.json)"
TMP_VERDICT="$(mktemp -t state-ratchet.XXXXXX.verdict)"
TMP_ERR="$(mktemp -t state-ratchet.XXXXXX.err)"
trap 'rm -f "$TMP_JSON" "$TMP_VERDICT" "$TMP_ERR"' EXIT

quick_arg=""
[ "$QUICK" = "1" ] && quick_arg="--quick"

# shellcheck disable=SC2086
python3 scripts/state-measure.py --baseline "$BASELINE" $quick_arg --json \
  >"$TMP_JSON" 2>"$TMP_ERR"
src=$?

if [ "$src" -eq 2 ]; then
  fail "SR-002 pomiar stanu wykonany" BLOCKING \
    "POMIAR NIEUDANY (fail-closed) — brak dowodu, że stan się nie zdegradował: $(head -1 "$TMP_ERR" 2>/dev/null)"
  verify_module_exit
elif [ ! -s "$TMP_JSON" ]; then
  fail "SR-002 pomiar stanu wykonany" BLOCKING "Pusty wynik pomiaru (rc=$src)."
  verify_module_exit
fi

pass "SR-002 pomiar stanu wykonany" BLOCKING \
  "state-measure.py rc=$src (tryb $( [ "$QUICK" = 1 ] && echo quick || echo full ))."

# ── SR-003..: porównanie z baseline ─────────────────────────
python3 - "$TMP_JSON" <<'PY' > "$TMP_VERDICT"
import json, sys
d = json.load(open(sys.argv[1]))
c = d.get("comparison") or {}
r = d.get("ratchet") or {}
print("SUM|%d|%d" % (len(r.get("min") or []), len(r.get("max") or [])))
# UWAGA (2026-09-29, rozkaz Suwerena: „pokazywać które, dodaj do bramki"):
# lista regresji MUSI być wypisana wprost, nie tylko jako licznik. Poprzednia
# wersja w trybie fast/full raportowała „Regresje: 7" bez nazw — operator
# (i agent) nie wiedział, CO się zdegradowało, więc nie dało się tego naprawić
# bez ręcznego uruchomienia --strict. Nazwa klucza + wartości przed/po to
# minimum diagnostyczne; sam licznik jest bezużyteczny.
for m in c.get("regressions") or []:
    print("REG|" + m)
for m in c.get("missing") or []:
    print("MISS|" + m)
for m in c.get("improvements") or []:
    print("IMP|" + m)
for m in c.get("warnings") or []:
    print("WRN|" + m)
PY

min_keys=0; max_keys=0
regressions=0; missing=0
while IFS='|' read -r tag a b; do
  case "$tag" in
    SUM)  min_keys="$a"; max_keys="$b" ;;
    REG)
      regressions=$((regressions+1))
      if [ "$MODE" = "strict" ]; then
        fail "SR-003 ratchet: $a" BLOCKING "Regresja stanu wobec baseline ($BASELINE)."
      else
        warn "SR-003 ratchet (nie blokuje w trybie $MODE): $a" \
          "Regresja wobec baseline — wymaga naprawy; brak blokady w profilu fast/full."
      fi
      ;;
    MISS)
      missing=$((missing+1))
      fail "SR-004 baseline spójny: $a" BLOCKING \
        "Baseline odwołuje się do klucza, którego pomiar nie dostarcza — ratchet jest ślepy."
      ;;
    IMP)  info "SR-005 poprawa: $a" ;;
    WRN)  warn "SR-006 zniknął pomiar: $a" "Klucz informacyjny — nie blokuje." ;;
  esac
done < "$TMP_VERDICT"

if [ "$regressions" -eq 0 ] && [ "$missing" -eq 0 ]; then
  pass "SR-007 brak regresji" BLOCKING \
    "Wszystkie $min_keys kluczy ratchet.min i $max_keys kluczy ratchet.max trzymają poziom."
else
  if [ "$MODE" = "strict" ]; then
    fail "SR-007 brak regresji" BLOCKING \
      "Regresje: $regressions, niespójny baseline: $missing — stan się zdegradował."
  else
    warn "SR-007 brak regresji (tryb $MODE)" \
      "Regresje: $regressions, niespójny baseline: $missing — raport, bez blokady."
  fi
fi

verify_module_exit
