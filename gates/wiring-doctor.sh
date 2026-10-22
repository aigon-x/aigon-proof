#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/wiring-doctor.sh — BRAMKA: spięcie observability AIGON-X
#
#  Kanon bramek AIGON: exit 0=PASS, 1=FAIL, 2=env/brak pomiaru.
#  Realizuje MASTER WIRING CHECKLIST pkt 12 przez scripts/wiring-doctor.py:
#    canary trace(Tempo) + canary metryka(Prometheus) + canary log z trace_id(Loki)
#    + grafana_ds + grafana_correlation + registry + collector.
#
#  Uruchomienie:  bash tools/gates/wiring-doctor.sh
#  Wpięcie:       config/canonical/hooks.yaml + gates.yaml (module: wiring-doctor)
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="${AIGON_PROJECT_ROOT:-/opt/PROD}"
PY="${AIGON_OTEL_PYTHON:-$ROOT/.venv-otel/bin/python}"

if [[ ! -x "$PY" ]]; then
  echo "FAIL(env): brak interpretera OTel: $PY (SKIP — brak pomiaru, LAW-OBS-3)" >&2
  exit 2
fi
if [[ ! -f "$ROOT/scripts/wiring-doctor.py" ]]; then
  echo "FAIL(env): brak $ROOT/scripts/wiring-doctor.py" >&2
  exit 2
fi

"$PY" "$ROOT/scripts/wiring-doctor.py" --json
rc=$?
# kanon: 0=PASS, 1=FAIL, 2=env — przekazujemy 1:1
exit "$rc"
