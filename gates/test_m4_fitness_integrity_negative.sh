#!/usr/bin/env bash
# M4: isolated mutations of real FITNESS executors; no live state writes.
# JSON contains exact transitions; exit 2 means unavailable measurement, never PASS.
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
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = Path(os.environ['M4_SOURCE_ROOT'])

def execute(cmd, env, cwd):
    try:
        result = subprocess.run(cmd, env=env, cwd=cwd, capture_output=True,
                                text=True, timeout=20)
        return {'rc': result.returncode, 'output': (result.stdout + result.stderr)[-6000:]}
    except subprocess.TimeoutExpired:
        return {'rc': 124, 'output': 'measurement timed out'}

def suite(name):
    laws = {'wiring': ['LAW-11', 'LAW-45'], 'lesson': ['LAW-35', 'LAW-57'],
            'chain': ['LAW-30', 'LAW-31'], 'limits': ['LAW-20', 'LAW-66a'],
            'gpu': ['LAW-46']}[name]
    result = {'executor': name, 'laws': laws, 'status': 'UNKNOWN', 'mutations': []}
    with tempfile.TemporaryDirectory(prefix='m4-fitness-integrity-') as tmp:
        fixture = Path(tmp)
        env = os.environ.copy()
        env['LC_ALL'] = 'C'
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        cmd = None
        cases = []
        def put(path, text):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding='utf-8')
        def case(label, path, good, bad):
            put(path, good)
            cases.append((label, path, good, bad))

        if name == 'wiring':
            files = {'AIGON_WIRING_DEBT': ('debt.txt', ''),
                     'AIGON_CAPS_YAML': ('caps.yaml', 'entries: []\n'),
                     'AIGON_WORKFLOWS_YAML': ('workflows.yaml', 'entries: []\n'),
                     'AIGON_PLUGINS_YAML': ('plugins.yaml', 'entries: []\n'),
                     'AIGON_CARGO_TOML': ('Cargo.toml', '[workspace]\nmembers = []\n')}
            for key, (filename, content) in files.items():
                path = fixture / filename
                put(path, content)
                env[key] = str(path)
            (fixture / 'crates').mkdir()
            env['AIGON_CRATES_DIR'] = str(fixture / 'crates')
            case('unregistered capability', fixture / 'caps.yaml', 'entries: []\n',
                 'entries: []\nC-999: {}\n')
            case('fictional workflow', fixture / 'workflows.yaml', 'entries: []\n',
                 'entries:\n- name: m4-flow\n  steps: [{action: echo}]\n')
            case('placeholder plugin', fixture / 'plugins.yaml', 'entries: []\n',
                 'entries:\n- name: m4-plugin\n  description: Placeholder\n')
            cmd = ['bash', str(ROOT / 'tools/gates/wiring-closure.sh')]
        elif name == 'lesson':
            lessons, gates = fixture / 'lessons', fixture / 'gates'
            lessons.mkdir(); gates.mkdir()
            put(gates / 'm4-check.sh', '#!/bin/sh\nexit 0\n')
            env.update(AIGON_LA_LESSONS=str(lessons), AIGON_LA_GATES=str(gates))
            good = '## Gate\nGate: m4-check\nStatus: COVERED\n'
            case('missing covered executor', lessons / 'lesson.md', good,
                 '## Gate\nGate: m4-absent\nStatus: COVERED\n')
            case('invalid lesson status', lessons / 'lesson.md', good,
                 '## Gate\nGate: m4-check\nStatus: INVALID\n')
            cmd = ['bash', str(ROOT / 'tools/gates/lesson-audit.sh')]
        elif name == 'chain':
            records, chain = fixture / 'records.ndjson', fixture / 'chain.ndjson'
            good = '{"run_id":"m4-fixture","outcome":"original"}\n'
            put(records, good)
            env.update(AIGON_RUN_CHAIN=str(chain), AIGON_RUN_CHAIN_SOURCES=str(records),
                       AIGON_RUN_CHAIN_TIMEOUT='15')
            seal = execute(['python3', str(ROOT / 'scripts/run-chain.py'), 'seal',
                            '--source', str(records), '--chain', str(chain)], env, fixture)
            if seal['rc'] != 0:
                result['reason'] = 'fixture seal unavailable'
                result['setup'] = seal
                return result
            case('sealed record changed', records, good,
                 '{"run_id":"m4-fixture","outcome":"tampered"}\n')
            case('sealed record removed', records, good, '')
            cmd = ['bash', str(ROOT / 'tools/gates/run-chain.sh')]
        elif name == 'limits':
            gate = fixture / 'tools/gates/limits-ssot.sh'
            gate.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / 'tools/gates/limits-ssot.sh', gate)
            assert hashlib.sha256(gate.read_bytes()).digest() == hashlib.sha256(
                (ROOT / 'tools/gates/limits-ssot.sh').read_bytes()).digest()
            good = 'num_ctx: 4096\nnum_parallel: 1\nmax_loaded_models: 1\n'
            case('limits baseline drift', fixture / 'config/limits.yaml', good,
                 'num_ctx: 8192\nnum_parallel: 1\nmax_loaded_models: 1\n')
            put(fixture / 'config/canonical/limits.baseline.sha256',
                hashlib.sha256(good.encode()).hexdigest() + '\n')
            cmd = ['bash', str(gate)]
            result['limitation'] = 'Tests YAML/hash agreement, not live container limits.'
        elif name == 'gpu':
            if not shutil.which('nvidia-smi'):
                result['reason'] = 'nvidia-smi prerequisite absent; no command stub used'
                return result
            metric = fixture / 'resident.prom'
            env['AIGON_GPU_RESIDENT_PROM'] = str(metric)
            case('resident metric absent', metric,
                 'aigon_gpu_resident_model_loaded 1\naigon_gpu_resident_vram_mib 12288\n',
                 'aigon_gpu_resident_model_loaded 0\naigon_gpu_resident_vram_mib 0\n')
            cmd = ['bash', str(ROOT / 'tools/gates/gpu-resident.sh')]
            result['limitation'] = 'Tests metric consumer; no GPU/model load or unload.'

        for label, path, good, bad in cases:
            put(path, good)
            before = execute(cmd, env, fixture)
            put(path, bad)
            broken = execute(cmd, env, fixture)
            put(path, good)
            restored = execute(cmd, env, fixture)
            transition = [before['rc'], broken['rc'], restored['rc']]
            result['mutations'].append({'name': label, 'transition': transition,
                                        'outputs': [before['output'], broken['output'], restored['output']]})
        result['status'] = 'PASS' if all(m['transition'] == [0, 1, 0]
                                       for m in result['mutations']) else 'FAIL'
    return result

with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
    results = list(pool.map(suite, ['wiring', 'lesson', 'chain', 'limits', 'gpu']))
report = {'suite': 'M4 isolated fitness integrity', 'results': results,
          'verified_laws': sum(len(r['laws']) for r in results if r['status'] == 'PASS'),
          'fixture_directories_cleaned': 5}
print(json.dumps(report, ensure_ascii=False, indent=2))
sys.exit(1 if any(r['status'] == 'FAIL' for r in results) else
         2 if any(r['status'] == 'UNKNOWN' for r in results) else 0)
PY
