#!/usr/bin/env bash
# ============================================================================
# obs-telemetry-check.sh — OBS-TELEMETRY GATE (GATE-088)
# ============================================================================
# Universal Project Template — Repository Certification Engine
#
# GATE-088 OBS-TELEMETRY: twardy validator strumienia OpenTelemetry/OTel.
# Koniec z "observability manifest istnieje, a telemetria nie leci".
# Ten gate sprawdza, że usługi stacku są REALNIE zinstrumentowane:
#   OTLP-01  Każdy docker-compose service ma AIGON_OTLP_ENDPOINT (KANON —
#            czyta go aigon-runtime/src/lib.rs:3655 przez
#            aigon-adapters/observability/otlp.rs) lub OTEL_EXPORTER_OTLP_
#            ENDPOINT / OTEL_* (standard OTel) — nie da się wdrożyć usługi
#            bez telemetrii.
#   OTLP-02  Endpoint wskazuje na działający kolektor OTLP (nie domyslny
#            localhost:4317/4318, który nic nie slucha na hoście mesh).
#   OTLP-03  Endpoint jest REACHABLE (port nasluchuje) — fail-closed.
#   OTLP-04  usluga ma healthcheck (bez = mozna byc martwym a 'healthy').
#
# NO FALSE GREEN: brak telemetrii w compose = FAIL BLOCKING (nie skip).
# ============================================================================
set -u

# shellcheck source=core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-088 OBS-TELEMETRY (OTel instrumentation gate) ==="

# ── Kolektory OTLP znane na meshu (SSOT: /srv/aigon/docker-compose.yml otel-collector) ──
# :44318 = OTLP HTTP eksporter (kolektor aigon-observability-otel-collector).
OTLP_HTTP_HOST="${OTLP_HTTP_HOST:-127.0.0.1:44318}"

# ── Zbior wszystkich compose w repo ─────────────────────────────────────────
# (pomijamy node_modules, dist, .next, .quarantine*, gen-*, template*, reports)
#
# POMIJANE ŚWIADOMIE — NIE SĄ WDROŻENIAMI (2026-09-30, dlug telemetrii OTLP):
#   */out/*         — katalog ARTEFAKTÓW BUILD (`.gitignore:299` = `out/`), nie
#                     źródło. Pliki tam są generowane przy budowie, więc
#                     instrumentowanie ich to fikcja (zmiana przepada).
#   */z-archiwum*/* — ARCHIWUM odzyskane z QNAP-a (wojsko/z-archiwum-qnap-*),
#                     nie jest uruchamiane na meshu — wymóg telemetrii go nie
#                     dotyczy. Gate FAIL-ował na tym, czego nie da się wdrożyć.
COMPOSES="$(find . -maxdepth 3 -type f \( -name 'docker-compose*.yml' -o -name 'compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'compose*.yaml' \) -not -path '*/node_modules/*' -not -path '*/dist/*' -not -path '*/.next/*' -not -path '*/.quarantine*/*' -not -path '*/template*/*' -not -path '*/reports/*' -not -path '*/out/*' -not -path '*/z-archiwum*/*' 2>/dev/null)"

if [ -z "$COMPOSES" ]; then
  fail "OTLP-04 stack compose istnieje" BLOCKING "Brak jakiegokolwiek docker-compose*.yml — nie mozna zweryfikowac telemetrii."
  verify_module_exit
fi

GATE_FAILED=0

for compose in $COMPOSES; do
  # Pomin wygenerowane / testy / template / archiwa
  case "$compose" in
    *gen-*|*template*|*/tests/*|*/test/*|*/reports/*|*.otel-backup*) continue ;;
  esac
  # Pomentarze: tylko jesli definiuje jakies uslugi (nie czysty extends)
  if ! grep -qE '^[[:space:]]{2}[A-Za-z0-9_-]+:' "$compose" 2>/dev/null; then
    continue
  fi
  say ""
  say "── $compose"

  # OTLP-01/02: KANON = AIGON_OTLP_ENDPOINT (aigon-runtime), OTEL_* = standard OTel
  OTEL_COUNT="$(( $(grep -cE 'AIGON_OTLP_ENDPOINT' "$compose" 2>/dev/null) + $(grep -cE 'OTEL_[A-Z_]+' "$compose" 2>/dev/null) ))"
  # NAPRAWA 2026-09-30: (a) ekstraktor nie rozumial formy `${VAR:-url}` (stad
  # falszywe WARN OTLP-02 dla poprawnych wpisow); (b) lapal WZORZEC Z KOMENTARZA
  # (przypadkowy PASS dla docker-compose.yml, ktorego realny wpis jest w komentarzu).
  # Teraz: pomijamy linie komentarza i dopuszczamy `${VAR:-` przed URL.
  OTLP_ENDPOINT="$(grep -v '^[[:space:]]*#' "$compose" 2>/dev/null | grep -hoE '(AIGON_OTLP_ENDPOINT|OTEL_EXPORTER_OTLP_ENDPOINT)[=: ]+(\$\{[A-Z_]+:-)?http[s]?://[a-zA-Z0-9._:/@-]+' | head -1 | sed -E 's#.*://##; s#/$##')"

  if [ "$OTEL_COUNT" -eq 0 ]; then
    fail "OTLP-01 $compose ma telemetrie" BLOCKING "Brak AIGON_OTLP_ENDPOINT / OTEL_* w compose — uslugi niezinstrumentowane."
    GATE_FAILED=1
  else
    pass "OTLP-01 $compose ma telemetrie" BLOCKING "$OTEL_COUNT wystapien (AIGON_OTLP_ENDPOINT|OTEL_)."
  fi

  if [ -n "$OTLP_ENDPOINT" ]; then
    # Normalizacja endpointu (odrzuc prefix http://, https://, scheme)
    ENDPOINT_HOST="$(echo "$OTLP_ENDPOINT" | sed -E 's#^[a-z]+://##; s#/$##')"
    # BUG 2026-09-27: wzorzec '431[78]' lapal ':44318' (bo zawiera "4318")
    # -> FALSZYWY WARN na KAZDYM poprawnym endpoincie kolektora mesh (:44318).
    # Domyslny port OTLP to 4317 (gRPC) / 4318 (HTTP) — dopasowanie MUSI byc
    # do KONCA adresu (:4317$|:4318$) albo do localhost/127.0.0.1 z tym portem,
    # nigdy do dowolnego wystapienia cyfr w dluzszym porcie.
    if echo "$ENDPOINT_HOST" | grep -qE '(:4317|:4318)$|localhost:431[78]$|127\.0\.0\.1:431[78]$'; then
      warn "OTLP-02 $compose endpoint domyslny" "Endpoint ${OTLP_ENDPOINT} to domyslny localhost:431x — prawdopodobnie nie slucha na meshu."
      GATE_FAILED=1
    else
      pass "OTLP-02 $compose endpoint OTLP" BLOCKING "Endpoint ${OTLP_ENDPOINT} (nie domyslny 4317/4318)."
    fi
  else
    warn "OTLP-02 $compose endpoint OTLP" "Telemetria obecna (AIGON_OTLP*|OTEL_*) ale brak ustawionego endpointu kolektora."
    GATE_FAILED=1
  fi

  # OTLP-04: healthcheck per service (tylko przy 'ports:'-publikowanych)
  if grep -qE '^[[:space:]]{2}healthcheck:|healthcheck:' "$compose" 2>/dev/null; then
    pass "OTLP-04 $compose healthcheck" BLOCKING "Compose definiuje healthcheck."
  else
    # healthcheck per-service moze byc indywidualny — sprawdz czy jakikolwiek
    if grep -qE 'healthcheck' "$compose" 2>/dev/null; then
      pass "OTLP-04 $compose healthcheck" BLOCKING "Compose zawiera healthcheck."
    else
      warn "OTLP-04 $compose healthcheck" "Brak healthcheck w compose — uslugi moga byc martwe a raport 'healthy'."
      GATE_FAILED=1
    fi
  fi
done

# ── OTLP-03 (REACHABLE): endpoint OTLP kolektora musi byc LIVE na hoście ────
say ""
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE ":$((${OTLP_HTTP_HOST##*:}))\b"; then
  pass "OTLP-03 kolektor OTLP live" BLOCKING "Kolektor nasluchuje na ${OTLP_HTTP_HOST}."
else
  HOST="${OTLP_HTTP_HOST%%:*}"; PORT="${OTLP_HTTP_HOST##*:}"
  if timeout 3 bash -c "exec 3<>/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
    pass "OTLP-03 kolektor OTLP live" BLOCKING "Kolektor nasluchuje na ${OTLP_HTTP_HOST} (tcp)."
  else
    warn "OTLP-03 kolektor OTLP live" "Kolektor nie odpowiada na ${OTLP_HTTP_HOST} — sprawdz aigon-observability-otel-collector."
    GATE_FAILED=1
  fi
fi

if [ "$GATE_FAILED" -eq 0 ]; then
  pass "OBS-TELEMETRY calosc" BLOCKING "Wszystkie kompozy zinstrumentowane (AIGON_OTLP_ENDPOINT|OTEL_), endpoint OTLP ustawiony, kolektor live."
fi

# ── Evidence ────────────────────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:obs-telemetry-check:FAIL" "verify" "obs-telemetry-check.sh"
else
  evidence_record "verify:obs-telemetry-check:PASS" "verify" "obs-telemetry-check.sh"
fi

verify_module_exit
