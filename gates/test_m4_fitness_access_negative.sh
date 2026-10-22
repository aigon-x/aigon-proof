#!/usr/bin/env bash
# Test real access evaluator; fixture collector substitutes remote audit transport.
set -euo pipefail
# Strip repository selectors before any fixture interpreter or git invocation.
for m4_git_env in ${!GIT_@}; do unset "$m4_git_env"; done
unset PYTHONOPTIMIZE PYTHONPATH
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 - "$ROOT" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
source = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='m4-access-') as scratch:
    root = pathlib.Path(scratch)
    gate = root/'tools/gates/access-posture-check.sh'
    gate.parent.mkdir(parents=True)
    shutil.copyfile(source/'tools/gates/access-posture-check.sh', gate)
    config=root/'config/canonical'; config.mkdir(parents=True)
    acl=config/'tailscale-acl.hujson'; cap=config/'capabilities.yaml'
    collector=root/'tools/access-posture-audit.py'
    # Collector is data transport only. The actual gate parses/decides untouched.
    collector.write_text('import pathlib\nprint(pathlib.Path(__file__).with_name("audit.json").read_text())\n')
    data=root/'tools/audit.json'
    good={'fixture': {'pub22':0, 'policy':'drop', 'pass':'no', 'root':'no', 'listen0':0}}
    def reset():
        acl.write_text('{}\n'); cap.write_text('entries: []\n')
        data.write_text(json.dumps(good))
    env={k:v for k,v in os.environ.items() if not k.startswith('AIGON_')}
    def run(expected):
        p=subprocess.run(['bash',str(gate)], cwd=root, env=env, capture_output=True,text=True,timeout=10)
        marker='access-posture-check: '+('PASS' if expected==0 else 'FAIL')
        assert p.returncode==expected and marker in p.stdout, p.stdout+p.stderr
    def alter(key,value):
        bad=json.loads(json.dumps(good)); bad['fixture'][key]=value; data.write_text(json.dumps(bad))
    mutations=[lambda:alter('pub22',1), lambda:alter('policy','accept'),
               lambda:alter('pass','yes'), lambda:alter('root','yes'),
               lambda:acl.unlink(), lambda:cap.unlink()]
    for mutate in mutations:
        reset(); run(0); mutate(); run(1); reset(); run(0)
    data.write_text('broken JSON')
    p=subprocess.run(['bash',str(gate)], cwd=root, env=env, capture_output=True,text=True,timeout=10)
    assert p.returncode == 2 and 'access-posture-check: WARN' in p.stdout, p.stdout+p.stderr
    # Malformed input is unmeasured and never counted as detected violation.
    reset(); run(0)
    print(f'M4_RESULT LAW-55 PASS mutants={len(mutations)} scope=audit-result-consumer-only unavailable_cases=1')
PY
