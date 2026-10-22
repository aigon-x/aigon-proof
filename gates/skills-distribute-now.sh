#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/skills-distribute-now.sh — bramka EVENT-DRIVEN dystrybucji skilli
# ═══════════════════════════════════════════════════════════════════════
#  ROZKAZ SUWERENA (2026-10-01): "to sie musi automatycznie robic" + "event driven".
#
#  PODZIAŁ RÓL (KANON #12):
#    - EVENT (ta bramka): zmiana (commit dotykający skills/shared/** lub
#      config/agent-models.yaml) NATYCHMIAST uruchamia dostarczenie i DOWÓD.
#    - ZEGAR (safety net, już istnieje): cron `sync-agent-models` (co 15 min) +
#      bramka GATE-140 `skill-distribution` (cyclic:hourly) pilnują tego,
#      czego event nie dopilnował (drop niecommitowany, lock trzymany, node offline).
#
#  TA BRAMKA JEST IDEMPOTENTNA i droga w spoczynku:
#    - brak zmian w skills/ w tym commicie  -> OK (event nie dotyczy), ~0 kosztu,
#    - zmiana dotyczy skills/              -> sync + pomiar rdzenia.
#
#  Kontrakt hook-runner.sh: exit 0 = PASS/WARN, exit 1 = FAIL, exit 2 = DEFER.
#  DEFER jest ŚWIADOMY (nie FAIL): lock trzymany przez inny przebieg = event nie
#  wszedł, ale zegar odrobi — meldowanie FAIL byłoby fałszywym alarmem.
#
#  Zmienne: AIGON_SKILLS_FORCE=1  -> wymuś pełny przebieg (ignoruj filtr zmian)
#           AIGON_SKILLS_SYNC_TIMEOUT (domyślnie 1500 s)
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_PROD_ROOT:-/opt/PROD}"
cd "$ROOT" || { echo "FAIL brak $ROOT"; exit 1; }

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FAIL brak python3"; exit 1; }

SYNC="$ROOT/scripts/sync-agent-models.py"
INTEG="$ROOT/tools/gates/skill-registry-integrity.py"
[ -f "$SYNC" ]  || { echo "FAIL brak $SYNC"; exit 1; }
[ -f "$INTEG" ] || { echo "FAIL brak $INTEG"; exit 1; }

TIMEOUT="${AIGON_SKILLS_SYNC_TIMEOUT:-1500}"

# ── 1) FILTR ZDARZENIA: czy TA zmiana dotyczy dystrybucji skilli? ──────────
if [ "${AIGON_SKILLS_FORCE:-0}" != "1" ]; then
  CHANGED="$(git -C "$ROOT" diff --name-only HEAD~1..HEAD 2>/dev/null \
              | grep -E '^(skills/|config/agent-models\.yaml)' | head -1 || true)"
  if [ -z "$CHANGED" ]; then
    echo "OK skills-distribute-now: brak zmian w skills/ ani w manifeście — event nie dotyczy (exit 0)"
    exit 0
  fi
  echo "INFO event: zmiana dotyczy dystrybucji -> $CHANGED"
fi

# ── 2) WYKONANIE: kanoniczna dystrybucja (jeden mechanizm, nie kopia) ─────
OUT="$(timeout "$TIMEOUT" "$PY" "$SYNC" 2>&1)"; RC=$?
if printf '%s' "$OUT" | grep -q "SKIP: agent config sync lock held"; then
  echo "DEFER skills-distribute-now: inny przebieg trzyma lock (event nie wszedł; zegar odrobi — brak dowodu != defekt)"
  exit 2
fi
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$OUT" | tail -5
  echo "FAIL skills-distribute-now: sync-agent-models.py rc=$RC (dystrybucja nie zaszła)"
  exit 1
fi

# ── 3) DOWÓD: nie "sync się wykonał", tylko "rdzeń JEST u agentów" ────────
JOUT="$(timeout 180 "$PY" "$INTEG" --json 2>/dev/null)"
[ -n "$JOUT" ] || { echo "WARN skills-distribute-now: brak pomiaru (integrity timeout) — brak pomiaru != defekt"; exit 0; }

read -r RSTATUS RTOTAL RNBRAK <<EOF
$(printf '%s' "$JOUT" | "$PY" -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("unknown 0 0"); raise SystemExit
f=[x for x in d.get("findings",[]) if x.get("check")=="rdzen_niedostarczony"]
if not f: print("unknown 0 0"); raise SystemExit
y=f[0]
print(y.get("status","unknown"), y.get("rdzen_total",0), len(y.get("brak_u_agentow",[])))
' 2>/dev/null)
EOF

case "$RSTATUS" in
  pass) echo "OK skills-distribute-now: rdzeń=${RTOTAL} dostarczony u wszystkich deklarowanych agentów (dowód, nie deklaracja)"; exit 0 ;;
  fail) echo "FAIL LAW-SKILL-1: ${RNBRAK}/${RTOTAL} skilli rdzenia NIE dotarło do agentów — event wykonał sync, ale dostarczenie nie domknęło"; exit 1 ;;
  *)    echo "WARN skills-distribute-now: status pomiaru=${RSTATUS} (rdzeń=${RTOTAL}) — brak rozstrzygającego dowodu"; exit 0 ;;
esac
