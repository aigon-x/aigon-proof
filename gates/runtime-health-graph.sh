#!/usr/bin/env bash
# ============================================================================
# GATE-229 runtime-health-graph — POKRYCIE ZDROWIA RUNTIME (brak pomiaru != zielony)
# ============================================================================
# Bramka uruchamia scripts/runtime-health-graph.py i wydaje werdykt z artefaktu,
# nie z opinii. Kontrakt runnera: 0 = PASS, 1 = FAIL, 2 = WARN/PARTIAL, 75 = DEFERRED.
#
# CO MIERZY (nie "czy /health zwraca 200"):
#   * 12 osi elementow runtime: kernels, engines, services, datastores, mesh_nodes,
#     providers, capabilities, endpoints, cron_jobs, gates, laws, skills;
#   * dla KAZDEGO elementu: status + KLASA DOWODU (REAL_PROBE/EXISTENCE/
#     DECLARED_ONLY/MISSING) + sonda + zrodlo;
#   * ratchet (config/canonical/runtime-health-graph.yaml): spadek coverage przy
#     KOMPLETNYM pomiarze = REGRESJA = FAIL; brak SSOT = nie moze byc PASS;
#   * dlug (debt) tylko z wlascicielem i data przegladu — wygasa automatycznie.
#
# WYNIK: PASS wymaga braku FAIL na osi krytycznej, braku regresji i braku
# niezmierzonych elementow. PARTIAL (exit 2) = system zyje, ale sa elementy bez
# sondy — to NIE jest "zielono", to jest jawny dlug.
#
# Uzycie:
#   tools/gates/runtime-health-graph.sh              # werdykt z pelnym pomiarem
#   tools/gates/runtime-health-graph.sh --quick      # bez sond HTTP endpointow
#   tools/gates/runtime-health-graph.sh --selftest   # dowod negatywny (4 przypadki)
#   tools/gates/runtime-health-graph.sh --certify    # tryb certyfikacji (PARTIAL => FAIL)
# ============================================================================
set -uo pipefail

ROOT="${AIGON_ROOT:-/srv/aigon}"
SCRIPT="$ROOT/scripts/runtime-health-graph.py"
CFG="$ROOT/config/canonical/runtime-health-graph.yaml"
TMPDIR_RUN="$(mktemp -d /tmp/rhg-gate.XXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

MODE="normal"
QUICK=0
for arg in "$@"; do
  case "$arg" in
    --selftest) MODE="selftest" ;;
    --quick)    QUICK=1 ;;
    --certify)  MODE="certify" ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
  esac
done

run_audit() { # $1 = config path or "" ; $2 = extra args
  local cfg="$1"; local extra="${2:-}"
  local -a cmd=(python3 "$SCRIPT" --json --no-textfile --out "$TMPDIR_RUN/art")
  [ -n "$cfg" ] && cmd+=(--config "$cfg")
  # shellcheck disable=SC2086
  "${cmd[@]}" $extra >"$TMPDIR_RUN/out.json" 2>"$TMPDIR_RUN/err.txt"
  echo $?
}

summarize() { # wypisuje WERDYKT + nazwy problemow (nie tylko liczby)
  python3 - "$TMPDIR_RUN/out.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"[BLAD] brak czytelnego artefaktu werdyktu: {e}")
    raise SystemExit(3)
print(f"WERDYKT={d.get('verdict')} CERTIFIED={d.get('certified')} "
      f"coverage={d.get('totals', {}).get('coverage_ratio')} "
      f"elementy={d.get('totals', {}).get('declared')} "
      f"zmierzone={d.get('totals', {}).get('observed')}")
for r in d.get("verdict_reasons") or []:
    print(f"  POWOD [{r.get('axis')}]: {r.get('reason')}")
for a in d.get("debt_accepted") or []:
    print(f"  DLUG-ZAAKCEPTOWANY: {a.get('element')} owner={a.get('owner')} "
          f"review_by={a.get('review_by')}")
# NAZWY, nie liczby: najgorsze osie z konkretnymi elementami
cov = d.get("coverage") or {}
bad = sorted(((v.get("coverage_ratio") if v.get("coverage_ratio") is not None else -1), k)
             for k, v in cov.items())
for ratio, axis in bad[:5]:
    v = cov[axis]
    print(f"  OS {axis}: coverage={ratio:.1%} evidence={v.get('evidence_ratio')} "
          f"PASS={v['by_status'].get('PASS',0)} FAIL={v['by_status'].get('FAIL',0)} "
          f"UNKNOWN={v['by_status'].get('UNKNOWN',0)}")
PY
}

if [ "$MODE" = "selftest" ]; then
  echo "=== SELFTEST GATE-229 (dowod negatywny) ==="
  fails=0

  # T1: kanon realny — bramka NIE moze byc slepa (musi wydac werdykt 0 albo 2)
  rc=$(run_audit "" "--quick")
  echo "[T1] kanon realny -> rc=$rc (oczekiwane 0 lub 2)"
  case "$rc" in 0|2) ;; *) echo "  FAIL: bramka nie wydala werdyktu na realnym kanonie"; fails=$((fails+1));; esac

  # T2: prog NIEMOZLIWY na osi krytycznej => REGRESJA => rc=1 (deterministyczne)
  python3 - "$CFG" "$TMPDIR_RUN/cfg-regresja.yaml" <<'PYCFG'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
d["thresholds"]["kernels"] = {"coverage": 2.0, "evidence": 1.0}
yaml.safe_dump(d, open(sys.argv[2], "w"), allow_unicode=True, sort_keys=False)
PYCFG
  rc=$(run_audit "$TMPDIR_RUN/cfg-regresja.yaml" "--quick")
  echo "[T2] prog nieosiagalny na osi krytycznej (kernels) -> rc=$rc (oczekiwane 1)"
  [ "$rc" = "1" ] || { echo "  FAIL: regresja na osi krytycznej NIE wykryta"; fails=$((fails+1)); }

  # T3: inna os krytyczna (engines) z niemozliwym progiem => rc=1
  python3 - "$CFG" "$TMPDIR_RUN/cfg-engines.yaml" <<'PYCFG'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
d["critical_axes"] = ["engines"]
d["thresholds"]["engines"] = {"coverage": 2.0, "evidence": 1.0}
yaml.safe_dump(d, open(sys.argv[2], "w"), allow_unicode=True, sort_keys=False)
PYCFG
  rc=$(run_audit "$TMPDIR_RUN/cfg-engines.yaml" "--quick")
  echo "[T3] os krytyczna engines z progiem nieosiagalnym -> rc=$rc (oczekiwane 1)"
  [ "$rc" = "1" ] || { echo "  FAIL: regresja na innej osi krytycznej NIE wykryta"; fails=$((fails+1)); }

  # T4: BRAK SSOT progow => nie wolno wydac PASS (rc musi byc != 0)
  rc=$(run_audit "/dev/null" "--quick")
  echo "[T4] brak SSOT (--config /dev/null) -> rc=$rc (oczekiwane != 0)"
  if [ "$rc" = "0" ]; then echo "  FAIL: brak SSOT przepuszczony jako PASS"; fails=$((fails+1)); fi
  cert=$(python3 -c "import json;print(json.load(open('$TMPDIR_RUN/out.json')).get('certified'))" 2>/dev/null)
  [ "$cert" = "False" ] || { echo "  FAIL: brak SSOT nie ustawil certified=False (jest: $cert)"; fails=$((fails+1)); }

  if [ "$fails" -eq 0 ]; then
    echo "SELFTEST: PASS (4/4)"
    exit 0
  fi
  echo "SELFTEST: FAIL ($fails/4)"
  exit 1
fi

if [ ! -x "$SCRIPT" ] && [ ! -f "$SCRIPT" ]; then
  echo "[FAIL] brak skryptu audytu: $SCRIPT"
  exit 1
fi

EXTRA=""
[ "$QUICK" = "1" ] && EXTRA="--quick"
rc=$(run_audit "$CFG" "$EXTRA")
if [ ! -s "$TMPDIR_RUN/out.json" ]; then
  echo "[FAIL] audyt nie wygenerowal werdyktu (rc=$rc)"
  sed -n '1,5p' "$TMPDIR_RUN/err.txt"
  exit 1
fi

summarize

if [ "$MODE" = "certify" ] && [ "$rc" = "2" ]; then
  echo "TRYB CERTYFIKACJI: PARTIAL traktowany jako FAIL (cel = 100% pokrycia)"
  exit 1
fi
exit "$rc"
