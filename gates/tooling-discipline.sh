#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/tooling-discipline.sh — GATE TOOLING-DISCIPLINE (LAW-TOOL-1)
#
#  PRAWO (SSOT: config/canonical/agent-tooling.yaml → enforcement):
#    "Ripgrep zawsze, nigdy find." Szukanie = `rg` (treść) i `rg --files`
#    (lista plików, z --no-ignore dla plików w .gitignore). Crash narzędzia
#    dedykowanego != „nie ma" — wtedy `rg` w shellu, nie pętla prób.
#
#  Bramka nie deklaruje — MIERZY:
#   1) STATYCZNIE: prawo MUSI być w prompcie SSOT (marker z SSOT) — usunięcie
#      prawa z promptu łamie bramkę (prawo nie znika po cichu).
#   2) PARYTET: prawo rozsyła scripts/sync-agent-models.py do plików
#      tożsamości WSZYSTKICH agentów. Bramka wymaga JEDNEGO md5 na wszystkich
#      celach — inaczej prawo dotarło do części agentów i jest sugestią,
#      nie prawem.
#   3) SKALA: ile razy kanon/prompt sam wskazuje `find` (raport; nie FAIL,
#      bo zakaz dotyczy NAS, a nie cudzych skryptów — raport czyni dług widocznym).
#
#  Kontrakt hook-runnera: exit 0 = PASS/WARN, exit 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSOT="${ROOT}/config/canonical/agent-tooling.yaml"
PROMPT_YAML="${ROOT}/config/agent-models.yaml"
FAILS=0
WARNS=0

say()  { printf '%s\n' "$*"; }
pass() { say "[PASS] $1"; }
warn() { say "[WARN] $1"; WARNS=$((WARNS+1)); }
fail() { say "[FAIL] $1"; FAILS=$((FAILS+1)); }

say "=== GATE TOOLING-DISCIPLINE (LAW-TOOL-1: ripgrep zawsze, nigdy find) ==="

# ── 0. SSOT prawa musi istnieć i wskazywać TĘ bramkę ───────────────────────
if [ -r "$SSOT" ]; then
  if grep -q "LAW-TOOL-1" "$SSOT" 2>/dev/null; then
    pass "prawo zadeklarowane w SSOT ($(basename "$SSOT") → LAW-TOOL-1)"
  else
    fail "brak LAW-TOOL-1 w $SSOT — prawo nie istnieje, nie ma czego egzekwować"
  fi
  if grep -q "tools/gates/tooling-discipline.sh" "$SSOT" 2>/dev/null; then
    pass "SSOT wskazuje tę bramkę jako egzekwującą"
  else
    fail "SSOT nie wskazuje tools/gates/tooling-discipline.sh — deklaracja bez bramki to dług"
  fi
else
  fail "brak SSOT $SSOT"
fi

# ── 1. Prawo MUSI być w prompcie rozsyłanym do agentów ─────────────────────
MARKER="$(sed -n 's/^[[:space:]]*marker:[[:space:]]*"\(.*\)".*/\1/p' "$SSOT" 2>/dev/null | head -1)"
[ -z "$MARKER" ] && MARKER="PRAWO NARZĘDZIOWE"

if [ -r "$PROMPT_YAML" ]; then
  if python3 - "$PROMPT_YAML" "$MARKER" <<'PY' >/dev/null 2>&1
import sys, yaml
path, marker = sys.argv[1], sys.argv[2]
c = yaml.safe_load(open(path))["system_prompt"]["content"]
ok = (marker in c) and ("ripgrep" in c) and ("rg --files" in c)
sys.exit(0 if ok else 1)
PY
  then
    pass "prawo jest w promptcie SSOT (marker: $MARKER, zawiera 'ripgrep' i 'rg --files')"
  else
    fail "prompt SSOT NIE zawiera prawa (marker '$MARKER' + 'ripgrep' + 'rg --files') — agenci go nie dostaną"
  fi
else
  fail "brak promptu $PROMPT_YAML"
fi

# ── 2. Parytet plików tożsamości: jedno md5 na wszystkich celach ───────────
REPORT="$(cd "$ROOT" && timeout 120 python3 scripts/sync-agent-models.py --render-identity 2>/dev/null)"
if [ -z "$REPORT" ]; then
  fail "brak raportu parytetu (sync-agent-models.py --render-identity) — brak dowodu, nie „OK”"
else
  # Kontrakt = ten sam co GATE-058: agent z własnym addendum
  # (`system_prompt.per_agent`, dziś TYLKO codex) CELOWO różni się od kanonu,
  # więc parytet liczy się na agentach WSPÓLNYCH. Porównywanie wszystkich
  # sześciu plików "na jeden md5" było fałszywym FAIL-em.
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
  N_FILE="$(printf '%s\n' "$REPORT" | awk -F'\t' -v skip="$PER_AGENT" '
    BEGIN { n=split(skip, s, ","); for (i=1;i<=n;i++) if (s[i]!="") excl[s[i]]=1 }
    NF>=3 && !($2 in excl)' | grep -c .)"
  N_EXCL="$(printf '%s\n' "$REPORT" | awk -F'\t' -v skip="$PER_AGENT" '
    BEGIN { n=split(skip, s, ","); for (i=1;i<=n;i++) if (s[i]!="") excl[s[i]]=1 }
    NF>=3 && ($2 in excl)' | grep -c .)"
  N_MD5="$(printf '%s\n' "$MD5S" | grep -c .)"
  if [ "$N_MD5" = "1" ]; then
    pass "parytet tożsamości: $N_FILE plików wspólnych, JEDEN md5 (${MD5S:0:12}…) — prawo dotarło do wszystkich agentów${N_EXCL:+ (+$N_EXCL z addendum per_agent: ${PER_AGENT})}"
  elif [ "${N_MD5:-0}" -gt "1" ]; then
    fail "parytet tożsamości ZŁAMANY: $N_FILE plików wspólnych, $N_MD5 różnych md5 — prawo dotarło tylko do części agentów"
    printf '%s\n' "$REPORT" | sed 's/^/       /'
  else
    fail "parytet: brak celu do porównania (0 plików wspólnych, wykluczone per_agent: ${PER_AGENT:-brak})"
  fi
fi

# ── 3. Skala: gdzie kanon/prompt sam wskazuje `find` (raport, nie FAIL) ─────
if [ -r "$PROMPT_YAML" ]; then
  N_FIND="$(python3 - "$PROMPT_YAML" <<'PY' 2>/dev/null
import sys, yaml, re
c = yaml.safe_load(open(sys.argv[1]))["system_prompt"]["content"]
print(len(re.findall(r'(?<![\w/])find\s', c)))
PY
)"
  if [ -n "$N_FIND" ] && [ "$N_FIND" != "0" ]; then
    warn "prompt SSOT wspomina 'find' $N_FIND× — sprawdź, czy to nie instrukcja dla agenta (zakaz z LAW-TOOL-1)"
  else
    pass "prompt SSOT nie wskazuje 'find' ani raz"
  fi
fi

say "---"
if [ "$FAILS" -gt 0 ]; then
  say "WYNIK: FAIL ($FAILS naruszeń, $WARNS ostrzeżeń) — LAW-TOOL-1 nieegzekwowane"
  exit 1
fi
say "WYNIK: PASS (0 naruszeń, $WARNS ostrzeżeń) — LAW-TOOL-1 egzekwowane"
exit 0
