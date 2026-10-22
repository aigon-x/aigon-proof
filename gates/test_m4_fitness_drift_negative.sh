#!/usr/bin/env bash
# M4 LAW104: existing drift permissions and hardcoded-IP predicates, scoped.
# This does not certify full remote mesh/Docker/HA drift checks.
set -uo pipefail
# Strip repository selectors before any fixture interpreter or git invocation.
for m4_git_env in ${!GIT_@}; do unset "$m4_git_env"; done
unset PYTHONOPTIMIZE PYTHONPATH
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export M4_SOURCE_ROOT="$ROOT"
exec python3 - "$@" <<'PY'
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(os.environ['M4_SOURCE_ROOT'])

def suite(scope):
    result = {'scope': scope, 'mutations': []}
    with tempfile.TemporaryDirectory(prefix='m4-drift-scoped-') as tmp:
        base = Path(tmp)
        script = base / 'scripts/mfixture.sh'
        script.parent.mkdir()
        script.write_text('#!/bin/sh\ntrue\n')
        script.chmod(0o755)
        secret = base / 'core/.env'
        secret.parent.mkdir()
        secret.write_text('# no actual secret, fixture data only\n')
        secret.chmod(0o600)
        allow = base / 'config/drift-allowlist.yaml'
        allow.parent.mkdir()
        allow.write_text('hardcoded_node_ips: []\n')
        cmd = ['bash', str(ROOT / 'scripts/drift-checker.sh'), '--check', scope, '--root', str(base)]
        env = os.environ.copy()
        env.update(PYTHONDONTWRITEBYTECODE='1', LC_ALL='C')
        def call():
            try:
                p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
                return {'rc': p.returncode, 'output': p.stdout + p.stderr}
            except subprocess.TimeoutExpired:
                return {'rc': 124, 'output': 'no scoped measurement: timeout'}
        if scope == 'permissions':
            cases = [('world-readable secret', lambda: secret.chmod(0o600), lambda: secret.chmod(0o644)),
                     ('script loses executable bit', lambda: script.chmod(0o755), lambda: script.chmod(0o644))]
        else:
            cases = [('new hardcoded mesh address', lambda: script.write_text('#!/bin/sh\ntrue\n'),
                      lambda: script.write_text('#!/bin/sh\nHOST=100.99.88.77\n')),
                     ('unreadable ratchet missing', lambda: allow.write_text('hardcoded_node_ips: []\n'),
                      lambda: allow.unlink())]
        for name, restore, corrupt in cases:
            restore(); before = call()
            corrupt(); broken = call()
            restore(); after = call()
            result['mutations'].append({'name': name, 'transition': [before['rc'], broken['rc'], after['rc']],
                                        'outputs': [before['output'], broken['output'], after['output']]})
        result['status'] = 'PASS' if all(m['transition'] == [0, 1, 0] for m in result['mutations']) else 'FAIL'
    return result

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    scopes = list(pool.map(suite, ['permissions', 'hardcoded-ips']))
mutations = [m for s in scopes for m in s['mutations']]
result = {'executor': 'drift-checker', 'laws': ['LAW-104'],
          'status': 'PASS' if all(s['status'] == 'PASS' for s in scopes) else 'FAIL',
          'mutations': mutations, 'scopes': scopes,
          'limitation': 'Partial predicate coverage: actual existing permissions and hardcoded-IP ratchet checks only; full live mesh/SSH/Docker/HA/tunnel audit not executed.'}
print(json.dumps({'suite': 'M4 scoped drift predicates', 'results': [result],
                  'verified_laws': int(result['status'] == 'PASS'), 'fixture_directories_cleaned': 2},
                 ensure_ascii=False, indent=2))
sys.exit(0 if result['status'] == 'PASS' else 1)
PY
