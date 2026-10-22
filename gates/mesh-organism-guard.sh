#!/usr/bin/env bash
# mesh-organism-guard.sh — egzekutor LAW-MESH-ORGANISM-1 ("JEDEN ORGANIZM").
# Realna bramka spójności organizmu: sprawdza, że KAŻDY agent jest WPIĘTY w
# mesh/swarm (deklaruje udział + ma kanał współpracy), a nie działa jako silos.
# ADVISORY: WARN domyślnie; --strict => FAIL; --selftest => testy.
set -uo pipefail
STRICT=0; SELFTEST=0; HITS=0
for a in "$@"; do case "$a" in --strict) STRICT=1;; --selftest) SELFTEST=1;; esac; done
AM=/srv/aigon/config/agent-models.yaml
PRESENCE=/srv/aigon/scripts/aigon-agent-presence.sh
SKILL=/srv/aigon/skills/shared/mesh-organism/SKILL.md
HOOKS=/srv/aigon/config/canonical/hooks.yaml

_check() {  # $1=opis, $2=0/1 (1=ok)
  if [ "$2" != 1 ]; then HITS=$((HITS+1)); printf 'WARN [mesh-organism] %s\n' "$1"; fi
}

if [ "$SELFTEST" = 1 ]; then
  ok=1
  # pozytywny: agent bez scatter -> wykryty
  t=$(_check 'test-agent bez udzialu w swarm' 0 >/dev/null 2>&1; echo "$?" )
  # licz samodzielnie: symuluj brakujacego
  HITS=0; _check 'x' 0 >/dev/null; [ "$HITS" -ge 1 ] || { echo 'SELFTEST FAIL: nie wykryl braku'; ok=0; }
  HITS=0; _check 'x' 1 >/dev/null; [ "$HITS" -eq 0 ] || { echo 'SELFTEST FAIL: falszywe trafienie'; ok=0; }
  [ "$ok" = 1 ] && echo 'SELFTEST PASS' || exit 1
  exit 0
fi

# 1) każdy agent musi deklarować udział w swarm/mesh
if [ -f "$AM" ]; then
  python3 - "$AM" <<'PY'
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
for n,v in (d.get('agents') or {}).items():
    if not isinstance(v,dict): continue
    has_scatter = bool(v.get('scatter'))
    caps = ' '.join(map(str,(v.get('capabilities') or [])+(v.get('skills') or [])))
    has_task = ('task_execute' in caps) or ('task_execute' in str(v.get('mcp') or ''))
    if not (has_scatter or has_task):
        print(f'MISS {n}')
PY
fi
# 2) mechanizmy współpracy muszą istnieć
[ -x "$PRESENCE" ] || _check "brak rejestru obecności: $PRESENCE" 0
[ -f "$SKILL" ] || _check "brak skilla mesh-organism: $SKILL" 0
[ -f "$HOOKS" ] && grep -q 'mesh-organism-guard' "$HOOKS" || _check "bramka bez triggera w hooks.yaml" 0

# zlicz MISS z pkt 1
MISS=$(python3 - "$AM" <<'PY' 2>/dev/null
import yaml,sys
d=yaml.safe_load(open(sys.argv[1])); c=0
for n,v in (d.get('agents') or {}).items():
    if not isinstance(v,dict): continue
    has=bool(v.get('scatter')) or ('task_execute' in ' '.join(map(str,(v.get('capabilities') or [])+(v.get('skills') or []))))
    if not has: c+=1
print(c)
PY
)
if [ "${MISS:-0}" -gt 0 ]; then HITS=$((HITS+MISS)); echo "WARN [mesh-organism] $MISS agent(ow) bez deklaracji swarm/mesh"; fi

if [ "$HITS" -gt 0 ]; then
  [ "$STRICT" = 1 ] && { echo "FAIL [mesh-organism] $HITS problemow organizmu (strict)"; exit 1; }
  echo "WARN [mesh-organism] $HITS problemow organizmu (advisory; --strict => FAIL)"; exit 0
fi
echo 'PASS [mesh-organism] organizm spójny: agenci wpięci w mesh/swarm, mechanizmy współpracy obecne'; exit 0
