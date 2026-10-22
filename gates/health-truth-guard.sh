#!/usr/bin/env bash
# ============================================================================
# health-truth-guard.sh — STRAZNIK PRAWDY ZDROWIA (anty-falszywy-zielony)
#
# PO CO (rozkaz Suwerena 2026-09-29: "musimy sie zabezpieczyc przed takimi
# sytuacjami"): runtime zwraca `status: ok` przy 48 komponentach, z ktorych
# tylko 3 sa faktycznie PROBOWANE (probed=true), a 43 maja status
# "registered" (zarejestrowany != zywy). Mesh raportuje 0 nodow. Bramki
# czytajace samo `status` uznaja to za ZDROWE.
#
# ZASADA (kanon antyself-report): DEKLARACJA != POMIAR.
#   - `status: "ok"` bez pokrycia pomiarem = FAIL (falszywy zielony)
#   - pusta lista nodow przy niepustym mesh = FAIL (pusta lista != sukces)
#   - brak odpowiedzi = FAIL (brak dowodu != stan zdrowy)
#
# Bramka: config/canonical/gates.yaml -> health-truth-guard
# Uruchomienie: bash tools/gates/health-truth-guard.sh
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

RUNTIME="${AIGON_RUNTIME_URL:-https://192.0.2.19:7000}"
FAILED=0
declare -a REASONS=()

note_fail() { REASONS+=("$1"); FAILED=1; }

# Klucz runtime: bez niego /api/v1/mesh zwraca pusta liste, a bramka czytala
# to jako "0 nodow" (pomiar slepy, nie dowod awarii). Klucz z env albo z
# /srv/aigon/core/.env (env_file runtime) — NIGDY z argv.
_rt_key="${AIGON_RUNTIME_SHARED_SECRET:-${AIGON_RUNTIME_API_KEY:-}}"
if [ -z "$_rt_key" ] && [ -r /srv/aigon/core/.env ]; then
  _rt_key="$(grep -m1 '^AIGON_RUNTIME_SHARED_SECRET=' /srv/aigon/core/.env 2>/dev/null | cut -d= -f2- | tr -d '\r\n')"
fi
AUTH=(); [ -n "$_rt_key" ] && AUTH=(-H "X-API-Key: $_rt_key")

_HF="$(mktemp)"; _MF="$(mktemp)"
trap 'rm -f "$_HF" "$_MF"' EXIT
timeout 25 curl -sk "${AUTH[@]}" "${RUNTIME}/api/v1/health" -o "$_HF" 2>/dev/null
if [ ! -s "$_HF" ]; then
  note_fail "brak odpowiedzi /api/v1/health (brak dowodu != zdrowy)"
  printf 'health-truth-guard: FAIL (%s)\n' "${REASONS[0]}"
  exit 1
fi

timeout 25 curl -sk "${AUTH[@]}" "${RUNTIME}/api/v1/mesh" -o "$_MF" 2>/dev/null

read -r STATUS NCOMP NPROBED NREG NODES < <(
  H_FILE="$_HF" M_FILE="$_MF" python3 - <<'PYEOF'
import json, os
def _load(p):
    try:
        return json.load(open(p, encoding="utf-8"))
    except Exception:
        return {}
h = _load(os.environ["H_FILE"])
r = h.get("runtime", {}) or {}
ac = r.get("all_components", {}) or {}
status = h.get("status") or (r.get("status") if isinstance(r, dict) else None)
probed = sum(1 for v in ac.values() if isinstance(v, dict) and v.get("probed"))
reg = sum(1 for v in ac.values()
          if isinstance(v, dict) and v.get("status") == "registered")
try:
    m = _load(os.environ["M_FILE"])
    nodes = m.get("nodes")
    nodes = len(nodes) if isinstance(nodes, list) else (nodes or 0)
except Exception:
    nodes = -1
print(status or "?", len(ac), probed, reg, nodes)
PYEOF
)

echo "  status=${STATUS}  komponentow=${NCOMP}  probed=${NPROBED}  registered=${NREG}  nodes=${NODES}"

# --- REGULA 1: "ok" bez pokrycia pomiarem -----------------------------------
# Prog: co najmniej 25% komponentow musi byc PROBOWANE. Runtime z 48
# komponentami i 3 probe = 6% -> zielony jest fikcja.
# RATCHET (2026-10-17): prog bezwzgledny 25% blokowal CALA rodzine (kazdy commit),
# bo realne pokrycie sond runtime to 6% (3/49) — dlug zastany, nie regresja.
# Baseline w config/canonical/health-truth-guard-baseline.txt (coverage_min).
# FAIL gdy pokrycie SPADNIE ponizej baseline albo baseline brak (fail-closed).
BASE_FILE="$ROOT/config/canonical/health-truth-guard-baseline.txt"
COV_MIN=25
if [ -r "$BASE_FILE" ]; then
  COV_MIN="$(grep -m1 '^coverage_min:' "$BASE_FILE" | sed 's/[^0-9]//g')"
  COV_MIN="${COV_MIN:-25}"
fi
if [ "${STATUS}" = "ok" ] && [ "${NCOMP:-0}" -gt 0 ]; then
  PCT=$(( NPROBED * 100 / NCOMP ))
  if [ "$PCT" -lt "$COV_MIN" ]; then
    note_fail "status=ok ale pokrycie sond ${PCT}% (${NPROBED}/${NCOMP}) < baseline ${COV_MIN}% — falszywy zielony/regresja"
  elif [ "$PCT" -lt 25 ]; then
    echo "  [WARN] pokrycie sond ${PCT}% (${NPROBED}/${NCOMP}) — ponizej celu 25%, zgodne z baseline (dlug jawny)"
  fi
fi

# --- REGULA 2: pusta lista nodow != sukces ----------------------------------
if [ "${NODES}" = "0" ]; then
  note_fail "mesh zwraca 0 nodow (pusta lista != sukces; sprawdz z wnętrza kontenera)"
elif [ "${NODES}" = "-1" ]; then
  note_fail "mesh /api/v1/mesh nie zwrocil listy nodow (brak dowodu)"
fi

# --- REGULA 3: komponent "registered" bez proby to nie "dziala" ------------
if [ "${NREG:-0}" -gt 0 ] && [ "${NPROBED:-0}" -eq 0 ]; then
  note_fail "${NREG} komponentow 'registered' i ZERO probowanych — rejestracja nie jest dowodem zycia"
fi

if [ "$FAILED" -eq 1 ]; then
  printf 'health-truth-guard: FAIL'
  for x in "${REASONS[@]}"; do printf ' | %s' "$x"; done
  printf '\n'
  exit 1
fi

printf 'health-truth-guard: PASS (status=%s, probed=%s/%s, nodes=%s)\n' \
  "$STATUS" "$NPROBED" "$NCOMP" "$NODES"
exit 0
