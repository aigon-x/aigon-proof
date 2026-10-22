#!/usr/bin/env bash
# M4: actual FITNESS executors, copied without modification to isolated fixtures.
# Each mutation must yield rc=1 plus FAIL; restoration must yield rc=0 plus PASS.
# Missing measurement (rc=2), crashes, timeout, and NOT_RUN never count as detection.
# Only file predicates are covered: no claim of live/auth/MFA/scatter execution.
set -euo pipefail
# Strip repository selectors before any fixture interpreter or git invocation.
for m4_git_env in ${!GIT_@}; do unset "$m4_git_env"; done
unset PYTHONOPTIMIZE PYTHONPATH
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 - "$ROOT" <<'PY'
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1])
cases = []
def case(law, files, mutations):
    cases.append((law, files, mutations))

case('1', {'runtime/crates/demo/src/lib.rs': 'fn clean() {}\n'}, [
    ('unallowlisted debt marker', {'runtime/crates/demo/src/lib.rs': 'fn clean() { /* TODO: injected */ }\n'}),
])
case('2', {'docker-compose.yml': 'services:\n  db:\n    image: postgres\n'}, [
    ('postgres trust', {'docker-compose.yml': 'POSTGRES_HOST_AUTH_METHOD: trust\n'}),
    ('auth disabled', {'docker-compose.yml': 'command: server --no-auth\n'}),
    ('allow all', {'docker-compose.yml': 'command: server --allow-all\n'}),
    ('surreal missing credentials', {'docker-compose.yml': 'command: start surrealkv://data\n'}),
    ('vault dev', {'docker-compose.yml': 'command: vault server -dev\n'}),
])
capabilities = 'entries:\n  - name: compute\n  - name: inference\n  - name: storage\n  - name: mesh\n  - name: vision\n  - name: speech\n'
case('15', {'runtime/manifests/capabilities.yaml': capabilities}, [
    ('missing '+name, {'runtime/manifests/capabilities.yaml': capabilities.replace('  - name: '+name+'\n', '')})
    for name in ('compute', 'inference', 'storage', 'mesh', 'vision', 'speech')
])
case('24', {
    'runtime/manifests/mesh.yaml': 'roles:\n  worker:\n    capabilities: [compute]\n',
    'runtime/manifests/schedulers.yaml': 'entries:\n  - name: distributed\n',
}, [
    ('missing roles', {'runtime/manifests/mesh.yaml': 'peers: []\n'}),
    ('missing capabilities', {'runtime/manifests/mesh.yaml': 'roles:\n  worker: {}\n'}),
    ('single host scheduler', {'runtime/manifests/schedulers.yaml': 'entries:\n  - name: single-host\n'}),
    ('hardcoded decision IP', {'runtime/manifests/schedulers.yaml': 'entries:\n  - name: distributed\n    target: "192.0.2.1"\n'}),
])
case('26', {
    'runtime/manifests/mesh.yaml': 'peers:\n  - "192.0.2.1:7000"\n  - "192.0.2.2:7000"\n',
    'config/mesh-nodes.yaml': 'nodes:\n  one:\n    ip: 192.0.2.1\n  two:\n    ip: 192.0.2.2\n',
    'runtime/pipelines/work.sh': '# scatter executor fixture\n',
    'runtime/crates/fixture.txt': 'fixture\n',
    'scripts/fixture.txt': 'fixture\n',
}, [
    ('single peer', {'runtime/manifests/mesh.yaml': 'peers:\n  - "192.0.2.1:7000"\n'}),
    ('single registered node', {'config/mesh-nodes.yaml': 'nodes:\n  one:\n    ip: 192.0.2.1\n'}),
    ('missing scatter mechanism', {'runtime/pipelines/work.sh': '# empty fixture\n'}),
])
case('49', {
    'tools/gates/functional-benchmark.sh': '# executor presence fixture\n',
    'config/canonical/hooks.yaml': 'gate: functional-benchmark\n',
}, [
    ('missing executor', {'tools/gates/functional-benchmark.sh': None}),
    ('missing recurring hook', {'config/canonical/hooks.yaml': 'gate: unrelated\n'}),
])
case('79', {
    'config/canonical/constitution.generated.yaml': 'id: "LAW-79"\n',
    'config/agent-models.yaml': 'persona_chat:\n  agent:\n    persona: true\n',
}, [
    ('unregistered law', {'config/canonical/constitution.generated.yaml': 'id: "LAW-1"\n'}),
    ('missing persona section', {'config/agent-models.yaml': 'agents:\n  agent:\n    persona: true\n'}),
    ('disabled persona', {'config/agent-models.yaml': 'persona_chat:\n  agent:\n    persona: false\n'}),
])
card = 'spawn_card:\n  - capabilities\n  - skills\n  - tools\n  - limits\n'
case('80', {'config/dynamic-agent.yaml': card, 'scripts/spawn-dynamic-agent.py': '# consumer presence fixture\n'}, [
    ('missing contract', {'config/dynamic-agent.yaml': None}),
    ('missing spawn_card', {'config/dynamic-agent.yaml': card.replace('spawn_card:', 'unrelated:')}),
    *[('missing '+field, {'config/dynamic-agent.yaml': card.replace('  - '+field+'\n', '')}) for field in ('capabilities', 'skills', 'tools', 'limits')],
    ('missing consumer', {'scripts/spawn-dynamic-agent.py': None}),
])
pin = ('enabled: true\nsignature:\n  enabled: true\n  allowed_signers: config/allowed_signers\n'
       'pin:\n  length: 6\ncritical_operations:\n  data.destroy: {}\n  secrets.rotate: {}\n'
       '  vault.unseal: {}\n  runtime.redeploy: {}\n  firewall.change: {}\n')
pin_files = {'config/sovereign-ops-pin.yaml': pin,
             'config/allowed_signers': 'fixture ssh-ed25519 FAKE_TEST_PUBLIC_KEY\n',
             'scripts/sovereign-ops-pin.py': '# ed25519 verify-signature gate exit 1\n'}
case('omega-3', pin_files, [
    ('disabled signature', {'config/sovereign-ops-pin.yaml': pin.replace('signature:\n  enabled: true', 'signature:\n  enabled: false')}),
    ('missing signers', {'config/allowed_signers': None}),
    ('empty signers', {'config/allowed_signers': '# no registered public key\n'}),
    ('missing asymmetric verification', {'scripts/sovereign-ops-pin.py': '# verify-signature gate exit 1\n'}),
    ('missing verification path', {'scripts/sovereign-ops-pin.py': '# ed25519 gate exit 1\n'}),
    ('missing MFA', {'config/sovereign-ops-pin.yaml': pin.replace('  length: 6', '  length: 0')}),
])
case('omega-4', pin_files, [
    ('disabled gate', {'config/sovereign-ops-pin.yaml': pin.replace('enabled: true', 'enabled: false', 1)}),
    *[('missing '+operation, {'config/sovereign-ops-pin.yaml': pin.replace('  '+operation+': {}\n', '')})
      for operation in ('data.destroy', 'secrets.rotate', 'vault.unseal', 'runtime.redeploy', 'firewall.change')],
    ('missing second factor', {'config/sovereign-ops-pin.yaml': pin.replace('signature:\n  enabled: true', 'signature:\n  enabled: false').replace('  length: 6', '  length: 0')}),
    ('missing deny contract', {'scripts/sovereign-ops-pin.py': '# ed25519 verify-signature\n'}),
])
registry = 'laws:\n  - LAW-Ω9\n  - LAW-Ω0\n  - LAW-Ω1\n  - LAW-Ω2\n'
case('omega-9', {'config/canonical/constitution.generated.yaml': registry,
                 'config/agent-models.yaml': 'system_prompt: LAW-Ω0\n'}, [
    *[('missing '+law, {'config/canonical/constitution.generated.yaml': registry.replace('  - '+law+'\n', '')})
      for law in ('LAW-Ω9', 'LAW-Ω0', 'LAW-Ω1', 'LAW-Ω2')],
    ('missing prompt core', {'config/agent-models.yaml': 'system_prompt: unrelated\n'}),
])

def write(root, files):
    for name, content in files.items():
        path = root / name
        if content is None:
            path.unlink(missing_ok=True)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding='utf-8')

checks = failures = 0
for law, baseline, mutations in cases:
    with tempfile.TemporaryDirectory(prefix='m4-fitness-') as scratch:
        root = pathlib.Path(scratch)
        relative = pathlib.Path('tools/gates/fitness') / ('law-'+law+'-fit.sh')
        (root / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / relative, root / relative)
        write(root, baseline)
        # Prevent inherited overrides from selecting real production objects.
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('LAW_OMEGA_', 'AIGON_LAW26_'))}
        def verify(label, expected):
            global checks, failures
            checks += 1
            try:
                result = subprocess.run(['bash', str(root / relative)], cwd=root,
                                        env=env, capture_output=True, text=True, timeout=15)
                text = result.stdout + result.stderr
                marker = 'PASS' if expected == 0 else 'FAIL'
                okay = result.returncode == expected and marker in text
                if not okay:
                    failures += 1
                    print(f'FAIL LAW-{law} {label}: wanted rc={expected}/{marker}, got rc={result.returncode}\n{text}')
            except subprocess.TimeoutExpired:
                failures += 1
                print(f'FAIL LAW-{law} {label}: executor timeout, NOT_RUN')
        verify('baseline', 0)
        for name, mutation in mutations:
            write(root, mutation)
            verify(name, 1)
            write(root, baseline)
            verify('restored after '+name, 0)
        print(f'CHECKED LAW-{law}: {len(mutations)} mutations, actual copied executor')
print(f'M4 file FITNESS: laws={len(cases)} negative_cases={sum(len(c[2]) for c in cases)} checks={checks} failures={failures}')
sys.exit(1 if failures else 0)
PY
