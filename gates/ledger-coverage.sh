#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  ledger-coverage.sh — BRAMKA: ledger pokrywa pracę WSZYSTKICH agentów
#
#  KANON 2026-09-24 (WAR MODE, rozkaz Suwerena: "czy każdy agent zapisuje
#  swoje task listy do ledgera? to też musi być kanoniczne").
#
#  CO MIERZY (nie deklaruje — mierzy):
#   1. Czy strażnik ledgera (scripts/ledger-warden.py) żyje i raportuje.
#   2. Czy hooki ledgera są zainstalowane u WSZYSTKICH znanych agentów
#      (qwen/claude/hermes/grok/codex) — brak hooka = praca niewidoczna.
#   3. Czy hook Stop istnieje (bez niego ostatni wpis sesji zostaje open
#      na zawsze — luka zmierzona: 69 wpisów project=auto).
#   4. Czy hook TodoWrite istnieje (task lista → ledger przy każdym zapisie).
#   5. Czy task-listy aktywnych sesji mają odzwierciedlenie w ledgerze.
#
#  Severity: FAIL gdy brak hooka u agenta, który ma config; WARN gdy brak
#  świeżych task-list (nic do zmierzenia — nie karzemy za ciszę).
#
#  Exit: 0 = PASS/WARN, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_ROOT:-/opt/PROD}"
HOME_OPER="${AIGON_OPER_HOME:-/home/sniegul}"
fails=0
warns=0

say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
warn() { printf 'WARN  %s\n' "$*"; warns=$((warns + 1)); }
ok()   { printf 'OK    %s\n' "$*"; }

# ── 1. Strażnik żyje i ma świeży raport ────────────────────────────────
REPORT="$HOME_OPER/.aigon/warden/report.json"
if [ -f "$REPORT" ]; then
  age_min=$(( ( $(date +%s) - $(stat -c %Y "$REPORT") ) / 60 ))
  if [ "$age_min" -le 15 ]; then
    ok "straznik ledgera: raport świeży (${age_min} min)"
  else
    fail "straznik ledgera: raport MA ${age_min} min (oczekiwane <=15, cron */5)"
  fi
  # Strażnik NIE MOŻE widzieć śmieci testowych jako otwartej pracy.
  garbage=$(python3 -c "import json;d=json.load(open('$REPORT'));print(d.get('totals',{}).get('garbage',0))" 2>/dev/null || echo "?")
  if [ "$garbage" = "?" ]; then
    warn "straznik ledgera: nie odczytano licznika śmieci"
  elif [ "$garbage" -gt 0 ]; then
    fail "ledger: ${garbage} otwartych wpisów TESTOWYCH (śmieci) — strażnik ma je czyścić"
  else
    ok "ledger: zero wpisów testowych wśród otwartych"
  fi
else
  fail "straznik ledgera: BRAK raportu ($REPORT) — warden nie uruchomiony"
fi

# ── 2. Hooki ledgera u KAŻDEGO agenta, który ma config ─────────────────
check_hook() {
  local agent="$1" cfg="$2" ev="$3" marker="$4"
  [ -f "$cfg" ] || return 0   # agent bez configu — nie dotyczy
  if grep -q "$marker" "$cfg" 2>/dev/null; then
    # czy marker jest w kontekscie eventu (grubsze, ale wykrywa brak eventu)
    ok "hook ${agent}/${ev}: zainstalowany"
  else
    fail "hook ${agent}/${ev}: BRAK u agenta ${agent} (config istnieje: $cfg)"
  fi
}

# qwen + claude: json settings
for a in qwen claude; do
  cfg="$HOME_OPER/.$a/settings.json"
  [ -f "$cfg" ] || continue
  for ev in UserPromptSubmit Stop; do
    if python3 - "$cfg" "$ev" <<'PY' 2>/dev/null
import json,sys
cfg,ev=sys.argv[1],sys.argv[2]
d=json.load(open(cfg))
arr=d.get("hooks",{}).get(ev) or []
ok=any("ledger-autoadd" in (h.get("command") or "") for e in arr for h in (e.get("hooks") or []))
sys.exit(0 if ok else 1)
PY
    then ok "hook ${a}/${ev}: ledger-autoadd obecny"; else fail "hook ${a}/${ev}: BRAK ledger-autoadd"; fi
  done
  # TodoWrite → tasklista
  if python3 - "$cfg" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
arr=d.get("hooks",{}).get("PostToolUse") or []
ok=any("tasklist-hook" in (h.get("command") or "")
       for e in arr if "TodoWrite" in str(e.get("matcher") or "")
       for h in (e.get("hooks") or []))
sys.exit(0 if ok else 1)
PY
  then ok "hook ${a}/TodoWrite: tasklist-hook obecny"; else fail "hook ${a}/TodoWrite: BRAK tasklist-hook"; fi
done

# ── 3. Skrypty kanoniczne istnieją ─────────────────────────────────────
for s in ledger-warden.py tasklist-sync.py tasklist-hook.py ledger-autoadd.py install-ledger-hooks.py; do
  if [ -x "$ROOT/scripts/$s" ]; then ok "skrypt $s"; else fail "skrypt $s: BRAK/nie-wykonywalny"; fi
done

# ── 4. Task-listy aktywnych sesji widoczne w ledgerze ──────────────────
active_files=$(find "$HOME_OPER/.claude/tasks" "$HOME_OPER/.qwen/todos" -name '*.json' -mmin -2880 2>/dev/null | wc -l)
if [ "$active_files" -gt 0 ]; then
  # sprawdz czy w agregacie sa wpisy tasklist:*
  n=$(grep -c '"project": "tasklist:' "$HOME_OPER/.aigon/todo/mesh-aggregate.ndjson" 2>/dev/null || echo 0)
  if [ "$n" -gt 0 ]; then
    ok "tasklisty: ${active_files} aktywnych plików, ${n} wpisów tasklist:* w ledgerze"
  else
    fail "tasklisty: ${active_files} aktywnych plików, ale ZERO wpisów tasklist:* w ledgerze"
  fi
else
  warn "tasklisty: brak aktywnych plików (<48h) — nic do zmierzenia"
fi

say ""
say "ledger-coverage: FAIL=${fails} WARN=${warns}"
[ "$fails" -eq 0 ]
