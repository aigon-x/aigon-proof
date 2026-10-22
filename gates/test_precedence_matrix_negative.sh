#!/usr/bin/env bash
# test_precedence_matrix_negative.sh — test negatywny law-precedence-matrix.sh.
# Psuje KOPIĘ M2 w mktemp -d; żywy plik nietknięty.
# Każda mutacja MUSI dać FAIL, a oryginał PASS. rc 0 = test PASS.
set -uo pipefail
ROOT="${AIGON_ROOT:-/opt/PROD}"
GATE="$ROOT/tools/gates/law-precedence-matrix.sh"
SRC="$ROOT/config/canonical/constitution-drafts/M2-precedence.yaml"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
bad=0

expect() { # nazwa oczekiwany_rc plik
  local got; PRECEDENCE_FILE="$3" bash "$GATE" >"$T/out" 2>&1; got=$?
  if [ "$got" = "$2" ]; then echo "ok   $1 (rc=$got)"
  else echo "BAD  $1 (rc=$got, oczekiwano $2)"; sed 's/^/     /' "$T/out"; bad=1; fi
}
mutate() { # nazwa kod-python
  python3 - "$SRC" "$T/$1.yaml" "$2" <<'PY'
import sys, yaml
src, dst, code = sys.argv[1:4]
p = yaml.safe_load(open(src)); exec(code); yaml.safe_dump(p, open(dst, "w"), allow_unicode=True, sort_keys=False)
PY
}

expect "oryginał PASS" 0 "$SRC"
mutate miss  'p["law_p_map"]["P6"].remove("LAW-100")'
expect "prawo bez P => FAIL" 1 "$T/miss.yaml"
mutate dup   'p["law_p_map"]["P8"].append("LAW-1")'
expect "prawo w dwóch P => FAIL" 1 "$T/dup.yaml"
mutate l31   'p["law_p_map"]["P1"].remove("LAW-31"); p["law_p_map"]["P5"].append("LAW-31")'
expect "LAW-31 (immutable, fixed exception) w P5 => FAIL" 1 "$T/l31.yaml"
mutate om    'p["law_p_map"]["P2"].remove("LAW-Ω1"); p["law_p_map"]["P7"].append("LAW-Ω1")'
expect "omega w P7 => FAIL" 1 "$T/om.yaml"
mutate pair  'p["conflict_matrix"].pop()'
expect "9/10 par => FAIL" 1 "$T/pair.yaml"
mutate win   'p["conflict_matrix"][0]["winner"]="a"'
expect "zwycięzca sprzeczny z P (LAW-18 nad LAW-20) => FAIL" 1 "$T/win.yaml"
mutate stop  'del p["stop_criteria"]["irreversibility"]["resume"]'
expect "typ stopu bez resume => FAIL" 1 "$T/stop.yaml"
mutate pre   'p["preamble"].pop()'
expect "7/8 zasad preambuły => FAIL" 1 "$T/pre.yaml"
mutate ghost 'p["law_p_map"]["P3"].append("LAW-999")'
expect "ID spoza rejestru => FAIL" 1 "$T/ghost.yaml"
expect "po przywróceniu oryginał PASS" 0 "$SRC"

[ "$bad" = 0 ] && { echo "TEST PASS: law-precedence-matrix łapie wszystkie mutacje"; exit 0; }
echo "TEST FAIL"; exit 1
