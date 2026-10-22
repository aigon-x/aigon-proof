#!/usr/bin/env bash
# M4 extra: byte-identical gate copies and real loopback HTTP fixtures.
# No SSH, Docker, live runtime, pipeline execution, or secret scanning.
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

ROOT = Path(os.environ['M4_SOURCE_ROOT'])

def run(cmd, env, cwd):
    try:
        p = subprocess.run(cmd, env=env, cwd=cwd, capture_output=True, text=True, timeout=20)
        return {'rc': p.returncode, 'output': (p.stdout + p.stderr)[-6000:]}
    except subprocess.TimeoutExpired:
        return {'rc': 124, 'output': 'measurement timeout'}

def suite(name):
    laws = {'otel': ['LAW-4'], 'kernel': ['LAW-16'], 'cerberus': ['LAW-39'],
            'mesh': ['LAW-29'], 'health': ['LAW-22']}[name]
    result = {'executor': name, 'laws': laws, 'status': 'UNKNOWN', 'mutations': []}
    with tempfile.TemporaryDirectory(prefix='m4-fitness-extra-') as tmp:
        base = Path(tmp)
        env = os.environ.copy()
        env.update(LC_ALL='C', PYTHONDONTWRITEBYTECODE='1')
        cases = []
        server = None
        thread = None
        state = {'code': 200, 'nodes': 6}
        def put(p, text):
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text, encoding='utf-8')
        def copied_gate(rel):
            dst = base / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / rel, dst)
            assert hashlib.sha256(dst.read_bytes()).digest() == hashlib.sha256((ROOT / rel).read_bytes()).digest()
            return ['bash', str(dst)]
        def case(label, p, good, bad):
            put(p, good)
            cases.append((label, lambda p=p, good=good: put(p, good),
                          lambda p=p, bad=bad: put(p, bad)))
        if name == 'otel':
            cmd = copied_gate('tools/gates/otel-coverage.sh')
            put(base / 'docker-compose.yml', 'services:\n  m4-service:\n    image: unused\nvolumes: {}\n')
            put(base / 'config/canonical/otel-coverage-debt.txt', '')
            good = 'scrape_configs:\n- job_name: m4-service\n'
            case('compose service has no scrape job', base / 'observability/prometheus/prometheus.yml',
                 good, 'scrape_configs: []\n')
            put(base / 'config/canonical/otel-span-registry.txt', 'scripts/emitter.sh|otel_span_emit\n')
            case('registered component has no span marker', base / 'scripts/emitter.sh',
                 '# static fixture: otel_span_emit\n', '# static fixture: marker removed\n')
            result['limitation'] = 'Static job/marker coverage, not actual OTLP delivery.'
        elif name == 'kernel':
            cmd = copied_gate('tools/gates/kernel-wiring.sh')
            put(base / 'runtime/manifests/kernels.yaml', 'entries:\n- name: mfixture\n')
            (base / 'runtime/crates/aigon-kernel-mfixture').mkdir(parents=True)
            case('kernel crate has no registration', base / 'runtime/crates/aigon-runtime/src/lib.rs',
                 'aigon_kernel_mfixture::FixtureKernel\n', '// registration removed\n')
            case('kernel has no manifest entry', base / 'runtime/manifests/kernels.yaml',
                 'entries:\n- name: mfixture\n', 'entries: []\n')
            result['limitation'] = 'Tests static registration consistency, not kernel tick execution.'
        elif name == 'cerberus':
            cmd = ['bash', str(ROOT / 'tools/gates/cerberus-e2e.sh')]
            env.update(AIGON_CERBERUS_FULL='0', AIGON_CE_PIPELINE=str(ROOT / 'runtime/tools/cerberus-e2e-pipeline.sh'),
                       AIGON_CE_SUMMARY=str(base / 'summary'))
            if not (ROOT / 'runtime/tools/cerberus-e2e-pipeline.sh').is_file():
                result['reason'] = 'actual pipeline file prerequisite absent'
                return result
            good = 'status=pass\npassed=1\nfailed=0\ntest_count=1\n'
            case('pipeline artifact status fail', base / 'summary', good,
                 'status=fail\npassed=0\nfailed=1\ntest_count=1\n')
            case('pipeline artifact failed tests', base / 'summary', good,
                 'status=pass\npassed=0\nfailed=1\ntest_count=1\n')
            result['limitation'] = 'Tests summary consumer only; full pipeline never invoked.'
        else:
            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(state['code']); self.end_headers()
                    self.wfile.write(json.dumps({'mesh': {'nodes': [{'status': 'online'}] * state['nodes']}}).encode())
                def log_message(self, *args):
                    pass
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            env['AIGON_RUNTIME_URL'] = 'http://127.0.0.1:%d' % server.server_address[1]
            # Disregard host proxy settings so transport cannot leave loopback.
            env['NO_PROXY'] = env['no_proxy'] = '127.0.0.1'
            if name == 'mesh':
                env['AIGON_MP_MIN'] = '6'
                cmd = ['bash', str(ROOT / 'tools/gates/mesh-presence.sh')]
                cases.append(('mesh loses quorum nodes', lambda: state.update(nodes=6), lambda: state.update(nodes=5)))
                result['limitation'] = 'Tests node count consumer, not real mesh connectivity or online filtering.'
            else:
                cmd = copied_gate('tools/gates/health-8.sh')
                put(base / 'config/mesh-nodes.yaml', 'nodes:\n  local:\n    ip: 127.0.0.1\n    ssh: null\n')
                env.update(AIGON_HEALTH8_SKIP_SSH='1', AIGON_HEALTH8_WAIT_SECS='0', AIGON_HEALTH8_RETRY_EVERY='1')
                cases.append(('registered node HTTP failure', lambda: state.update(code=200), lambda: state.update(code=503)))
                result['limitation'] = 'Tests HTTP status consumer on isolated local endpoint; no remote nodes contacted.'
        try:
            for label, good, broken in cases:
                good(); before = run(cmd, env, base)
                broken(); negative = run(cmd, env, base)
                good(); restored = run(cmd, env, base)
                result['mutations'].append({'name': label, 'transition': [before['rc'], negative['rc'], restored['rc']],
                                            'outputs': [before['output'], negative['output'], restored['output']]})
            result['status'] = 'PASS' if result['mutations'] and all(
                m['transition'] == [0, 1, 0] for m in result['mutations']) else 'FAIL'
        finally:
            if server:
                server.shutdown(); server.server_close(); thread.join(timeout=2)
                if thread.is_alive():
                    raise RuntimeError('fixture HTTP server did not stop')
    return result

with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
    results = list(pool.map(suite, ['otel', 'kernel', 'cerberus', 'mesh', 'health']))
pending = []  # Measured by completion, safety_secret, memory and drift suites.
print(json.dumps({'suite': 'M4 isolated extra fitness', 'results': results, 'pending': pending,
                  'verified_laws': sum(len(r['laws']) for r in results if r['status'] == 'PASS'),
                  'fixture_directories_cleaned': 5, 'fixture_http_servers_stopped': 2}, ensure_ascii=False, indent=2))
sys.exit(1 if any(r['status'] == 'FAIL' for r in results) else 0)
PY
