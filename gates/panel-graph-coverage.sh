#!/usr/bin/env bash
# GATE-244: PANEL-GRAPH-COVERAGE — każda rola z panelu MA instrument w grafie.
#
# ROZKAZ SUWERENA 2026-10-18: „zlinkuj to wszystko na strzał za pomocą mesha i swarma".
# Panel ról jest bezużyteczny, jeśli role nie mają krawędzi do bramek/skilli/praw —
# wtedy są opisem, nie sterowaniem.
#
# Sprawdza: każda rola bez `no_instrument` ma ≥1 krawędź role_*; każde prawo
# z law_owners ma węzeł w grafie. Rola z jawnym `no_instrument` = zadeklarowany dług.
# Kontrakt: 0=PASS, 1=FAIL, 2=WARN (brak panelu/grafu)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
LINK="$ROOT/scripts/panel-graph-link.py"
PANEL="$ROOT/config/canonical/expert-panel.yaml"

echo "── GATE-244 panel-graph-coverage ──"
[ -r "$LINK" ] || { echo "FAIL: brak $LINK"; exit 1; }
[ -r "$PANEL" ] || { echo "WARN: brak expert-panel.yaml"; exit 2; }

if [ "${1:-}" = "--selftest" ]; then
  python3 "$LINK" --check >/dev/null 2>&1; rc_real=$?
  tmp="$(mktemp -d)"
  python3 - "$PANEL" "$tmp/p.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
d['roles'] = (d.get('roles') or []) + [
    {'slug': 'selftest-orphan', 'artifact': 'x', 'metric': 'y',
     'patterns': ['nieistniejacy-wzorzec-xyz']}]
yaml.safe_dump(d, open(sys.argv[2], 'w'), allow_unicode=True, sort_keys=False)
PY
  AIGON_PANEL_FILE="$tmp/p.yaml" python3 "$LINK" --check >/dev/null 2>&1; rc_orphan=$?
  rm -rf "$tmp"
  echo "[T1] realny panel → rc=$rc_real (oczekiwane 0)"
  echo "[T2] wstrzyknięta rola-sierota → rc=$rc_orphan (oczekiwane 1)"
  if [ "$rc_real" -eq 0 ] && [ "$rc_orphan" -eq 1 ]; then
    echo "SELFTEST: PASS (2/2)"; exit 0
  fi
  echo "SELFTEST: FAIL (bramka ślepa)"; exit 1
fi

python3 "$LINK" --check; rc=$?
case "$rc" in
  0) echo "PASS panel-graph-coverage" ;;
  *) echo "FAIL panel-graph-coverage (rola bez instrumentu albo prawo bez węzła)" ;;
esac
exit "$rc"
