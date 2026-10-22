#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/promtool-rules-test.sh — gate promtool-rules-test
#  (trigger: cyclic:hourly)
#
#  PO CO: klasa defektu „REGUŁA ALERTOWA, KTÓRA NIE MOŻE SIĘ ZAPALIĆ".
#  Zmierzone 2026-09-23 (audyt fałszywego zielonego w samo-naprawie) dwa
#  realne przypadki w tym repo:
#    1. `AlertAutomationExecutingNothing` miała wyrażenie
#       `...{result="rejected"} > 0 and increase(...{result="executed"}) == 0`.
#       Operator `and` w PromQL dopasowuje ZBIORY ETYKIET, a `result="rejected"`
#       ≠ `result="executed"`, więc wynik był ZAWSZE PUSTY — reguła nie mogła
#       zapłonąć przy żadnych danych.
#    2. Licznik `executed` był bity PRZED akcją, więc „sukces" raportowano, gdy
#       nic nie naprawiono (65 prób / 65 błędów / 0 napraw, detektor milczał).
#  Szerzej: reguła na nieistniejącą metrykę, `and`/`or` między rozłącznymi
#  zbiorami, próg nieosiągalny albo permanentny, `for:` dłuższy niż incydent.
#  W repo nie było ŻADNEGO automatu łapiącego tę klasę — promtool `test rules`
#  to jedyne narzędzie, które widzi wynik wyrażenia na danych, a nie jego
#  składnię. Ten gate jest jego triggerem.
#
#  CO ROBI:
#    1. plik testów MUSI istnieć i MUSI deklarować rule_files
#       `/etc/prometheus/rules.yml` (ścieżka bind-mountu w kontenerze).
#       Test na KOPII reguł byłby fałszywą bramką — dlatego to twardy warunek.
#    2. sha256 reguł w repo == sha256 `/etc/prometheus/rules.yml` w kontenerze
#       (inaczej test mierzy inny plik niż ten, który jest w repo — WARN).
#    3. `promtool test rules` w kontenerze Prometheusa: promtool NIE ma na
#       hoście, a kontener nie widzi plików spoza bind-mountów, więc obie
#       obowiązkowe suite (ogólna + LIVE) idą przez stdin. Każdy test ma
#       limit 60 s; żadnych plików ani kasowania w kontenerze.
#
#  KONTRAKT (hook-runner.sh): exit 0 = PASS, 1 = FAIL (reguła nie może się
#  zapalić / testy nie przechodzą), 3 = WARN — brak promtoola, brak kontenera
#  albo brak dostępu do dockera. Brak NARZĘDZIA != awaria reguł, więc to nie
#  FAIL; ale też nie cichy PASS (fałszywy zielony).
#  UWAGA (zmierzone): scripts/hook-runner.sh mapuje 0→PASS, 2→WARN,
#  wszystko inne → FAIL, więc w triggerze cyclic:hourly ten WARN zostanie
#  zaraportowany jako FAIL. Trigger ma `block_on_fail: false`, więc nic nie
#  blokuje. Kod WARN można przełączyć na 2 bez edycji skryptu:
#      AIGON_PROMTOOL_WARN_RC=2 bash scripts/hook-runner.sh cyclic:hourly
#
#  Zmienne (testy / inne środowiska):
#    AIGON_PROMTOOL_TEST_FILE          plik testów (default: repo)
#    AIGON_PROMTOOL_LIVE_TEST_FILE     obowiązkowy plik testów LIVE
#    AIGON_PROMTOOL_CONTAINER          kontener z promtoolem
#    AIGON_PROMTOOL_RULES_IN_CONTAINER ścieżka reguł w kontenerze
#    AIGON_PROMTOOL_HOST_RULES         ścieżka reguł w repo (do porównania sha)
#    AIGON_PROMTOOL_WARN_RC            kod WARN (default 3)
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="promtool-rules-test"

TEST_FILE="${AIGON_PROMTOOL_TEST_FILE:-$ROOT/observability/prometheus/tests/rules.test.yaml}"
LIVE_TEST_FILE="${AIGON_PROMTOOL_LIVE_TEST_FILE:-$ROOT/observability/prometheus/tests/live-ha.test.yaml}"
CONTAINER="${AIGON_PROMTOOL_CONTAINER:-aigon-observability-prometheus}"
RULES_IN_CONTAINER="${AIGON_PROMTOOL_RULES_IN_CONTAINER:-/etc/prometheus/rules.yml}"
HOST_RULES="${AIGON_PROMTOOL_HOST_RULES:-$ROOT/observability/prometheus/rules.yml}"
WARN_RC="${AIGON_PROMTOOL_WARN_RC:-3}"

warn() { echo "WARN $GATE: $1"; exit "$WARN_RC"; }
fail() { echo "FAIL $GATE: $1"; exit 1; }

# ── 1. Wejście: plik testów i jego kontrakt ────────────────────────────
[ -f "$TEST_FILE" ] || fail "brak pliku testów reguł ($TEST_FILE) — bramka nie ma czego uruchomić, a brak testu tej klasy to dokładnie ten dług, który ta bramka zamyka"

if ! grep -qE "^[[:space:]]*-[[:space:]]*/etc/prometheus/rules\.yml[[:space:]]*$" "$TEST_FILE"; then
  fail "plik testów ($TEST_FILE) nie deklaruje rule_files: /etc/prometheus/rules.yml — test na kopii reguł jest fałszywą bramką (mierzy inny plik niż ten, który ładuje Prometheus)"
fi

# ── 2. Środowisko: docker + kontener + promtool (brak narzędzia != FAIL) ─
command -v docker >/dev/null 2>&1 \
  || warn "docker niedostępny — nie mogę uruchomić promtool test rules (brak narzędzia != awaria reguł)"

docker inspect "$CONTAINER" >/dev/null 2>&1 \
  || warn "kontener $CONTAINER nie istnieje/niedostępny — promtool żyje tylko w nim (brak narzędzia != awaria reguł)"

docker exec "$CONTAINER" sh -c 'command -v promtool >/dev/null 2>&1' \
  || warn "brak promtool w kontenerze $CONTAINER (brak narzędzia != awaria reguł)"

docker exec "$CONTAINER" test -f "$RULES_IN_CONTAINER" \
  || warn "kontener $CONTAINER nie widzi $RULES_IN_CONTAINER (brak wejścia != awaria reguł)"

# ── 3. Reguły w kontenerze == reguły w repo (inaczej test mierzy inny plik) ─
if [ -f "$HOST_RULES" ]; then
  H_HOST="$(sha256sum "$HOST_RULES" 2>/dev/null | awk '{print $1}')"
  H_CTR="$(docker exec "$CONTAINER" sha256sum "$RULES_IN_CONTAINER" 2>/dev/null | awk '{print $1}')"
  if [ -n "$H_HOST" ] && [ -n "$H_CTR" ] && [ "$H_HOST" != "$H_CTR" ]; then
    warn "reguły w kontenerze różnią się od repo (repo=$H_HOST kontener=$H_CTR) — test mierzyłby INNY plik niż $HOST_RULES"
  fi
fi

# ── 4. Uruchomienie testów ─────────────────────────────────────────────
command -v timeout >/dev/null 2>&1 || warn "brak timeout — nie uruchamiam nieograniczonego testu"
# stdin: no shared container files, no cleanup deletion, finite test budget.
OUT="$(timeout --kill-after=2s 60s docker exec -i "$CONTAINER" promtool test rules /dev/stdin < "$TEST_FILE" 2>&1)"
RC=$?

# ── 5. Liczniki (ilu reguł/aserów dotyczy wynik) ───────────────────────
COUNTS="$(python3 - "$TEST_FILE" 2>/dev/null <<'PYEOF'
import sys
try:
    import yaml
except Exception:
    print("grupy=? asercje=?"); raise SystemExit(0)
try:
    d = yaml.safe_load(open(sys.argv[1]))
except Exception:
    print("grupy=? asercje=?"); raise SystemExit(0)
tests = d.get("tests") or []
assertions = sum(len(t.get("alert_rule_test") or []) for t in tests)
print("grupy=%d asercje=%d" % (len(tests), assertions))
PYEOF
)"
[ -n "$COUNTS" ] || COUNTS="grupy=? asercje=?"

if [ "$RC" -ne 0 ]; then
  # Ponumeruj znaleziska: promtool wypisuje je jako "FAILED:" + bloki per alert.
  FINDINGS="$(printf '%s\n' "$OUT" | grep -cE '^ *alertname:' 2>/dev/null || echo 0)"
  printf 'FAIL %s: promtool test rules NIE przeszło (%s, %s niezgodności) — reguła nie zachowuje się jak zadeklarowano (np. NIE MOŻE się zapalić: `and` między rozłącznymi zbiorami, próg nieosiągalny, for dłuższy niż incydent)\n' \
    "$GATE" "$COUNTS" "$FINDINGS"
  printf '%s\n' "$OUT" | grep -E '^FAILED:|^ *name:|^ *alertname:|^ *got:' | head -40
  echo "  pełny zrzut: docker exec $CONTAINER promtool test rules <plik testów>"
  echo "  plik testów: $TEST_FILE"
  exit 1
fi

[ -f "$LIVE_TEST_FILE" ] || fail "brak obowiązkowego testu LIVE ($LIVE_TEST_FILE)"
grep -qE '^[[:space:]]*-[[:space:]]*/etc/prometheus/rules\.yml[[:space:]]*$' "$LIVE_TEST_FILE" \
  || fail "test LIVE nie wskazuje rzeczywistego bind-mount /etc/prometheus/rules.yml"
LIVE_OUT="$(timeout --kill-after=2s 60s docker exec -i "$CONTAINER" promtool test rules /dev/stdin < "$LIVE_TEST_FILE" 2>&1)"
LIVE_RC=$?
if [ "$LIVE_RC" -ne 0 ]; then
  printf '%s\n' "$LIVE_OUT"
  fail "test LIVE nie przeszedł (exit=$LIVE_RC); brak zdrowia nie może być PASS"
fi
echo "PASS $GATE: promtool test rules SUCCESS ($COUNTS) oraz obowiązkowe testy LIVE — bez kopii i plików w kontenerze"
exit 0
