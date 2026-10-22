#!/usr/bin/env bash
# GATE-148: source/registry/semantic contract + adversarial tests only.
# PASS is NOT a production/runtime certificate or mission closure.
set -euo pipefail
for contract_env_name in $(compgen -e); do
  case "$contract_env_name" in GIT_*|PYTHONOPTIMIZE|PYTHONPATH|PYTHONHOME|BASH_ENV|ENV) unset "$contract_env_name" ;; esac
done
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Real Git/ledger observer tests take 89s on a loaded host alone.
# Full-suite budget includes those tests and bounded child transport timeouts.
exec timeout --kill-after=5 580 python3 - "$ROOT" "$@" <<'PY'
import concurrent.futures,hashlib,json,pathlib,re,subprocess,sys,yaml
def unittest_execution_counts(stderr):
    counts=re.findall(r'^Ran (\d+) tests? in ',stderr,re.M)
    summaries=re.findall(r'^(?:OK|FAILED)\b[^\n]*$',stderr,re.M)
    if len(counts)!=1 or int(counts[0])<1 or len(summaries)!=1:
        raise ValueError('missing/nonempty unittest count or unique summary')
    skipped=re.findall(r'\bskipped=(\d+)\b',summaries[0])
    if len(skipped)>1:
        raise ValueError('ambiguous unittest skipped count')
    scheduled=int(counts[0]);skipped=int(skipped[0]) if skipped else 0
    if skipped>scheduled:
        raise ValueError('unittest skipped count exceeds scheduled count')
    return scheduled-skipped,skipped
def require_executed_tests(executed):
    if executed<1:
        raise ValueError('zero executed tests is NOT proof')
root=pathlib.Path(sys.argv[1])
try:
    if sys.argv[2:] not in ([], ['--registry-only']):
        raise ValueError('unknown contract gate option')
    source=root/'prawa-sniegul.md'
    registry=yaml.safe_load((root/'config/canonical/prawa-sniegul-registry.yaml').read_text())
    rows=registry['requirements']
    headings={int(m[1]):m[2] for line in source.read_text().splitlines()
              if (m:=re.match(r'^### §(\d+) — (.+)$',line))}
    if len(headings)!=138 or len(rows)!=138 or len({x['section'] for x in rows})!=138:
        raise ValueError('mandatory source/registry inventory mismatch')
    if {x['section']:x['title'] for x in rows}!=headings:
        raise ValueError('normative heading/registry mismatch')
    if registry['source']['path']!='prawa-sniegul.md' or registry['source']['sha256']!=hashlib.sha256(source.read_bytes()).hexdigest():
        raise ValueError('registry source SHA mismatch')
    if any(x.get('required') is not True or x.get('criticality') not in ('C0','C1','C2','C3','C4')
           or not x.get('executor_ids') for x in rows):
        raise ValueError('mandatory canonical requirement incomplete')
    if sys.argv[2:] == ['--registry-only']:
        print('constitution-contract: PASS — source/138 registry ONLY; semantic suites NOT_RUN; NO production certificate')
        sys.exit(0)
    for path in ('tools/gates/test_status_contract_negative.sh','tools/canon/tests/test_constitution_ledger.py',
                 'tools/canon/tests/test_constitution_finalize.py','tools/canon/tests/test_constitution_integration.py'):
        if not (root/path).is_file(): raise ValueError('required adversarial suite absent: '+path)
    for command in ([sys.executable,str(root/'tools/canon/constitution-status.py'),'contract'],
                    ['bash',str(root/'tools/gates/test_status_contract_negative.sh')],
                    ['bash',str(root/'tools/verify/gates/tests/test_constitution_contract.sh')]):
        import os
        child_env=dict(os.environ, AIGON_ROOT=str(root))
        completed=subprocess.run(command,cwd=root,env=child_env,timeout=240,check=False)
        if completed.returncode:
            raise ValueError('required semantic/adversarial check failed (rc='+str(completed.returncode)+', command='+' '.join(command)+')')
    # Each test file owns isolated fixtures. Two finite lanes overlap real
    # Git/ledger I/O, not inference, without dropping any discovered suite.
    suites=sorted((root/'tools/canon/tests').glob('test_constitution_*.py'))
    if not suites: raise ValueError('empty adversarial discovery is NOT proof')
    def test_suite(path):
        command=[sys.executable,'-B','-m','unittest','discover','-s',str(path.parent),'-p',path.name]
        result=subprocess.run(command,cwd=root,env=child_env,timeout=180,capture_output=True,text=True)
        return path.name,result
    failed=[]
    executed_tests=0
    skipped_tests=0
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as lanes:
        for future in concurrent.futures.as_completed([lanes.submit(test_suite,path) for path in suites]):
            name,result=future.result()
            print('constitution-contract suite: '+name,flush=True)
            print(result.stdout,end='',flush=True)
            print(result.stderr,end='',file=sys.stderr,flush=True)
            if result.returncode: failed.append(name)
            try:
                executed,skipped=unittest_execution_counts(result.stderr)
                executed_tests+=executed;skipped_tests+=skipped
                if skipped:
                    print(name+': '+str(executed)+' executed, '+str(skipped)+' SKIPPED (not verified)',flush=True)
            except ValueError as error:
                failed.append(name+' ('+str(error)+')')
    if failed: raise ValueError('required suites failed: '+', '.join(failed))
    require_executed_tests(executed_tests)
    print('constitution-contract: PASS — source/138 registry; '+str(executed_tests)+' executed unittest tests, '+str(skipped_tests)+' skipped/'+str(len(suites))+' suites; semantic adversarial contract only; NO production certificate')
except (ValueError,OSError,KeyError,TypeError,subprocess.SubprocessError) as exc:
    print('constitution-contract: FAIL — '+str(exc),file=sys.stderr)
    sys.exit(1)
PY
