#!/usr/bin/env bash
# LAW102: byte-identical executor; isolated prompt, memory, identity report.
# Docker CLI fixture models transport responses; actual socket measures MCP.
set -euo pipefail
while IFS= read -r m4_git_var; do unset "$m4_git_var"; done < <(compgen -v GIT_ || true)
unset PYTHONOPTIMIZE PYTHONPATH PYTHONHOME BASH_ENV ENV
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 - "$ROOT" <<'PY'
import hashlib, os, pathlib, shutil, socket, subprocess, sys, tempfile
import yaml
source = pathlib.Path(sys.argv[1])
checks = failures = 0
with tempfile.TemporaryDirectory(prefix='m4-memory-') as scratch:
    root = pathlib.Path(scratch)
    script = root/'tools/gates/memory-first.sh'
    script.parent.mkdir(parents=True)
    shutil.copyfile(source/'tools/gates/memory-first.sh',script)
    def write(name,content):
        p=root/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_text(content)
    # Load canonical structure, change only layer objects to private fixtures.
    canonical=yaml.safe_load((source/'config/canonical/agent-memory.yaml').read_text())
    layers=canonical['enforcement']['layers']
    layers['memory']['indexes']=['.qwen/memories/MEMORY.md']
    layers['registry']['containers_any']=['m4-core-db']
    layers['registry']['required']=True
    layers['mcp']['required']=True
    listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(64)
    open_port=listener.getsockname()[1]
    # Reserve the closed port without listening so another process cannot
    # acquire it between negative probes and make the mutant falsely green.
    closed=socket.socket(); closed.bind(('127.0.0.1',0)); closed_port=closed.getsockname()[1]
    layers['mcp']['ports']=[open_port]
    prompt={'system_prompt':{'content':'PRAWO PAMIĘCI LAW-MEM-1 memory_search rg','per_agent':{}}}
    memory='Verified fixture memory index.\n'
    digest=hashlib.md5(memory.encode()).hexdigest()
    report=digest+'\tqwen\t/home-fixture/qwen.md\n'+digest+'\tclaude\t/home-fixture/claude.md\n'
    def reset():
        layers['memory']['indexes']=['.qwen/memories/MEMORY.md']
        layers['registry']['containers_any']=['m4-core-db']
        layers['mcp']['ports']=[open_port]
        write('config/canonical/agent-memory.yaml',yaml.safe_dump(canonical,allow_unicode=True))
        # The executor parses its marker from double quotes using sed.
        p=root/'config/canonical/agent-memory.yaml'
        p.write_text(p.read_text().replace('marker: PRAWO PAMIĘCI','marker: "PRAWO PAMIĘCI"'))
        write('config/agent-models.yaml',yaml.safe_dump(prompt,allow_unicode=True))
        write('home/.qwen/memories/MEMORY.md',memory)
        write('identity.report',report)
        write('docker.names','m4-core-db\n')
        write('docker.rc','0')
    write('bin/docker','#!/usr/bin/env bash\nset -euo pipefail\ncase "$1" in\ninfo) exit 0 ;;\nps) /bin/cat "$M4_DOCKER_NAMES"; exit "$(/bin/cat "$M4_DOCKER_RC")" ;;\n*) exit 2 ;;\nesac\n')
    (root/'bin/docker').chmod(0o755)
    env={k:v for k,v in os.environ.items() if not k.startswith(('AIGON_', 'M4_', 'GIT_'))}
    env.update(AIGON_MEMORY_HOME=str(root/'home'),AIGON_MEMORY_IDENTITY_REPORT=str(root/'identity.report'),
        M4_DOCKER_NAMES=str(root/'docker.names'),M4_DOCKER_RC=str(root/'docker.rc'),PATH=str(root/'bin')+os.pathsep+os.environ['PATH'])
    def verify(label,expected,claim):
        global checks,failures
        checks+=1
        try:
            r=subprocess.run(['bash',str(script)],cwd=root,env=env,capture_output=True,text=True,timeout=10)
            out=r.stdout+r.stderr
            marker='WYNIK: PASS' if expected==0 else '[FAIL] '+claim
            if r.returncode!=expected or marker not in out:
                failures+=1; print(f'FAIL memory-first {label}: expected rc={expected}/{marker}, got rc={r.returncode}\n{out}',flush=True)
        except subprocess.TimeoutExpired:
            failures+=1; print('FAIL memory-first '+label+': timeout, NOT_RUN',flush=True)
    reset()
    try:
        verify('baseline',0,'')
        def dead_mcp():
            layers['mcp']['ports']=[closed_port]
            write('config/canonical/agent-memory.yaml',yaml.safe_dump(canonical,allow_unicode=True))
        def no_law():
            p=root/'config/canonical/agent-memory.yaml'; p.write_text(p.read_text().replace('LAW-MEM-1','UNDECLARED'))
        mutations=[
            ('required memory has no indexes',lambda:(
                layers['memory'].update(indexes=[]),
                write('config/canonical/agent-memory.yaml',yaml.safe_dump(canonical,allow_unicode=True))),
                'SSOT nie deklaruje indeksów pamięci'),
            ('required registry has no targets',lambda:(
                layers['registry'].update(containers_any=[]),
                write('config/canonical/agent-memory.yaml',yaml.safe_dump(canonical,allow_unicode=True))),
                'SSOT nie deklaruje kontenerów rejestru'),
            ('collector crashes on malformed layer',lambda:(
                layers['memory'].update(indexes=[None]),
                write('config/canonical/agent-memory.yaml',yaml.safe_dump(canonical,allow_unicode=True))),
                'kolektor warstw zakończył się błędem'),
            ('empty memory',lambda:write('home/.qwen/memories/MEMORY.md',''),'warstwa PAMIĘĆ MARTWA'),
            ('missing prompt',lambda:(root/'config/agent-models.yaml').unlink(),'brak promptu'),
            ('identity divergence',lambda:write('identity.report',report.replace(digest+'\tclaude','f'*32+'\tclaude')),'parytet tożsamości ZŁAMANY'),
            ('registry down',lambda:write('docker.names','unrelated-container\n'),'warstwa BAZA/REJESTR MARTWA'),
            ('required MCP closed',dead_mcp,'warstwa MCP nie nasłuchuje'),
            ('missing law marker',no_law,'brak LAW-MEM-1'),
            ('empty identity report',lambda:write('identity.report',''),'brak raportu parytetu'),
            ('collector fails with plausible names',lambda:write('docker.rc','1'),'warstwa BAZA/REJESTR'),
        ]
        for label,mutate,claim in mutations:
            mutate(); verify(label,1,claim); reset(); verify('restored '+label,0,'')
        print(f'M4_RESULT LAW-102 {"PASS" if failures==0 else "FAIL"} mutants={len(mutations)} scope=isolated-memory-prompt-parity-registry-transport-and-live-socket',flush=True)
    finally:
        listener.close()
        closed.close()
print(f'M4 memory-first: checks={checks} failures={failures}',flush=True)
sys.exit(bool(failures))
PY
