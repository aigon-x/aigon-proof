#!/usr/bin/env bash
# M4 completion: scoped query input, real HTTP swarm fixture, real local HA drill.
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
import yaml

ROOT = Path(os.environ['M4_SOURCE_ROOT'])

def run(cmd, env, cwd):
    try:
        p = subprocess.run(cmd, env=env, cwd=cwd, capture_output=True, text=True, timeout=25)
        return {'rc': p.returncode, 'output': (p.stdout + p.stderr)[-5000:]}
    except subprocess.TimeoutExpired:
        return {'rc': 124, 'output': 'measurement timeout'}

def suite(name):
    result = {'executor': name, 'laws': {'registry': ['LAW-6'], 'swarm': ['LAW-18', 'LAW-95'],
               'ha': ['LAW-23', 'LAW-25', 'LAW-61']}[name], 'status': 'UNKNOWN', 'mutations': []}
    servers = []
    def start(handler, port=0):
        server = ThreadingHTTPServer(('127.0.0.1', port), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start(); servers.append((server, thread))
        return server, thread
    def stop(server, thread):
        server.shutdown(); server.server_close(); thread.join(timeout=2)
        if thread.is_alive(): raise RuntimeError('fixture server did not stop')
    def request(url):
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                return r.status, json.loads(r.read())
        except Exception:
            return 0, {}
    try:
        with tempfile.TemporaryDirectory(prefix='m4-fitness-completion-') as tmp:
            base = Path(tmp)
            env = os.environ.copy()
            env.update(LC_ALL='C', PYTHONDONTWRITEBYTECODE='1', NO_PROXY='127.0.0.1', no_proxy='127.0.0.1')
            cases = []
            def put(path, value):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(value, encoding='utf-8')
            def case(label, path, good, broken):
                put(path, good)
                cases.append((label, lambda: put(path, good), lambda: put(path, broken)))
            if name == 'registry':
                (base / 'runtime/knowledge/canon/products/mfixture').mkdir(parents=True)
                products = base / 'products.txt'
                env.update(__VERIFY_ROOT=str(base), AIGON_REGISTRY_PRODUCTS_FILE=str(products),
                           AIGON_REGISTRY_SSOT=socket.gethostname())
                case('registry contains orphan product', products, 'mfixture\n', 'mfixture\norphan\n')
                case('registry count diverges from canon', products, 'mfixture\n', '')
                cmd = ['bash', str(ROOT / 'tools/verify/gates/domains/registry-coherence.sh')]
                result['limitation'] = 'Recorded query input exercises actual coherence comparison; no production PostgreSQL read.'
            elif name == 'swarm':
                class Handler(BaseHTTPRequestHandler):
                    def do_GET(self):
                        self.send_response(200); self.end_headers()
                        self.wfile.write(json.dumps({'runtime': {'mesh': {'healthy_peers': 2,
                            'has_quorum': True, 'nodes': [{}, {}]}}}).encode())
                    def log_message(self, *args): pass
                server, thread = start(Handler)
                guard, ssot = base / 'guard.py', base / 'config.yaml'
                env.update(AIGON_SWARM_PROJECT_ROOT=str(base), AIGON_SWARM_GUARD=str(guard),
                           AIGON_SWARM_SSOT=str(ssot), AIGON_SWARM_HEALTH_URL='http://127.0.0.1:%d/health' % server.server_port)
                case('swarm enforcer marker removed', guard, '# LAW-F5\n', '# missing enforcer\n')
                case('swarm hook wiring removed', ssot,
                     '    PreToolUse:\n    - matcher: "Task|Workflow"\n', '    PostToolUse: []\n')
                cmd = ['bash', str(ROOT / 'tools/gates/fitness/law-f5-swarm-fit.sh')]
                result['limitation'] = 'Exercises fixture health API plus real hook/enforcer validation; no inference dispatch.'
            else:
                def backend(identity):
                    class Handler(BaseHTTPRequestHandler):
                        def do_GET(self):
                            self.send_response(200); self.end_headers()
                            self.wfile.write(json.dumps({'served_by': identity}).encode())
                        def log_message(self, *args): pass
                    return Handler
                primary, pt = start(backend('primary'))
                peer, qt = start(backend('peer'))
                purl, qurl = ('http://127.0.0.1:%d/' % s.server_port for s in (primary, peer))
                class Balancer(BaseHTTPRequestHandler):
                    def do_GET(self):
                        for url in (purl, qurl):
                            code, data = request(url)
                            if code == 200:
                                self.send_response(200); self.end_headers()
                                self.wfile.write(json.dumps(data).encode()); return
                        self.send_response(503); self.end_headers()
                    def log_message(self, *args): pass
                lb, lt = start(Balancer)
                channel = 'http://127.0.0.1:%d/' % lb.server_port
                observations = []
                def observe(phase):
                    code, data = request(channel)
                    bcode, _ = request(purl)
                    observations.append({'phase': phase, 'channel_http': code,
                                         'backend_http': bcode, 'served_by': data.get('served_by')})
                started = time.monotonic_ns()
                observe('before')
                port = primary.server_port
                stop(primary, pt); servers.remove((primary, pt))
                observe('stopped')
                primary, pt = start(backend('primary'), port)
                observe('restored')
                if [o['backend_http'] for o in observations] != [200, 0, 200]:
                    raise RuntimeError('local failover drill did not stop and restore backend')
                evidence = {'schema_version': 1, 'status': 'executed', 'duration_ns': time.monotonic_ns() - started,
                            'evidence_id': str(uuid.uuid4()), 'timestamp': time.time(), 'service': 'mcp_gate',
                            'channel_url': channel, 'backend_url': purl, 'observations': observations}
                topology = {'services': {'mcp_gate': {'ha': 'replicated', 'adres_agenta': channel,
                    'backends': [{'node': 'primary', 'url': purl}, {'node': 'peer', 'url': qurl}]}}}
                config, drill = base / 'ha.yaml', base / 'drill.json'
                put(config, yaml.safe_dump(topology))
                env.update(AIGON_PROJECT_ROOT=str(base), AIGON_HA_SSOT=str(config),
                           AIGON_HA_DRILL_EVIDENCE=str(drill), AIGON_HA_EXECUTE_FAILOVER='0')
                good = json.dumps(evidence)
                skipped = dict(evidence, status='skipped')
                case('skipped drill cannot prove success', drill, good, json.dumps(skipped))
                stale = dict(evidence, timestamp=time.time() - 90000)
                case('stale drill rejected', drill, good, json.dumps(stale))
                broken = json.loads(good); broken['observations'][1]['channel_http'] = 503
                case('channel failed during stopped phase', drill, good, json.dumps(broken))
                broken = json.loads(good); broken['observations'][2]['backend_http'] = 0
                case('backend not restored after drill', drill, good, json.dumps(broken))
                broken = json.loads(good); broken['observations'][1]['served_by'] = 'unregistered-peer'
                case('unregistered peer cannot prove failover', drill, good, json.dumps(broken))
                case('replication below required backend count', config, yaml.safe_dump(topology),
                     yaml.safe_dump({'services': {'mcp_gate': dict(topology['services']['mcp_gate'],
                                      backends=topology['services']['mcp_gate']['backends'][:1])}}))
                cmd = ['bash', str(ROOT / 'tools/gates/ha-failover.sh')]
                result['drill_observations'] = observations
                result['limitation'] = 'Actual isolated HTTP backend stop/failover/restore; validates recorded scoped drill, not production Docker failover.'
            for label, good, broken in cases:
                good(); before = run(cmd, env, base)
                broken(); negative = run(cmd, env, base)
                good(); restored = run(cmd, env, base)
                result['mutations'].append({'name': label, 'transition': [before['rc'], negative['rc'], restored['rc']],
                                            'outputs': [before['output'], negative['output'], restored['output']]})
            result['status'] = 'PASS' if result['mutations'] and all(
                m['transition'] == [0, 1, 0] for m in result['mutations']) else 'FAIL'
    finally:
        for server, thread in reversed(servers): stop(server, thread)
    return result

with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    results = list(pool.map(suite, ['registry', 'swarm', 'ha']))
report = {'suite': 'M4 completion fitness', 'results': results,
          'verified_laws': sum(len(r['laws']) for r in results if r['status'] == 'PASS'),
          'fixture_directories_cleaned': 3}
print(json.dumps(report, ensure_ascii=False, indent=2))
sys.exit(1 if any(r['status'] != 'PASS' for r in results) else 0)
PY
