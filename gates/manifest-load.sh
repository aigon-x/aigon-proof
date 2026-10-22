#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/manifest-load.sh — gate manifest-load (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  Brak błędów parsera manifestów w logach runtime (ostatnie 30 min) —
#  wykryłby regresję mesh.yaml/knowledge.yaml (incydent 2026-08-14:
#  "unknown field" cicho wywalał loadery manifestów).
#
#  Kontrakt: exit 0 = PASS (0 błędów), exit 1 = FAIL (>=1 błąd).
#  Zmienne env: AIGON_MANIFEST_CONTAINER (default aigon-core-runtime).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

CONTAINER="${AIGON_MANIFEST_CONTAINER:-aigon-core-runtime}"
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/gate-params.sh"
# Kolejność źródeł (2026-10-19): jawne NADPISANIE env (test wykonalności:
# scripts/tests/test_context_source_gates.py ustawia je, żeby sprawdzić, że
# timeout/niepoprawny budżet dają FAIL) -> SSOT progów gate-params (GATE-242).
# Wcześniej gate czytał WYŁĄCZNIE gate-params, więc test kontraktu (timeout=1
# z `docker logs` śpiącym 3 s → reader_status=124) nie mógł przejść: bramka
# zwracała 0. Zmierzone 2026-10-19: scripts-tests FAIL na tym teście.
LOG_TIMEOUT="${AIGON_MANIFEST_LOG_TIMEOUT_SECONDS:-$(gp GATE-073 manifest_log_timeout_s 30)}"
if ! [[ "$LOG_TIMEOUT" =~ ^[1-9][0-9]{0,2}$ ]] || [ "$LOG_TIMEOUT" -gt 120 ]; then
  echo "manifest-load: FAIL (timeout logów musi wynosić 1..120 s)"
  exit 1
fi

# Preserve the reader status separately: missing containers, daemon failures,
# and timeouts are missing evidence, never proof that manifests loaded.
# Never print raw logs; they may contain secrets, including failure output.
LOGS=$(timeout --kill-after=2s "${LOG_TIMEOUT}s" docker logs "$CONTAINER" --since 30m 2>&1)
READER_STATUS=$?
if [ "$READER_STATUS" -ne 0 ]; then
  unset LOGS
  echo "manifest-load: FAIL (brak dowodu z logów; reader_status=$READER_STATUS)"
  exit 1
fi
BAD=$(printf '%s\n' "$LOGS" | grep -cE 'unknown field|manifest load failed')
PARSER_STATUS=$?
unset LOGS
if [ "$PARSER_STATUS" -gt 1 ]; then
  echo "manifest-load: FAIL (analiza logów nie powiodła się; parser_status=$PARSER_STATUS)"
  exit 1
fi
if [ "$BAD" -eq 0 ]; then
  echo "manifest-load: PASS (manifesty OK)"
  exit 0
fi
echo "manifest-load: FAIL ($BAD błędów manifestu w logach $CONTAINER)"
exit 1
