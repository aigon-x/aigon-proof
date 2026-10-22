#!/usr/bin/env bash
# Actual LAW53/56 adapters and byte-identical executors in isolated fixtures.
# Runtime inventory is served by local HTTP, limits use real limits-render.py.
# No production API, histories, StateStore or service mutation is performed.
set -euo pipefail
# Strip repository selectors before any fixture interpreter or git invocation.
for m4_git_env in ${!GIT_@}; do unset "$m4_git_env"; done
unset PYTHONOPTIMIZE PYTHONPATH
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 - "$ROOT" <<'PY'
import copy, http.server, json, os, pathlib, shutil, sqlite3, subprocess, sys, tempfile, threading
import yaml
source = pathlib.Path(sys.argv[1])
checks = failures = 0
def clone(root, rel):
    dst = root/rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source/rel,dst)
    dst.chmod(0o755)
def write(root,name,content):
    p = root/name
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(content)
def run(root,script,env,expected,claim):
    global checks,failures
    checks += 1
    try:
        r = subprocess.run(['bash',str(root/script)],cwd=root,env=env,capture_output=True,text=True,timeout=18)
        out = r.stdout+r.stderr
        if r.returncode != expected or claim not in out or 'EVIDENCE-STORE-UNWRITABLE' in out:
            failures += 1
            print(f'FAIL {script}: expected {expected}/{claim}, actual {r.returncode}\n{out}',flush=True)
    except subprocess.TimeoutExpired:
        failures += 1
        print('FAIL '+script+': timeout, NOT_RUN',flush=True)

with tempfile.TemporaryDirectory(prefix='m4-channel-') as scratch:
    root = pathlib.Path(scratch)
    # Do not inherit paths selecting production evidence or API credentials.
    env = {k:v for k,v in os.environ.items() if not k.startswith(('AIGON_', 'VERIFY_', '__VERIFY_','RUNTIME_API_KEY'))}
    env['__VERIFY_ROOT'] = str(root)
    db = root/'system/control-plane/state/data/canonical-state.db'
    db.parent.mkdir(parents=True)
    with sqlite3.connect(db) as c:
        c.execute('CREATE TABLE evidence(evidence_id TEXT PRIMARY KEY,claim TEXT,source_type TEXT,source_ref TEXT,created_at TEXT)')
    env['VERIFY_STATE_DB'] = str(db)
    for p in ('tools/gates/safety-limits-check.sh','tools/verify/safety-limits-check.sh','tools/verify/core/lib.sh','scripts/limits-render.py',
              'tools/gates/law-56a-secret-channel.sh','tools/verify/law-56a-secret-channel.sh'):
        clone(root,p)
    # Real limits renderer checks cpus, restart and mem_limit against compose.
    compose = {'services':{'worker':{'cpus':1.0,'restart':'unless-stopped','mem_limit':'1g'}}}
    limits = {'version':1,'services':{'worker':copy.deepcopy(compose['services']['worker'])},'systemd':{},'scripts':{}}
    write(root,'docker-compose.yml',yaml.safe_dump(compose))
    write(root,'config/limits.yaml',yaml.safe_dump(limits))
    policy = {'name':'capacity','resource':'session','condition':'sessions >= 10','action':'deny'}
    policies = {'entries':[policy]}
    write(root,'runtime/manifests/policies.yaml',yaml.safe_dump(policies))
    wire = {'status':200,'body':{'count':1,'rules':[copy.deepcopy(policy)]}}
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/runtime/policies' or self.headers.get('X-API-Key') != 'local-isolated-credential':
                self.send_error(401); return
            self.send_response(wire['status']); self.end_headers()
            body = wire['body']
            self.wfile.write((body if isinstance(body,str) else json.dumps(body)).encode())
        def log_message(self,*args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread = threading.Thread(target=server.serve_forever,daemon=True)
    thread.start()
    env['AIGON_SAFETY_RUNTIME_URL'] = 'http://127.0.0.1:'+str(server.server_port)
    env['AIGON_SAFETY_LIMITS_RENDERER'] = str(root/'scripts/limits-render.py')
    env['AIGON_RUNTIME_SHARED_SECRET'] = 'local-isolated-credential'
    before = failures
    safety = 'tools/gates/safety-limits-check.sh'
    try:
        run(root,safety,env,0,'[PASS] GATE-119 SAFETY-LIMITS calosc')
        def malformed_rule(rule):
            write(root,'runtime/manifests/policies.yaml',yaml.safe_dump({'entries':[rule]}))
            wire.update(body={'count':1,'rules':[rule]})
        mutations = [
            ('empty SSOT',lambda:write(root,'runtime/manifests/policies.yaml','entries: []\n'),'SSOT blokad'),
            ('empty live',lambda:wire.update(body={'count':0,'rules':[]}),'egzekwowanie'),
            ('count facade',lambda:wire.update(body={'count':1}),'egzekwowanie'),
            ('unrelated allow rule',lambda:wire.update(body={'count':1,'rules':[dict(policy,action='allow')]}),'egzekwowanie'),
            ('policy drift',lambda:wire.update(body={'count':1,'rules':[dict(policy,condition='sessions >= 1000')]}),'egzekwowanie'),
            ('HTTP unauthorized',lambda:wire.update(status=401),'egzekwowanie'),
            ('malformed response',lambda:wire.update(body='not JSON'),'egzekwowanie'),
            ('service limits drift',lambda:write(root,'docker-compose.yml',yaml.safe_dump({'services':{'worker':dict(compose['services']['worker'],cpus=2.0)}})),'limity serwisu'),
            ('incomplete enforcement rule',lambda:malformed_rule({'action':'deny'}),'egzekwowanie'),
            ('non-string condition',lambda:malformed_rule(dict(policy,condition={'field':'sessions'})),'egzekwowanie'),
            ('empty resource',lambda:malformed_rule(dict(policy,resource=' ')),'egzekwowanie'),
            ('unknown deny action',lambda:malformed_rule(dict(policy,action='deny-nothing')),'egzekwowanie'),
        ]
        for label,mutate,claim in mutations:
            mutate()
            run(root,safety,env,1,'[FAIL] GATE-119 '+claim)
            write(root,'runtime/manifests/policies.yaml',yaml.safe_dump(policies))
            write(root,'docker-compose.yml',yaml.safe_dump(compose))
            wire.update(status=200,body={'count':1,'rules':[copy.deepcopy(policy)]})
            run(root,safety,env,0,'[PASS] GATE-119 SAFETY-LIMITS calosc')
        print(f'M4_RESULT LAW-53 {"PASS" if failures==before else "FAIL"} mutants={len(mutations)} scope=HTTP-policy-inventory-and-real-limits-renderer',flush=True)
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=2)
    # All five channel roots point to this private directory, never real logs.
    for d in ('deleg','logs','scripts'):(root/d).mkdir(exist_ok=True)
    env.update(AIGON_DELEG_DIR=str(root/'deleg'),AIGON_LOGDIR=str(root/'logs'),AIGON_REPO=str(root),
        AIGON_SECRET_USER_HISTORY=str(root/'user.history'),AIGON_SECRET_ROOT_HISTORY=str(root/'root.history'))
    channels = ['deleg/command.log','logs/command.log','scripts/channel.sh','user.history','root.history']
    good = 'curl -H "Authorization: Bearer $SECRET" host\nssh host command\n'
    for channel in channels:write(root,channel,good)
    secret = 'tools/gates/law-56a-secret-channel.sh'
    before = failures
    run(root,secret,env,0,'LAW-56a PASS')
    for channel in channels:
        write(root,channel,'ssh host PASSWORD="BogusCredential881" command\n')
        run(root,secret,env,1,'LAW-56a FAIL')
        write(root,channel,good)
        run(root,secret,env,0,'LAW-56a PASS')
    # Exercise remaining forbidden channel patterns without genuine secrets.
    patterns = ['mysql -p BogusCredential881\n','program --password=BogusCredential881\n',
                'curl -u admin:BogusCredential881 host\n','VAULT_TOKEN="BogusCredential881"\n']
    for bad in patterns:
        write(root,'user.history',bad)
        run(root,secret,env,1,'LAW-56a FAIL')
        write(root,'user.history',good)
        run(root,secret,env,0,'LAW-56a PASS')
    # Inject a real grep protocol error (rc=2), passing all other commands to
    # the installed executable; operational failure must never mean no hits.
    grep = shutil.which('grep')
    if not grep: raise SystemExit('grep unavailable')
    write(root,'bin/grep','#!/usr/bin/env bash\nif [[ "$1" == "-rInE" && -f "$M4_GREP_FAULT" ]]; then exit 2; fi\nexec "'+grep+'" "$@"\n')
    (root/'bin/grep').chmod(0o755)
    env['PATH']=str(root/'bin')+os.pathsep+os.environ['PATH']
    env['M4_GREP_FAULT']=str(root/'grep.fault')
    write(root,'grep.fault','operational failure\n')
    run(root,secret,env,1,'LAW-56a FAIL')
    (root/'grep.fault').unlink()
    run(root,secret,env,0,'LAW-56a PASS')
    absent=dict(env)
    absent.update(AIGON_DELEG_DIR=str(root/'absent-deleg'),AIGON_LOGDIR=str(root/'absent-logs'),AIGON_REPO=str(root/'absent-repo'),
        AIGON_SECRET_USER_HISTORY=str(root/'absent-user'),AIGON_SECRET_ROOT_HISTORY=str(root/'absent-root'))
    run(root,secret,absent,1,'LAW-56a FAIL')
    run(root,secret,env,0,'LAW-56a PASS')
    print(f'M4_RESULT LAW-56 {"PASS" if failures==before else "FAIL"} mutants={len(channels)+len(patterns)+2} scope=five-isolated-channel-roots-forbidden-patterns-and-unmeasured-errors',flush=True)
print(f'M4 safety/secret: checks={checks} failures={failures}',flush=True)
sys.exit(bool(failures))
PY
