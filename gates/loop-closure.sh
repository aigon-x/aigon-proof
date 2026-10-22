#!/usr/bin/env bash
# G-L1 (LAW-101 perfection): every loop has a closed contract or an explicit
# owner/reason/next_check. No CLOSED without evidence. No false green.
set -euo pipefail
REG="${1:-/srv/aigon/config/canonical/loop-registry.yaml}"
SKILL=/srv/aigon/skills/shared/doskonalosc-100plus/SKILL.md
AGENTS=/srv/aigon/config/agent-models.yaml
python3 - "$REG" "$SKILL" "$AGENTS" <<'PY'
import sys, yaml
reg, skill, agents = sys.argv[1:4]
d = yaml.safe_load(open(reg)) or {}
loops = d.get('loops') or []
fail = []
for l in loops:
    i = l.get('id', '<no-id>')
    st = l.get('status', '')
    for k in ('id','status','owner','next_check'):
        if not l.get(k):
            fail.append(f"{i}: missing {k}")
    if st == 'closed':
        if not l.get('evidence'):
            fail.append(f"{i}: closed without evidence")
    elif st == 'open':
        for k in ('trigger','remediation','verification','evidence'):
            if not l.get(k):
                fail.append(f"{i}: open missing {k}")
    elif st == 'blocked':
        if not l.get('blocked_reason'):
            fail.append(f"{i}: blocked without blocked_reason")
    else:
        fail.append(f"{i}: invalid status {st!r}")
if not loops:
    fail.append("registry has no loops")
try:
    body = open(skill, encoding='utf-8').read()
except FileNotFoundError:
    fail.append("perfection skill missing"); body = ""
for marker in ('## R17', 'loop-registry', 'G-L1'):
    if marker not in body:
        fail.append(f"perfection skill missing {marker}")
a = yaml.safe_load(open(agents)) or {}
core = (a.get('context_budget') or {}).get('skills_core') or {}
if 'doskonalosc-100plus' not in (core.get('always') or []):
    fail.append("doskonalosc-100plus not in skills_core.always")
if 'doskonalosc-100plus' not in (a.get('skills',{}).get('manifest') or {}):
    fail.append("doskonalosc-100plus not in skills.manifest")
if fail:
    print("G-L1 FAIL")
    for f in fail:
        print(" -", f)
    sys.exit(1)
print(f"G-L1 PASS loops={len(loops)}"
      f" open={sum(1 for l in loops if l.get('status')=='open')}"
      f" blocked={sum(1 for l in loops if l.get('status')=='blocked')}"
      f" closed={sum(1 for l in loops if l.get('status')=='closed')}")
PY
