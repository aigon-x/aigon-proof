#!/usr/bin/env bash
# M4 drafts/tests only. Run actual, byte-identical adapters and verify modules
# in private fixtures. Declarative/token detection is NOT behavioral coverage.
set -euo pipefail
# Strip repository selectors before any fixture interpreter or git invocation.
for m4_git_env in ${!GIT_@}; do unset "$m4_git_env"; done
unset PYTHONOPTIMIZE PYTHONPATH
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 - "$ROOT" <<'PY'
import os, pathlib, re, shutil, sqlite3, subprocess, sys, tempfile, time
import yaml

source = pathlib.Path(sys.argv[1])
mapping = yaml.safe_load((source/'config/canonical/constitution-fitness-map.yaml').read_text())['fitness']
cases = []
def add(adapter, files, mutations, scope='declarative'):
    cases.append((adapter, files, mutations, scope))
actions = 'system/control-plane/state/actions/check.action'
add('action-proof', {actions:'POSTCONDITION="test -f ./present"\n', 'present':'yes'}, [
    ('missing declaration', {actions:'ACTION=check\n'}, 'ACTION-PROOF-002'),
    ('unverifiable declaration', {actions:'POSTCONDITION="healthy"\n'}, 'ACTION-PROOF-003')])
add('postcondition', {actions:'POSTCONDITION="./present"\n', 'present':'yes'}, [
    ('missing target', {'present':None}, 'POSTCONDITION-001'),
    ('false command', {actions:'POSTCONDITION="test 1 -eq 2"\n'}, 'POSTCONDITION-001'),
    ('missing declaration', {actions:'ACTION=check\n'}, 'POSTCONDITION-002')], 'fixture postcondition execution')
add('configuration', {'config/source.yaml':'enabled: true\n'}, [
    ('empty config', {'config/source.yaml':None}, 'CONFIGURATION-003')])
test = '#!/usr/bin/env bash\nset -eu\n# isolated nonempty declared test fixture\ntest 1 -eq 1\n'
add('testing', {'tools/verify/gates/tests/test_fixture.sh':test}, [
    ('empty test', {'tools/verify/gates/tests/test_fixture.sh':''}, 'TESTING-002'),
    ('bypass', {'tools/verify/gates/tests/test_fixture.sh':test+'false || true\n'}, 'TESTING-003'),
    ('unset-variable checks removed', {'tools/verify/gates/tests/test_fixture.sh':test.replace('set -eu','set -e')}, 'TESTING-004')])
readme = '# Fixture Purpose\n'+'Actual documented fixture content.\n'*8
add('contracts', {'README.md':readme}, [
    ('missing readme', {'README.md':None}, 'CONTRACTS-001'),
    ('placeholder', {'README.md':readme+'TODO\n'}, 'CONTRACTS-002'),
    ('short readme', {'README.md':'# Fixture Purpose\n'}, 'CONTRACTS-004')])
add('documentation', {'docs/fixture.md':'Complete documentation.\n'}, [
    ('missing docs directory', {'docs':None}, 'DOCUMENTATION-001')])
migration = 'system/control-plane/state/migrations/0004_system_twin.sql'
add('system-twin', {migration:'CREATE TABLE system_twin_node(x);\nCREATE TABLE system_twin_edge(x);\n',
    'system/control-plane/state/lib.sh':'STATE_SCHEMA_VERSION="4"\n', 'present':'fixture component\n', 'fixture-twin-state':'valid'}, [
    ('missing node table', {migration:'CREATE TABLE system_twin_edge(x);\n'}, 'SYSTEM-TWIN-002'),
    ('missing edge table', {migration:'CREATE TABLE system_twin_node(x);\n'}, 'SYSTEM-TWIN-003'),
    ('schema mismatch', {'system/control-plane/state/lib.sh':'STATE_SCHEMA_VERSION="3"\n'}, 'SYSTEM-TWIN-004'),
    ('declared component absent', {'present':None}, 'SYSTEM-TWIN-005'),
    ('orphan source node', {'fixture-twin-state':'orphan'}, 'SYSTEM-TWIN-006')], 'declarations plus isolated SQLite path/source-edge predicates')
registry = 'runtime/tools/sigil/config/registry.yaml'
state = 'system/control-plane/state/state.sh'
res_migration = 'system/control-plane/state/migrations/0014_resilience.sql'
res_files = {registry:'resilience:\n  rto: 1\n  rpo: 1\n  restore_drill_max_age: 1\n  dr_game_day_max_age: 1\n  floors: {}\n',
    state:'# backup restore backup-restore-test backup-verify sha256 backup-retention\n',
    'tools/resilience/restore-drill/restore-drill.sh':'# fixture declaration\n',
    res_migration:''.join('CREATE TABLE '+t+'(x);\n' for t in ('backup_catalog','resilience_requirements','game_days','spof_findings'))}
add('resilience', res_files, [
    ('missing rpo', {registry:res_files[registry].replace('  rpo: 1\n','')}, 'RES-B-01'),
    ('missing drill', {'tools/resilience/restore-drill/restore-drill.sh':None}, 'RES-B-02'),
    ('missing integrity declaration', {state:res_files[state].replace('sha256','')}, 'RES-B-03'),
    ('missing retention', {state:res_files[state].replace('backup-retention','')}, 'RES-B-04')])
gate_reg = 'config/canonical/gate-registry.yaml'
reg = 'gates:\n  - gate_id: FIXTURE\n    status: IMPLEMENTED\n    blocking: true\n    command: scripts/executor.sh\n'
add('autonomy-level', {gate_reg:reg, 'scripts/executor.sh':'#!/bin/sh\nexit 0\n'}, [
    ('missing declared executor', {'scripts/executor.sh':None}, 'AUTONOMY-LEVEL-001')])
profile = 'config/agent-models.yaml'
safe_profile = 'ollama:\n  profiles:\n    cpu:\n      num_ctx: 4096\n      num_parallel: 1\n      keep_alive_secs: 10\n'
add('predictive-resource', {profile:safe_profile}, [
    ('permanent CPU residency', {profile:safe_profile.replace('keep_alive_secs: 10','keep_alive_secs: -1')}, 'PREDICTIVE-RESOURCE-001'),
    ('excessive KV', {profile:safe_profile.replace('num_ctx: 4096','num_ctx: 65537')}, 'PREDICTIVE-RESOURCE-001')], 'configuration arithmetic')
life_path = 'docs/00-foundation/LIFECYCLE.md'
life_doc = ('IDEA DISCOVERING DEFINED CONTRACTED DESIGNED IMPLEMENTING VERIFYING INTEGRATING HARDENING RELEASING STAGING CERTIFIED CANARY PRODUCTION OPERATING DEPRECATED RETIRED\nF00 F17 G0 G17\n'
    'CHANGE_ID REQUIREMENT_ID CONTRACT_ID DESIGN_ID CODE_ID TEST_ID GATE_ID BUILD_ID ARTIFACT_ID RELEASE_ID DEPLOYMENT_ID RUNTIME_ID EVIDENCE_ID VERIFICATION_ID\n')
add('lifecycle', {life_path:life_doc, 'tools/verify/gates/registry.sh':'# GATE-040\n'}, [
    ('missing phase', {life_path:life_doc.replace('F17','')}, 'LIFECYCLE-004'),
    ('incomplete state sequence', {life_path:life_doc.replace('VERIFYING','')}, 'LIFECYCLE-003')])
recovery = 'system/control-plane/state/state.sh'
recovery_text = '#!/usr/bin/env bash\nset -euo pipefail\n# backup restore\n'
add('recovery', {recovery:recovery_text}, [
    ('missing backup declaration', {recovery:recovery_text.replace('backup','')}, 'RECOVERY-002'),
    ('missing restore declaration', {recovery:recovery_text.replace('restore','')}, 'RECOVERY-003')])
obs_path = 'config/canonical/observability.yaml'
obs = 'metrics:\n  - name: fixture_requests_total\n    type: counter\n    unit: count\n    description: Requests\n    labels: [node]\ncardinality:\n  forbidden_labels: [user_id]\n  max_labels: 5\n'
add('obs-metrics', {obs_path:obs}, [
    ('invalid naming', {obs_path:obs.replace('fixture_requests_total','badname')}, 'OBS-03'),
    ('missing unit', {obs_path:obs.replace('    unit: count\n','')}, 'OBS-06'),
    ('high cardinality', {obs_path:obs.replace('labels: [node]','labels: [user_id]')}, 'OBS-03')], 'manifest schema validation')
add('memory-integrity', {'fixture-memory-state':'fresh'}, [
    ('old pending with live owner', {'fixture-memory-state':'old'}, 'MEMORY-INTEGRITY-001')], 'isolated SQLite age/live-owner predicate')
audit = 'bin/pip-audit'
audit_ok = '#!/bin/sh\necho "No vulnerabilities found"\nexit 0\n'
add('deps-cve', {'requirements.txt':'fixture==1.0\n',audit:audit_ok}, [
    ('audit reports vulnerability', {audit:'#!/bin/sh\necho "fixture CVE-TEST vulnerability"\nexit 1\n'}, 'DEPS-CVE podsumowanie')], 'fake scanner CLI failure protocol only')
add('complexity-governor', {'fixture.py':'pass\n'*5}, [
    ('god file grows', {'fixture.py':'pass\n'*6}, 'COMPLEXITY-GOVERNOR-001')], 'staged god-file growth above threshold')

# These modules only grep a QG token: test precisely that declaration predicate.
# No throughput, revocation, ordering, budget, or autoscaling is performed.
seen = {x[0] for x in cases}
for value in mapping.values():
    adapter = pathlib.Path(value['cmd'])
    if adapter.parent != pathlib.Path('tools/gates') or adapter.stem in seen:
        continue
    text = (source/adapter).read_text()
    target = re.search(r'CANONICAL="\$ROOT/([^"\n]+)"', text)
    if not target or not (source/target[1]).is_file():
        continue
    implementation = (source/target[1]).read_text()
    if 'EVIDENCE_ROOT="artifacts/quality-gates"' not in implementation:
        continue
    token = re.search(r'grep -qi "(G\d+)"', implementation)
    heading = re.search(r'fail "(GATE-\d+) dowod deklaracji"', implementation)
    if not token or not heading:
        raise SystemExit('Unsupported declarative executor '+str(adapter))
    seen.add(adapter.stem)
    add(adapter.stem, {'artifacts/quality-gates/coverage-matrix-qg300.md':token[1]+'\n'}, [
        ('missing QG declaration', {'artifacts/quality-gates/coverage-matrix-qg300.md':'unrelated declaration\n'}, heading[1]+' dowod deklaracji')], 'token declaration only')

def write(root, files):
    for name, content in files.items():
        p = root/name
        if content is None:
            if p.is_dir(): shutil.rmtree(p)
            else: p.unlink(missing_ok=True)
        else:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content)
            if name.startswith('bin/'): p.chmod(0o755)

checks = failures = 0
for adapter, baseline, mutations, scope in cases:
    failures_before = failures
    with tempfile.TemporaryDirectory(prefix='m4-declared-') as scratch:
        root = pathlib.Path(scratch)
        relative = pathlib.Path('tools/gates')/(adapter+'.sh')
        target_match = re.search(r'CANONICAL="\$ROOT/([^"\n]+)"', (source/relative).read_text())
        if not target_match: raise SystemExit('Cannot resolve adapter '+adapter)
        for rel in (relative, pathlib.Path(target_match[1]), pathlib.Path('tools/verify/core/lib.sh')):
            (root/rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source/rel, root/rel)
        write(root, baseline)
        db = root/'system/control-plane/state/data/canonical-state.db'
        db.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(db) as conn:
            conn.executescript('CREATE TABLE evidence(evidence_id TEXT PRIMARY KEY, claim TEXT, source_type TEXT, source_ref TEXT, created_at TEXT);'+
                ''.join('CREATE TABLE "'+t+'"(x);' for t in ('requirement','change','verification','release')))
        env = {k:v for k,v in os.environ.items() if not k.startswith(('VERIFY_', '__VERIFY_', 'AIGON_SSOT', 'GIT_'))}
        env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_COUNT='1',
                   GIT_CONFIG_KEY_0='core.hooksPath', GIT_CONFIG_VALUE_0='/dev/null')
        env.update(__VERIFY_ROOT=str(root), VERIFY_STATE_DB=str(db))
        env['AIGON_SSOT'] = str(root/'config/agent-models.yaml')
        env['PATH'] = str(root/'bin')+os.pathsep+os.environ['PATH']
        env['AIGON_HERMES_DB'] = str(root/'hermes-fixture.db')
        env['AIGON_MEMORY_MAX_PENDING_H'] = '6'
        env['AIGON_GOD_FILE_LINES'] = '3'
        if adapter == 'complexity-governor':
            for args in (['init','-q'],['add','fixture.py'],['-c','user.name=M4 fixture','-c','user.email=m4@example.invalid','-c','commit.gpgsign=false','commit','-qm','fixture baseline']):
                subprocess.run(['git','-c','core.hooksPath=/dev/null',*args],cwd=root,env=env,check=True,capture_output=True)
        def verify(label, expected, claim):
            global checks, failures
            checks += 1
            if adapter == 'system-twin':
                with sqlite3.connect(db) as conn:
                    conn.executescript('CREATE TABLE IF NOT EXISTS system_twin_node(node_id TEXT,declared TEXT); CREATE TABLE IF NOT EXISTS system_twin_edge(from_node TEXT,to_node TEXT); DELETE FROM system_twin_node; DELETE FROM system_twin_edge;')
                    conn.execute('INSERT INTO system_twin_node VALUES(?,?)',('fixture','./present'))
                    from_node = 'absent' if (root/'fixture-twin-state').read_text() == 'orphan' else 'fixture'
                    conn.execute('INSERT INTO system_twin_edge VALUES(?,?)',(from_node,'fixture'))
            if adapter == 'memory-integrity':
                with sqlite3.connect(env['AIGON_HERMES_DB']) as conn:
                    conn.execute('CREATE TABLE IF NOT EXISTS async_delegations(delegation_id TEXT,state TEXT,dispatched_at REAL,completed_at REAL,owner_pid INTEGER,delivery_state TEXT)')
                    conn.execute('DELETE FROM async_delegations')
                    age = 7*3600 if (root/'fixture-memory-state').read_text() == 'old' else 10
                    conn.execute('INSERT INTO async_delegations VALUES(?,?,?,?,?,?)',('fixture','completed',time.time()-age,time.time()-5,os.getpid(),'pending'))
            if adapter == 'complexity-governor':
                subprocess.run(['git','-c','core.hooksPath=/dev/null','add','fixture.py'],cwd=root,env=env,check=True,capture_output=True)
            try:
                result = subprocess.run(['bash',str(root/relative)],cwd=root,env=env,capture_output=True,text=True,timeout=20)
                output = result.stdout+result.stderr
                marker = '[FAIL] '+claim if expected else 'CERTIFICATION: PASS'
                okay = result.returncode == expected and marker in output and 'EVIDENCE-STORE-UNWRITABLE' not in output
                if not okay:
                    failures += 1
                    print(f'FAIL {adapter}: {label}, expected rc={expected}/{marker}, actual rc={result.returncode}\n{output}')
            except subprocess.TimeoutExpired:
                failures += 1
                print('FAIL '+adapter+': timeout, NOT_RUN')
        verify('baseline',0,'')
        for label, mutation, claim in mutations:
            write(root,mutation)
            verify(label,1,claim)
            write(root,baseline)
            verify('restored '+label,0,'')
        laws = [law for law,v in mapping.items() if v['cmd'] == str(relative)]
        print(f'CHECKED {adapter}: laws={",".join(laws)} negatives={len(mutations)} scope={scope}')
        for law in laws:
            status = 'PASS' if failures == failures_before else 'FAIL'
            print(f'M4_RESULT {law} {status} mutants={len(mutations)} scope={scope.replace(" ","-")}', flush=True)
print(f'M4 declared FITNESS: executors={len(cases)} negative_cases={sum(len(c[2]) for c in cases)} checks={checks} failures={failures}')
sys.exit(bool(failures))
PY
