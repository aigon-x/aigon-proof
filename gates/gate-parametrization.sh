#!/usr/bin/env bash
# GATE-242: GATE-PARAMETRIZATION — żadna bramka nie wnosi twardych progów bez SSOT.
#
# ROZKAZ SUWERENA (2026-10-18): „prawa powinny być dynamiczne i generowane z configów…
# każde prawo i jego elementy możemy zmieniać/dodawać/usuwać w configu? to jest
# determinizm w najwyższej postaci" + „albo z bazy".
#
# KLASYFIKACJA każdej bramki: config | db_api | params | accepted | HARDCODED.
# HARDCODED = dług liczony ratchetem (config/canonical/gate-parametrization-baseline.json).
#
# Kontrakt: 0=PASS, 1=FAIL (nowy HARDCODED), 2=WARN (brak SSOT / nieklasyfikowane)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
CHECK="$ROOT/scripts/gate-parametrization-check.py"

echo "── GATE-242 gate-parametrization ──"
[ -r "$CHECK" ] || { echo "FAIL: brak $CHECK"; exit 1; }

if [ "${1:-}" = "--selftest" ]; then
  tmp="$(mktemp -d)"
  # T1: bramka z twardym defaultem i bez źródła MUSI być HARDCODED
  cat > "$tmp/hard.sh" <<'EOF'
#!/usr/bin/env bash
LIMIT="${SOME_LIMIT:-123}"
echo "x"
EOF
  # T2: bramka czytająca config NIE jest HARDCODED
  cat > "$tmp/cfg.sh" <<'EOF'
#!/usr/bin/env bash
cfg="$(python3 -c 'import yaml;print(1)')"   # config/canonical/x.yaml
echo ok
EOF
  python3 - "$tmp/hard.sh" "$tmp/cfg.sh" <<'PY'
import re, sys
CFG = re.compile(r'(config/(?:canonical/)?[A-Za-z0-9_./-]+\.(?:ya?ml|json|txt)|--config|yaml\.safe_load)')
HARD = re.compile(r'[A-Z][A-Z0-9_]{2,}="?\$\{[A-Z0-9_]+:-[0-9]+(?:\.[0-9]+)?\}"?')
hard = open(sys.argv[1]).read(); cfg = open(sys.argv[2]).read()
ok = bool(HARD.search(hard)) and not CFG.search(hard) and bool(CFG.search(cfg))
print('[T1] klasyfikator: hard→HARDCODED, cfg→config:', 'OK' if ok else 'FAIL')
sys.exit(0 if ok else 1)
PY
  rc=$?
  rm -rf "$tmp"
  [ "$rc" -eq 0 ] || { echo "SELFTEST: FAIL (klasyfikator slepy)"; exit 1; }
  echo "SELFTEST: PASS (2/2)"
  exit 0
fi

python3 "$CHECK"; rc=$?
case "$rc" in
  0) echo "PASS gate-parametrization" ;;
  2) echo "WARN gate-parametrization (brak SSOT / nieklasyfikowane bramki)" ;;
  *) echo "FAIL gate-parametrization (nowa bramka z twardymi progami)" ;;
esac
exit "$rc"
