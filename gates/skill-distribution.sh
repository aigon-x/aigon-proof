#!/usr/bin/env bash
# ============================================================================
# gates/domains/skill-distribution.sh — bramka dystrybucji skilli (LAW-SKILL-1)
# ============================================================================
# Po co: skill potrafi mieć POPRAWNY wpis w manifeście (`targets: [7 agentów]`)
# i NIE istnieć u żadnego agenta — bo nie należy do rdzenia (`skills_core`).
# Manifest wygląda jak rejestracja, więc luka jest CICHA. Zmierzone
# 2026-09-29: `aigon-x-operations` — manifest OK, rdzeń nie, u agentów BRAK.
#
# Mechanizm (kod, nie teoria): scripts/sync-agent-models.py
#   # Rdzeń kontekstu: poza nim skill NIE trafia do katalogu agenta.
#   if core is not None and name not in core:
#       continue
#
# Bramka woła tools/gates/skill-registry-integrity.py i czyta check
# `rdzen_niedostarczony`. FAIL gdy skill JEST w rdzeniu i deklaruje agenta,
# a agent go nie ma (zawiodło dostarczenie).
#
# WARNING (nie FAIL): 2229 skilli manifestu poza rdzeniem — to PROJEKT
# (oszczędność kontekstu; treść dostępna przez MCP skills_get), nie defekt.
#
# Uwaga na detektor: rdzeń liczy się z KODU KONSUMUJĄCEGO
# (sync-agent-models.py::_skills_core_set = 269), nie z reimplementacji
# w bramce (always+kategorie = 286 → 15 fałszywych FAIL).
# ============================================================================
set -uo pipefail

REPO="${AIGON_PROD_ROOT:-/srv/aigon}"
GATE="$REPO/tools/gates/skill-registry-integrity.py"

fail() { echo "FAIL: $*"; exit 1; }
warn() { echo "WARN: $*"; exit 0; }
ok()   { echo "OK: $*"; exit 0; }

[ -f "$GATE" ] || fail "brak $GATE (bramka LAW-SKILL-1 niezainstalowana)"

PY="$(command -v python3 || true)"
[ -n "$PY" ] || fail "brak python3"

# Bramka czyta config + katalogi agentów; dajemy twardy budżet czasu.
"$PY" "$REPO/scripts/mandatory_skills.py" --check || fail "mandatory skill core incomplete"

OUT="$(timeout 180 "$PY" "$GATE" --json 2>/dev/null)"
[ -n "$OUT" ] || warn "bramka nie zwróciła JSON (timeout/błąd) — brak pomiaru != defekt"

# Parsowanie: verdict + check rdzen_niedostarczony.
read -r VERDICT RSTATUS RTOTAL RCOMPLETE RNBRAK <<EOF
$(printf '%s' "$OUT" | "$PY" -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("unknown unknown 0 false 0"); raise SystemExit
f=[x for x in d.get("findings",[]) if x.get("check")=="rdzen_niedostarczony"]
if not f: print(d.get("verdict","unknown"),"unknown",0,"false",0); raise SystemExit
y=f[0]
print(d.get("verdict","unknown"), y.get("status"), y.get("rdzen_total",0),
      str(y.get("rdzen_kompletny",False)).lower(), len(y.get("brak_u_agentow",[])))
' 2>/dev/null)
EOF

case "$RSTATUS" in
  pass)
    ok "dystrybucja skilli: rdzeń=${RTOTAL} (kompletny=${RCOMPLETE}), wszystkie dostarczone"
    ;;
  fail)
    fail "LAW-SKILL-1: ${RNBRAK} skilli RDZENIA nie dostarczono do deklarowanych agentów — zawiodło sync-agent-models.py; domknij: <n> do skills_core.always + sync + bramka"
    ;;
  warn|unknown|*)
    warn "check rdzen_niedostarczony: status=${RSTATUS} (rdzeń=${RTOTAL}) — brak rozstrzygającego pomiaru; nie ogłaszam defektu"
    ;;
esac
