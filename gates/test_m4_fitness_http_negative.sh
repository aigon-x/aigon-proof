#!/usr/bin/env bash
# Actual unchanged executors. Fake curl models transport only; the browser
# fixture proves command presence only. No live HTTP/auth/browser claim.
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
failures = 0
checks = 0
def run(root, relative, env, wanted, label):
    global failures, checks
    checks += 1
    try:
        p = subprocess.run(['bash', str(root / relative)], cwd=root, env=env,
                           capture_output=True, text=True, timeout=20)
        marker = {0: 'PASS', 1: 'FAIL', 2: 'BEZ_POMIARU'}[wanted]
        if p.returncode != wanted or marker not in p.stdout + p.stderr:
            failures += 1
            print(f'FAIL {label}: wanted {wanted}/{marker}, got {p.returncode}\n{p.stdout}{p.stderr}')
    except subprocess.TimeoutExpired:
        failures += 1
        print(f'FAIL {label}: timeout, NOT_RUN')

def put(root, name, content):
    p = root / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding='utf-8')
    return p

with tempfile.TemporaryDirectory(prefix='m4-transport-') as scratch:
    root = pathlib.Path(scratch)
    for relative in ('tools/gates/fitness/law-78-fit.sh',
                     'tools/gates/sovereignty-fitness.sh',
                     'tools/gates/project-visual-verification.sh'):
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / relative, target)
    curl = put(root, 'bin/curl', '#!'+sys.executable+'\n'+'''
import os, pathlib, sys
args = sys.argv[1:]
target = pathlib.Path(args[args.index('-o') + 1])
mode = os.environ['M4_HTTP_MODE']
target.write_text('' if mode == 'empty' else '#!/bin/bash\\necho fixture join\\n')
print({'okay':'200', '404':'404', '500':'500', 'empty':'200', 'connection':'000'}[mode], end='')
sys.exit(7 if mode == 'connection' else 0)
''')
    curl.chmod(0o700)
    browser = put(root, 'bin/agent-browser', '#!/bin/sh\nexit 99\n')
    browser.chmod(0o700)
    env = dict(os.environ, PATH=str(root / 'bin')+':'+os.environ['PATH'])
    gate = 'tools/gates/fitness/law-78-fit.sh'
    before = failures
    env['M4_HTTP_MODE'] = 'okay'
    run(root, gate, env, 0, 'LAW-78 baseline')
    for mode in ('404', '500', 'empty'):
        env['M4_HTTP_MODE'] = mode
        run(root, gate, env, 1, 'LAW-78 '+mode)
        env['M4_HTTP_MODE'] = 'okay'
        run(root, gate, env, 0, 'LAW-78 restored')
    env['M4_HTTP_MODE'] = 'connection'
    run(root, gate, env, 2, 'LAW-78 transport unavailable (not violation detection)')
    env['M4_HTTP_MODE'] = 'okay'
    run(root, gate, env, 0, 'LAW-78 restored after transport failure')
    print(f'M4_RESULT LAW-78 {"PASS" if failures == before else "FAIL"} mutants=3 scope=transport-fixture unavailable_cases=1')

    # These three mapped laws share one static executor; count no live key use.
    put(root, 'runtime/knowledge/01-canon/AIGON_CONSTITUTION.md', 'LAW-Ω1 LAW-Ω2 Suweren\n')
    code = 'def decision():\n    return {"error": "forbidden", "reason": "cannot comply"}\n'
    baseline = 'AIGON_SOVEREIGN_KEY = "fixture-marker-only"\n' + code
    path = put(root, 'fixture/decision.py', baseline)
    env['AIGON_SOVEREIGN_ROOTS'] = str(root / 'fixture')
    before = failures
    gate = 'tools/gates/sovereignty-fitness.sh'
    run(root, gate, env, 0, 'sovereignty baseline override marker')
    path.write_text(code, encoding='utf-8')
    run(root, gate, env, 1, 'sovereignty remove override marker')
    path.write_text(baseline, encoding='utf-8')
    run(root, gate, env, 0, 'sovereignty restored')
    for law in ('LAW-Ω1', 'LAW-Ω2', 'LAW-Ω6'):
        print(f'M4_RESULT {law} {"PASS" if failures == before else "FAIL"} mutants=1 scope=shared-static-refusal-executor')

    gate = 'tools/gates/project-visual-verification.sh'
    ssot = put(root, 'config/canonical/project-verification.yaml', 'gate: project-visual-verification.sh\n')
    report = put(root, 'evidence/report.ndjson', json.dumps({'text':'projekt https://fixture.invalid działa screenshot render poprawny'})+'\n')
    env['AIGON_PROJECT_VERIFY_EVIDENCE'] = str(report)
    before = failures
    run(root, gate, env, 0, 'LAW-VERIFY-1 baseline')
    report.write_text(json.dumps({'text':'projekt https://fixture.invalid działa curl HTTP 200'})+'\n', encoding='utf-8')
    run(root, gate, env, 1, 'LAW-VERIFY-1 curl-only false green')
    report.write_text(json.dumps({'text':'projekt https://fixture.invalid działa screenshot render poprawny'})+'\n', encoding='utf-8')
    run(root, gate, env, 0, 'LAW-VERIFY-1 restored evidence')
    ssot.write_text('gate: unrelated\n', encoding='utf-8')
    run(root, gate, env, 1, 'LAW-VERIFY-1 disconnected SSOT')
    ssot.write_text('gate: project-visual-verification.sh\n', encoding='utf-8')
    run(root, gate, env, 0, 'LAW-VERIFY-1 restored SSOT')
    print(f'M4_RESULT LAW-VERIFY-1 {"PASS" if failures == before else "FAIL"} mutants=2 scope=evidence-classification-and-command-presence')
print(f'M4 transport/static: checks={checks} failures={failures}')
sys.exit(1 if failures else 0)
PY
