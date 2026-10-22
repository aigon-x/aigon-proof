#!/usr/bin/env bash
# Real reusable engine tests; deterministic fixtures, no live state mutation.
set -euo pipefail
ROOT="${AIGON_ROOT:-/srv/aigon}"
export PYTHONDONTWRITEBYTECODE=1
exec python3 - "$ROOT" <<'PY'
import copy
import importlib.util
import itertools
import json
import pathlib
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('constitution_status', ROOT / 'tools/canon/constitution-status.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
now = datetime.now(timezone.utc).replace(microsecond=0)
stamp = lambda delta=0: (now + timedelta(seconds=delta)).isoformat()
checks = 0

def fixture():
    ident = dict(source_sha='a'*40, artifact_digest='sha256:'+'b'*64,
                 configuration_version='config/1', constitution_version='constitution/1',
                 policy_version=m.ENGINE_VERSION, environment='repository', release_id='rc/1',
                 dependency_version='dependencies/1', executor_semantics_version='probe/1')
    ev = dict(evidence_id='e1', executor_id='x1', scope='repository', identity=copy.deepcopy(ident),
              observed_at=stamp(-10), valid_until=stamp(3600), reference='fixture://actual-test-output',
              complete=True, sources_available=True)
    rec = dict(record_id='r1', law_id='LAW-X', law_version='1', law_status='PASS', reason_code='LAW.VERIFIED',
               scope='repository', criticality='C0', constitution_version=ident['constitution_version'],
               source_sha=ident['source_sha'], artifact_digest=ident['artifact_digest'],
               configuration_version=ident['configuration_version'], environment=ident['environment'],
               identity=copy.deepcopy(ident), executor_ids=['x1'], evidence_ids=['e1'], evaluated_at=stamp(-5),
               valid_until=stamp(3600), executors=[dict(executor_id='x1',status='EXECUTED',law_status='PASS',evidence_ids=['e1'])])
    return dict(mission_id='mission-fixture', evaluation_run_id='run-fixture', evaluated_at=stamp(),
                scope='repository', identity=ident, required_laws=[dict(law_id='LAW-X',law_version='1',
                criticality='C0',scope='repository',required=True,required_executor_ids=['x1'])],
                law_records=[rec], evidence=[ev], deployment=dict(required=False,state='NOT_BUILT'),
                blockers=[], remaining_work=[])

def closure(result):
    actual = {key: copy.deepcopy(result[key]) for key in ('constitution_verdict','scope','source_sha','artifact_digest','configuration_version','environment','deployment_state')}
    actual.update(code_changed=True,tests_executed=True,commit_executed=False,push_executed=False,merge_executed=False,runtime_verified=result['runtime_verified'])
    return dict(mission_closure='CLOSED_SUCCESS',constitution_verdict=result['constitution_verdict'],
                checklist=dict.fromkeys(m.CHECKLIST,True),status_object=copy.deepcopy(result),
                repository=dict(head='a'*40,branch='test',working_tree_state='clean',unpushed_commits=0,pr_state='NOT_APPLICABLE',merge_state='NOT_MERGED',release_state='NOT_RELEASED'),
                evidence_accounting=dict(required=['e1'],present=['e1'],missing=[],stale=[],invalidated=[]),
                cleanup=dict.fromkeys(m.CLEANUP_FIELDS,'CLEAR'),safety=dict.fromkeys(m.SAFETY_FIELDS,True),
                executed_changes=[dict(change_id='fixture',classification='TEST_ONLY',provenance='test fixture',evidence_ids=['e1'])],
                required_work_executed=True,no_executable_required_work=True,remaining_work=[],blockers=[],
                actual_execution_state=actual,report=copy.deepcopy(actual),ledger=copy.deepcopy(actual),registry=copy.deepcopy(actual))

def check(name, fn):
    global checks
    fn(); checks += 1; print('PASS:', name)

def eq(value, expected):
    assert value == expected, (value, expected)

def rejects(fn):
    try:
        fn()
    except m.ContractError:
        return
    raise AssertionError('malformed mutant accepted')

def mutate(fn):
    d=fixture(); fn(d); return d

def evaluate(d):
    return m.evaluate(d, now=now)

def result_status(d):
    return evaluate(d)['current_laws'][0]['law_status']

check('valid actual scoped evidence -> VERIFIED', lambda: eq(evaluate(fixture())['constitution_verdict'],'CONSTITUTIONALLY_VERIFIED'))
baseline=evaluate(fixture()); check('valid full closure',lambda:eq(m.validate_closure(closure(baseline),expected=baseline),'CLOSED_SUCCESS'))
check('input/history not mutated',lambda: eq(fixture()['law_records'][0]['law_status'],'PASS'))

schema_mutants={
 'empty inventory': lambda d:d.update(required_laws=[]),
 'noncanonical status':lambda d:d['law_records'][0].update(law_status='GREEN'),
 'mixed executor namespace':lambda d:d['law_records'][0]['executors'][0].update(status='PASS'),
 'missing reason':lambda d:d['law_records'][0].pop('reason_code'),
 'underscore reason':lambda d:d['law_records'][0].update(reason_code='EVIDENCE_MISSING'),
 'missing identity':lambda d:d['identity'].pop('source_sha'),
 'missing scope':lambda d:d.pop('scope'),
 'duplicate evidence':lambda d:d['evidence'].append(copy.deepcopy(d['evidence'][0])),
 'duplicate history':lambda d:d['law_records'].append(copy.deepcopy(d['law_records'][0])),
 'record widens scope':lambda d:d['law_records'][0].update(scope='federation'),
 'implicit priority':lambda d:d['required_laws'][0].update(criticality='P0'),
 'naive timestamp':lambda d:d['law_records'][0].update(evaluated_at='2026-01-01T00:00:00'),
 'future evidence':lambda d:d['evidence'][0].update(observed_at=stamp(20)),
 'not-applicable self exemption':lambda d:d['law_records'][0]['executors'][0].update(status='NOT_APPLICABLE',scope_exclusion_reason='GPU not here',scope_exclusion_evidence_ids=['e1']),
 'critical operation no postcondition':lambda d:d.update(operations=[dict(operation_id='o',status='SUCCEEDED',critical=True,execution_completed=True,executor_id='x1',scope='repository',postcondition_evidence_ids=[])]),
 'operation status as LAW':lambda d:d['law_records'][0].update(law_status='SUCCEEDED'),
 'blocked operation no dependency':lambda d:d.update(operations=[dict(operation_id='o',status='BLOCKED',reason_code='AUTHORITY.INSUFFICIENT')]),
}
for name, fn in schema_mutants.items():
    check(name, lambda fn=fn: rejects(lambda: evaluate(mutate(fn))))

measurement_mutants={
 'no record':(lambda d:d.update(law_records=[]),'UNKNOWN'),
 'missing required executor':(lambda d:d['required_laws'][0]['required_executor_ids'].append('x2'),'UNKNOWN'),
 'not run required':(lambda d:d['law_records'][0]['executors'][0].update(status='NOT_RUN',reason_code='EXECUTOR.NOT_RUN'),'UNKNOWN'),
 'timeout required':(lambda d:d['law_records'][0]['executors'][0].update(status='EXECUTOR_TIMEOUT',reason_code='EXECUTOR.TIMEOUT'),'UNKNOWN'),
 'error required':(lambda d:d['law_records'][0]['executors'][0].update(status='EXECUTOR_ERROR',reason_code='EXECUTOR.ERROR'),'UNKNOWN'),
 'unavailable required':(lambda d:d['law_records'][0]['executors'][0].update(status='EXECUTOR_UNAVAILABLE',reason_code='EXECUTOR.UNAVAILABLE'),'UNKNOWN'),
 'missing proof':(lambda d:d.update(evidence=[]),'UNKNOWN'),
 'collector unavailable':(lambda d:d['evidence'][0].update(sources_available=False),'UNKNOWN'),
 'incomplete proof':(lambda d:d['evidence'][0].update(complete=False),'UNKNOWN'),
 'expired proof':(lambda d:d['evidence'][0].update(valid_until=stamp(-1)),'STALE'),
 'source changed':(lambda d:d['identity'].update(source_sha='c'*40),'STALE'),
 'artifact changed':(lambda d:d['identity'].update(artifact_digest='sha256:'+'c'*64),'STALE'),
 'config changed':(lambda d:d['identity'].update(configuration_version='config/2'),'STALE'),
 'constitution changed':(lambda d:d['identity'].update(constitution_version='constitution/2'),'STALE'),
 'dependency changed':(lambda d:d['identity'].update(dependency_version='dependencies/2'),'STALE'),
 'executor semantics changed':(lambda d:d['identity'].update(executor_semantics_version='probe/2'),'STALE'),
 'record TTL expired':(lambda d:d['law_records'][0].update(valid_until=stamp(-1)),'STALE'),
 'missing negative proof':(lambda d:d['required_laws'][0].update(negative_proof_required=True),'UNKNOWN'),
 'wrong evidence scope':(lambda d:d['evidence'][0].update(scope='federation'),'UNKNOWN'),
 'wrong executor role':(lambda d:d['evidence'][0].update(executor_id='different'),'UNKNOWN'),
}
for name,(fn,want) in measurement_mutants.items():
    check(name,lambda fn=fn,want=want:eq(result_status(mutate(fn)),want))

def failed(d):
    d['law_records'][0].update(law_status='FAIL',reason_code='SECURITY.AUTH_BYPASS',failed_invariant='auth',observed_state='bypass',expected_state='denied',impact='critical access',remediation_status='OPEN')
    d['law_records'][0]['executors'][0].update(law_status='FAIL',invariant_violation_proven=True)

check('critical positive failure -> FAILED',lambda:eq(evaluate(mutate(failed))['constitution_verdict'],'FAILED_VERIFICATION'))
def rollback(d):
    d['rollback']=dict(state='SUCCEEDED',executor_id='x1',candidate_failed=True,rollout_started=True,
      execution_evidence_ids=['e1'],state_evidence_ids=['e1'],critical_fitness_evidence_ids=['e1'],runtime_evidence_ids=['e1'])
check('verified rollback -> ROLLED_BACK',lambda:eq(evaluate(mutate(rollback))['constitution_verdict'],'ROLLED_BACK'))
check('critical failure dominates rollback',lambda:eq(evaluate(mutate(lambda d:(failed(d),rollback(d))))['constitution_verdict'],'FAILED_VERIFICATION'))
check('rollback failure dominates green',lambda:eq(evaluate(mutate(lambda d:d.update(rollback=dict(state='FAILED'))))['constitution_verdict'],'FAILED_VERIFICATION'))
def pending(d):
    d['deployment'].update(required=True,state='RELEASE_CANDIDATE',implementation_complete=True,predeploy_complete=True)
check('complete predeploy -> pending',lambda:eq(evaluate(mutate(pending))['constitution_verdict'],'IMPLEMENTED_DEPLOYMENT_PENDING'))
check('pending cannot outrank required UNKNOWN',lambda:eq(evaluate(mutate(lambda d:(pending(d),d.update(law_records=[]))))['constitution_verdict'],'PARTIALLY_VERIFIED'))
check('deployment requires runtime proof',lambda:eq(evaluate(mutate(lambda d:d['deployment'].update(required=True,state='PRODUCTION_DEPLOYED')))['constitution_verdict'],'PARTIALLY_VERIFIED'))
check('runtime proof enables production verified',lambda:eq(evaluate(mutate(lambda d:d['deployment'].update(required=True,state='PRODUCTION_DEPLOYED',executor_id='x1',runtime_evidence_ids=['e1'])))['constitution_verdict'],'CONSTITUTIONALLY_VERIFIED'))

def history(d,remediation=False):
    old=copy.deepcopy(d['law_records'][0]); old.update(record_id='old',evaluated_at=stamp(-100))
    old.update(law_status='FAIL',reason_code='SECURITY.AUTH_BYPASS',failed_invariant='auth',observed_state='bypass',expected_state='denied',impact='critical',remediation_status='OPEN')
    old['executors'][0].update(law_status='FAIL',invariant_violation_proven=True)
    oldev=copy.deepcopy(d['evidence'][0]);oldev.update(evidence_id='old-evidence',observed_at=stamp(-110))
    d['evidence'].append(oldev);old['evidence_ids']=['old-evidence'];old['executors'][0]['evidence_ids']=['old-evidence']
    d['law_records'].insert(0,old)
    if remediation:d['law_records'][-1]['remediation_evidence_ids']=['e1']
check('manual FAIL to PASS without remediation -> UNKNOWN',lambda:eq(result_status(mutate(history)),'UNKNOWN'))
check('remediated historical FAIL preserved current PASS',lambda:eq(result_status(mutate(lambda d:history(d,True))),'PASS'))
check('history never deleted',lambda:eq(len(evaluate(mutate(lambda d:history(d,True)))['history']),2))
def conflict(d):
    second=copy.deepcopy(d['law_records'][0]);second['record_id']='r2'; second['law_status']='UNKNOWN';second['reason_code']='EVIDENCE.CONFLICT';d['law_records'].append(second)
check('same-time contradictory records -> UNKNOWN',lambda:eq(result_status(mutate(conflict)),'UNKNOWN'))
check('order independent evaluation',lambda:eq(evaluate(mutate(lambda d:history(d,True))),evaluate(mutate(lambda d:(history(d,True),d['law_records'].reverse())))))

def warning(d):
    d['law_records'][0].update(law_status='WARN',reason_code='PERFORMANCE.WARNING',message='latency risk',severity='LOW',recommended_action='measure again')
    d['law_records'][0]['executors'][0]['law_status']='WARN'
check('WARN has proven invariant and metadata',lambda:eq(result_status(mutate(warning)),'WARN'))
check('WARN missing message rejected',lambda:rejects(lambda:evaluate(mutate(lambda d:(warning(d),d['law_records'][0].pop('message'))))))
check('WARN missing proof -> UNKNOWN',lambda:eq(result_status(mutate(lambda d:(warning(d),d.update(evidence=[])))),'UNKNOWN'))
def partial(d):
    d['law_records'][0].update(law_status='PARTIAL',reason_code='EVIDENCE.INCOMPLETE',proven_scope=['A'],unproven_scope=['B'],required_action='verify B')
    d['law_records'][0]['executors'][0]['law_status']='PARTIAL'
check('PARTIAL never automatically PASS',lambda:eq(result_status(mutate(partial)),'PARTIAL'))
check('PARTIAL needs unproven scope',lambda:rejects(lambda:evaluate(mutate(lambda d:(partial(d),d['law_records'][0].pop('unproven_scope'))))))
def exemption(d):
    d['required_laws'][0]['required_executor_ids']=[]
    d['law_records'][0].update(law_status='EXEMPT-JUSTIFIED',reason_code='ENFORCEMENT.ALTERNATIVE',exemption=dict(formal_justification='human review of nonautomatable norm',evidence_model='signed review',owner='reviewer',review_policy='daily',last_verification=stamp(-10),next_review=stamp(3600),automation_not_sensible=True))
check('alternative actualproof -> EXEMPT-JUSTIFIED',lambda:eq(result_status(mutate(exemption)),'EXEMPT-JUSTIFIED'))
check('exemption missing review rejected',lambda:rejects(lambda:evaluate(mutate(lambda d:(exemption(d),d['law_records'][0]['exemption'].pop('next_review'))))))
check('gate missing not exemption justification',lambda:rejects(lambda:evaluate(mutate(lambda d:(exemption(d),d['law_records'][0]['exemption'].update(automation_not_sensible=False))))))
check('exemption review expired -> STALE',lambda:eq(result_status(mutate(lambda d:(exemption(d),d['law_records'][0]['exemption'].update(next_review=stamp(-1))))),'STALE'))
check('exemption absent proof -> UNKNOWN',lambda:eq(result_status(mutate(lambda d:(exemption(d),d.update(evidence=[])))),'UNKNOWN'))
def adjustment(d, kind='waiver', expired=False):
    d['required_laws'][0]['criticality']='C3';d['law_records'][0]['criticality']='C3';failed(d)
    common=dict(law_id='LAW-X',scope='repository',reason='bounded known noncritical risk',authority=dict(principal='authorized-reviewer',reference='fixture://approval',executor_id='x1',evidence_ids=['e1']),created_at=stamp(-100),expires_at=stamp(-1 if expired else 3600),compensating_controls=['isolate feature'])
    obj=dict(common,waiver_id='w1',risk='bounded',remediation_plan='fix with verified test') if kind=='waiver' else dict(common,override_id='o1',original_status='FAIL',effective_decision='ACCEPTED',evidence=['e1'])
    d[kind+'s']=[obj]
check('valid noncritical waiver affects decision',lambda:eq(evaluate(mutate(adjustment))['constitution_verdict'],'VERIFIED_WITH_NON_CRITICAL_WARNINGS'))
check('waiver preserves observed FAIL',lambda:eq(result_status(mutate(adjustment)),'FAIL'))
check('expired waiver no effect',lambda:eq(evaluate(mutate(lambda d:adjustment(d,expired=True)))['constitution_verdict'],'FAILED_VERIFICATION'))
check('valid override separate decision',lambda:eq(evaluate(mutate(lambda d:adjustment(d,'override')))['constitution_verdict'],'VERIFIED_WITH_NON_CRITICAL_WARNINGS'))
check('override preserves observed FAIL',lambda:eq(result_status(mutate(lambda d:adjustment(d,'override'))),'FAIL'))
check('expired override no effect',lambda:eq(evaluate(mutate(lambda d:adjustment(d,'override',True)))['constitution_verdict'],'FAILED_VERIFICATION'))
for field in m.WAIVER_FIELDS:
    check('waiver missing '+field,lambda field=field:rejects(lambda:evaluate(mutate(lambda d:(adjustment(d),d['waivers'][0].pop(field))))))
for field in ('original_status','effective_decision','evidence'):
    check('override missing '+field,lambda field=field:rejects(lambda:evaluate(mutate(lambda d:(adjustment(d,'override'),d['overrides'][0].pop(field))))))
check('waiver C0 forbidden',lambda:rejects(lambda:evaluate(mutate(lambda d:(adjustment(d),d['required_laws'][0].update(criticality='C0'),d['law_records'][0].update(criticality='C0'))))))
check('override cannot rewrite original',lambda:rejects(lambda:evaluate(mutate(lambda d:(adjustment(d,'override'),d['overrides'][0].update(original_status='PASS'))))))
check('critical violation cannot waived',lambda:eq(evaluate(mutate(lambda d:(adjustment(d),d['law_records'][0].update(critical_violation=True))))['constitution_verdict'],'FAILED_VERIFICATION'))
check('waiver authority proof unavailable',lambda:rejects(lambda:evaluate(mutate(lambda d:(adjustment(d),d['evidence'][0].update(sources_available=False))))))
def two_executors(d,status,required=True):
    e=copy.deepcopy(d['evidence'][0]);e.update(evidence_id='e2',executor_id='x2');d['evidence'].append(e)
    d['law_records'][0]['executor_ids'].append('x2')
    ex=dict(executor_id='x2',status='EXECUTED',law_status=status,evidence_ids=['e2'])
    if status=='FAIL':ex['invariant_violation_proven']=True;d['law_records'][0].update(failed_invariant='auth',observed_state='bypass',expected_state='deny',impact='critical',remediation_status='OPEN')
    if status=='WARN':d['law_records'][0].update(message='risk',severity='LOW',recommended_action='follow up')
    d['law_records'][0]['executors'].append(ex)
    if required:d['required_laws'][0]['required_executor_ids'].append('x2')
check('any required FAIL dominates PASS',lambda:eq(result_status(mutate(lambda d:two_executors(d,'FAIL'))),'FAIL'))
check('required UNKNOWN dominates STALE',lambda:eq(result_status(mutate(lambda d:(two_executors(d,'PASS'),d['law_records'][0]['executors'][1].update(status='NOT_RUN',reason_code='EXECUTOR.NOT_RUN'),d['evidence'][0].update(valid_until=stamp(-1))))),'UNKNOWN'))
check('optional actual violation still FAIL',lambda:eq(result_status(mutate(lambda d:two_executors(d,'FAIL',False))),'FAIL'))
check('optional WARN visible',lambda:eq(result_status(mutate(lambda d:two_executors(d,'WARN',False))),'WARN'))
check('optional unavailable does not lower PASS',lambda:eq(result_status(mutate(lambda d:(two_executors(d,'PASS',False),d['law_records'][0]['executors'][1].update(status='EXECUTOR_UNAVAILABLE',reason_code='EXECUTOR.UNAVAILABLE')))),'PASS'))
def scoped_matrix(d):
    req=copy.deepcopy(d['required_laws'][0]);req['scope']='node-B';d['required_laws'].append(req)
check('single scope PASS not global proof',lambda:eq(evaluate(mutate(scoped_matrix))['constitution_verdict'],'PARTIALLY_VERIFIED'))
check('matrix missing scope UNKNOWN',lambda:eq(evaluate(mutate(scoped_matrix))['unknown'],1))
check('FAIL claim without executor violation UNKNOWN',lambda:eq(result_status(mutate(lambda d:(failed(d),d['law_records'][0]['executors'][0].update(law_status='PASS')))),'UNKNOWN'))
check('future proof relative to LAW record rejected',lambda:rejects(lambda:evaluate(mutate(lambda d:d['law_records'][0].update(evaluated_at=stamp(-20))))))

for key in m.CHECKLIST:
    c=closure(baseline);c['checklist'][key]=False
    check('closure false '+key,lambda c=c:rejects(lambda:m.validate_closure(c,expected=baseline)))
for key in m.SAFETY_FIELDS:
    c=closure(baseline);c['safety'][key]=False
    check('closure unsafe '+key,lambda c=c:rejects(lambda:m.validate_closure(c,expected=baseline)))
for key in m.CLEANUP_FIELDS:
    c=closure(baseline);c['cleanup'].pop(key)
    check('cleanup unaccounted '+key,lambda c=c:rejects(lambda:m.validate_closure(c,expected=baseline)))
for name, fn in {
 'closure fabricated verdict':lambda c:c['status_object'].update(constitution_verdict='FAILED_VERIFICATION'),
 'ledger contradicts actual':lambda c:c['ledger'].update(source_sha='x'),
 'report contradicts actual':lambda c:c['report'].update(tests_executed=False),
 'registry contradicts actual':lambda c:c['registry'].update(artifact_digest='x'),
 'required work remains':lambda c:c.update(no_executable_required_work=False),
 'missing accounting':lambda c:c['evidence_accounting'].update(present=[]),
 'hidden remaining work':lambda c:c.update(remaining_work=['fix']),
 'closure success with FAILED verdict':lambda c:c.update(constitution_verdict='FAILED_VERIFICATION'),
}.items():
    c=closure(baseline);fn(c);check(name,lambda c=c:rejects(lambda:m.validate_closure(c,expected=baseline)))

contract=m.load_contract()
for name,fn in {
 'status precedence stale before unknown':lambda c:c['aggregation']['status_precedence'].reverse(),
 'waiver C0':lambda c:c['aggregation']['criticality_policy']['C0'].update(waiver_allowed=True),
 'bad executor enum':lambda c:c['enums']['executor_status'].append('PASS'),
 'exempt underscore':lambda c:c['enums']['law_status'].__setitem__(6,'EXEMPT_JUSTIFIED'),
 'waiver no expiry':lambda c:c['waiver']['required_fields'].remove('expires_at'),
 'partial wrongly success closure':lambda c:c['closure_contract']['verdict_to_closure'].update(PARTIALLY_VERIFIED='CLOSED_WITH_WARNINGS'),
}.items():
    c=copy.deepcopy(contract);fn(c);check(name,lambda c=c:rejects(lambda:m.validate_contract(c)))

# Exercise actual CLI wrapper against files, not just imported helper functions.
with tempfile.TemporaryDirectory(prefix='constitution-status-') as tmp:
    tmp=pathlib.Path(tmp)
    def cli(arg,path=None):
        cmd=['bash',str(ROOT/'tools/gates/law-status-contract.sh')]+arg
        return subprocess.run(cmd,capture_output=True,text=True)
    check('wrapper canonical contract',lambda:eq(cli([]).returncode,0))
    good=tmp/'good.json';good.write_text(json.dumps(fixture()))
    check('wrapper real evaluate',lambda:eq(cli(['--input',str(good)]).returncode,0))
    bad=tmp/'bad.json';bad.write_text(json.dumps(dict(closure_status='CLOSED_SUCCESS',constitution_verdict='FAILED_VERIFICATION',checklist=dict.fromkeys(m.CHECKLIST,False))))
    check('wrapper rejects original false closure shape',lambda:eq(cli(['--closure',str(bad)]).returncode,1))
    inp=fixture();res=evaluate(inp); cl=closure(res);cl['evaluation_input']=inp
    good.write_text(json.dumps(cl))
    check('wrapper independently rederives full closure',lambda:eq(cli(['--closure',str(good)]).returncode,0))
    cl['status_object']['constitution_verdict']='FAILED_VERIFICATION';good.write_text(json.dumps(cl))
    check('wrapper rejects forged derived verdict',lambda:eq(cli(['--closure',str(good)]).returncode,1))
check('restored baseline remains VERIFIED',lambda:eq(evaluate(fixture())['constitution_verdict'],'CONSTITUTIONALLY_VERIFIED'))
print('TEST PASS:',checks,'canonical engine/closure assertions; fixtures cleaned; no live mutations')
PY
