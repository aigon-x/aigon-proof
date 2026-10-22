#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/swarm-scout-brief.sh — GATE SWARM-SCOUT-BRIEF (LAW-SWARM-1)
#
#  PRAWO (SSOT: config/canonical/agent-swarm.yaml → enforcement):
#    "Zwiadowca → brief → wykonawcy." Jeden agent czyta raz i pisze brief per
#    zadanie; wykonawca dostaje tylko swój brief i commituje po każdym defekcie.
#
#  Bramka MIERZY:
#   1) SSOT prawa istnieje i wskazuje TĘ bramkę.
#   2) Prawo jest w runtime_addendum promptu SSOT (marker + kontrakt briefu).
#   3) PARYTET: jeden md5 plików tożsamości agentów wspólnych (jak GATE-058).
#
#  Kontrakt hook-runnera: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSOT="${ROOT}/config/canonical/agent-swarm.yaml"
PROMPT_YAML="${ROOT}/config/agent-models.yaml"
FAILS=0
WARNS=0

say()  { printf '%s\n' "$*"; }
pass() { say "[PASS] $1"; }
warn() { say "[WARN] $1"; WARNS=$((WARNS+1)); }
fail() { say "[FAIL] $1"; FAILS=$((FAILS+1)); }

say "=== GATE SWARM-SCOUT-BRIEF (LAW-SWARM-1: zwiadowca → brief → wykonawcy) ==="

# ── 0. SSOT prawa musi istnieć i wskazywać TĘ bramkę ───────────────────────
if [ -r "$SSOT" ]; then
  if grep -q "LAW-SWARM-1" "$SSOT" 2>/dev/null; then
    pass "prawo zadeklarowane w SSOT ($(basename "$SSOT") → LAW-SWARM-1)"
  else
    fail "brak LAW-SWARM-1 w $SSOT"
  fi
  if grep -q "tools/gates/swarm-scout-brief.sh" "$SSOT" 2>/dev/null; then
    pass "SSOT wskazuje tę bramkę jako egzekwującą"
  else
    fail "SSOT nie wskazuje tools/gates/swarm-scout-brief.sh — deklaracja bez bramki to dług"
  fi
else
  fail "brak SSOT $SSOT"
fi

# ── 1. Prawo MUSI być w prompcie rozsyłanym do agentów ─────────────────────
MARKER="$(sed -n 's/^[[:space:]]*marker:[[:space:]]*"\(.*\)".*/\1/p' "$SSOT" 2>/dev/null | head -1)"
[ -z "$MARKER" ] && MARKER="PRAWO ZWIADU"

if [ -r "$PROMPT_YAML" ]; then
  if python3 - "$PROMPT_YAML" "$MARKER" <<'PY' >/dev/null 2>&1
import sys, yaml
path, marker = sys.argv[1], sys.argv[2]
sp = yaml.safe_load(open(path))["system_prompt"]
c = (sp.get("content") or "") + "\n" + (sp.get("runtime_addendum") or "")
ok = ("LAW-SWARM-1" in c) and (marker in c) and ("plik:linia" in c) and ("brief" in c)
sys.exit(0 if ok else 1)
PY
  then
    pass "prawo jest w prompcie SSOT (marker: $MARKER, kontrakt briefu 'plik:linia')"
  else
    fail "prompt SSOT NIE zawiera prawa (LAW-SWARM-1 + '$MARKER' + 'plik:linia') — agenci go nie dostaną"
  fi
else
  fail "brak promptu $PROMPT_YAML"
fi

# ── 2. Parytet plików tożsamości: jedno md5 na wspólnych celach ────────────
REPORT="$(cd "$ROOT" && timeout 120 python3 scripts/sync-agent-models.py --render-identity 2>/dev/null)"
if [ -z "$REPORT" ]; then
  fail "brak raportu parytetu (sync-agent-models.py --render-identity) — brak dowodu, nie „OK”"
else
  PER_AGENT="$(python3 - "$PROMPT_YAML" <<'PY' 2>/dev/null
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1]))
    per = ((d.get("system_prompt") or {}).get("per_agent") or {})
    print(",".join(sorted(per.keys())))
except Exception:
    print("")
PY
)"
  MD5S="$(printf '%s\n' "$REPORT" | awk -F'\t' -v skip="$PER_AGENT" '
    BEGIN { n=split(skip, s, ","); for (i=1;i<=n;i++) if (s[i]!="") excl[s[i]]=1 }
    NF>=3 && !($2 in excl) && $1!="" { print $1 }' | sort -u)"
  N_MD5="$(printf '%s\n' "$MD5S" | grep -c .)"
  if [ "$N_MD5" = "1" ]; then
    pass "parytet tożsamości: JEDEN md5 (${MD5S:0:12}…) — prawo dotarło do wszystkich agentów wspólnych"
  elif [ "${N_MD5:-0}" -gt "1" ]; then
    fail "parytet tożsamości ZŁAMANY: $N_MD5 różnych md5 — prawo dotarło tylko do części agentów"
    printf '%s\n' "$REPORT" | sed 's/^/       /'
  else
    fail "parytet: brak celu do porównania"
  fi
fi

say "---"
if [ "$FAILS" -gt 0 ]; then
  say "WYNIK: FAIL ($FAILS naruszeń, $WARNS ostrzeżeń) — LAW-SWARM-1 nieegzekwowane"
  exit 1
fi
say "WYNIK: PASS (0 naruszeń, $WARNS ostrzeżeń) — LAW-SWARM-1 egzekwowane"
exit 0
