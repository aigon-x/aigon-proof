#!/usr/bin/env bash
# TEMPLATE-CANON G-20f: wymaga scripts/ + /srv/aigon
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/scripts-tests.sh — gate scripts-tests (hook-runner)
#
#  PO CO (rozkaz Suwerena 2026-09-30: „chuj martwy kod, podpinac, jak cos
#  bylo napisane tzn ze bylo potrzebne"):
#  W /srv/aigon/scripts leżały TESTY i WERYFIKATORY, których NIKT nie wołał —
#  test istnieje, ale nie jest uruchamiany, więc nie chroni NICZEGO.
#  To najgorsza klasa martwego kodu: wygląda jak zabezpieczenie, a jest
#  deklaracją intencji.
#
#  TEN GATE URUCHAMIA JE WSZYSTKIE. Każdy test dostaje własny timeout i jest
#  raportowany osobno (żeby jeden padający nie ukrył reszty). Wynik zbiorczy:
#    exit 0 = wszystkie pass (albo pominięte świadomie)
#    exit 1 = któryś test FAILED
#    exit 3 = błąd środowiska
#  Opcje: --json (raport), --quiet (tylko kod), --list (spis testów)
#
#  Rejestr uruchamianych testów = SSOT: config/canonical/scripts-tests.json
#  (nie lista w tym pliku — ta sama zasada „zero ręcznych list" co w atlasie).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REG="${AIGON_SCRIPTS_TESTS:-$ROOT/config/canonical/scripts-tests.json}"
JSON=0; QUIET=0; LIST=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --quiet) QUIET=1 ;;
    --list) LIST=1 ;;
  esac
done
[ -f "$REG" ] || { echo "scripts-tests: brak rejestru $REG"; exit 3; }

if [ "$LIST" = "1" ]; then
  python3 - "$REG" << 'PY'
import json,sys
for t in json.load(open(sys.argv[1])):
    print(f"{t.get('script',''):<48} {t.get('timeout',120):>5}s  {t.get('why','')[:60]}")
PY
  exit 0
fi

run() { # run <script> <timeout> <why>
  local s="$1" to="${2:-120}" why="$3" rc out
  local path="$ROOT/scripts/$s"
  if [ ! -f "$path" ]; then
    echo "MISSING|$s|$why||plik nie istnieje"; return
  fi
  case "$s" in
    # Children must not consume the registry pipe used by the dispatch loop.
    *.py) out="$(timeout "$to" python3 "$path" </dev/null 2>&1)"; rc=$? ;;
    *)    out="$(timeout "$to" bash "$path" </dev/null 2>&1)"; rc=$? ;;
  esac
  # RETRY JEDEN RAZ dla skryptow sondujacych ZYWA infrastrukture (2026-10-20):
  # `post-reboot-verify.sh` ma ~87 s i 6 sekcji prob (docker, runtime health,
  # mesh, tailscale, dysk). Zmierzone: samodzielnie ZIELONY (PASS=21 FAIL=0),
  # a w przebiegu pre-push pod load 30-40 potrafic raz mignac rc=1 — i blokowal
  # push całej flocie na flaku srodowiskowym, nie na regresji. Jedna powtorka
  # po 20 s rozroznia TRZEPOT od REALNEGO zlamania (drugi FAIL nadal blokuje).
  if [ "$rc" != "0" ] && [ "$s" = "post-reboot-verify.sh" ]; then
    sleep 20
    out="$(timeout "$to" bash "$path" </dev/null 2>&1)"; rc=$?
    [ "$rc" = "0" ] && out="$out"$'\n''(retry po 20 s: PASS — pierwszy przebieg byl trzepotem srodowiskowym)'
  fi
  local tail1
  tail1="$(printf '%s' "$out" | tail -1 | tr -d '\000' | tr -cd '[:print:]\n' | cut -c1-160)"
  if [ "$rc" = "0" ]; then echo "PASS|$s|$why|$rc|$tail1"
  elif [ "${ENV_DEP:-0}" = "1" ]; then echo "ENV-DEP|$s|$why|$rc|$tail1"
  elif [ "$rc" = "124" ]; then echo "TIMEOUT|$s|$why|$rc|$tail1"
  # FIX 2026-09-30: testy z klasą `env_dependent` (wymagają PEŁNEGO mesha —
  # węzły expected_down jak poligon dają FAIL środowiskowy, nie kodowy) NIE
  # mogą zatrzymywać pusha. Oznaczamy je ENV-DEP, nie FAIL. Rozróżnienie jest
  # w SSOT config/canonical/scripts-tests.json, nie w tym skrypcie.
  else echo "FAIL|$s|$why|$rc|$tail1"; fi
}

if ! REGISTRY_ROWS="$(python3 - "$REG" <<'PY'
import json, sys
from pathlib import PurePosixPath
with open(sys.argv[1], encoding='utf-8') as handle:
    records = json.load(handle)
if not isinstance(records, list) or not records:
    raise ValueError('registry must be a nonempty list')
rows = []
for record in records:
    if not isinstance(record, dict):
        raise ValueError('registry entry must be an object')
    script = record.get('script')
    timeout = record.get('timeout', 120)
    env = record.get('env_dependent', False)
    why = record.get('why', '')
    if (not isinstance(script, str) or not script or
            any(c in script for c in '|\r\n') or PurePosixPath(script).is_absolute() or
            '..' in PurePosixPath(script).parts):
        raise ValueError('invalid script path')
    if type(timeout) is not int or timeout <= 0 or type(env) is not bool or not isinstance(why, str):
        raise ValueError('invalid timeout, environment classification or reason')
    rows.append(f"{script}|{timeout}|{why.replace('|', ' ').replace(chr(10), ' ').replace(chr(13), ' ')}|{int(env)}")
print('\n'.join(rows))
PY
)"; then
  echo 'scripts-tests: invalid or empty required registry; no success verdict'
  exit 3
fi

RESULTS="$(printf '%s\n' "$REGISTRY_ROWS" | while IFS='|' read -r s to why envdep; do
      ENV_DEP="$envdep" run "$s" "$to" "$why"
    done)"

TOTAL=$(printf '%s\n' "$RESULTS" | grep -c . || true)
PASS=$(printf '%s\n' "$RESULTS" | grep -c '^PASS|' || true)
FAIL=$(printf '%s\n' "$RESULTS" | grep -cE '^(FAIL|TIMEOUT|MISSING)\|' || true)

if [ "$JSON" = "1" ]; then
  RESULTS="$RESULTS" python3 -c "
import json,os
rows=[l.split('|',4) for l in os.environ['RESULTS'].splitlines() if l]
print(json.dumps({'status':'PASS' if $FAIL==0 else 'FAIL','total':$TOTAL,'pass':$PASS,'fail':$FAIL,
 'rows':[{'status':r[0],'script':r[1],'why':r[2],'rc':r[3] if len(r)>3 else '','tail':r[4] if len(r)>4 else ''} for r in rows]},ensure_ascii=False))
"
elif [ "$QUIET" != "1" ]; then
  echo "scripts-tests: total=$TOTAL pass=$PASS fail=$FAIL"
  printf '%s\n' "$RESULTS" | grep -vE '^PASS\|' | while IFS='|' read -r st s why rc t; do
    [ -z "$st" ] && continue
    echo "  $st $s (rc=$rc) — $why"
    [ -n "$t" ] && echo "        $t"
  done
  printf '%s\n' "$RESULTS" | grep -c '^PASS|' >/dev/null
fi

[ "$FAIL" = "0" ] && exit 0 || exit 1
