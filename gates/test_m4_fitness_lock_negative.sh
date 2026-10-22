#!/usr/bin/env bash
# Actual lock executor with isolated source, baseline, metrics and health inputs.
set -euo pipefail
# Strip repository selectors before any fixture interpreter or git invocation.
for m4_git_env in ${!GIT_@}; do unset "$m4_git_env"; done
unset PYTHONOPTIMIZE PYTHONPATH
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 - "$ROOT" <<'PY'
import datetime, json, os, pathlib, subprocess, sys, tempfile
source = pathlib.Path(sys.argv[1])
gate = source / 'tools/verify/gates/domains/runtime-lock-discipline.sh'
with tempfile.TemporaryDirectory(prefix='m4-lock-') as scratch:
    root = pathlib.Path(scratch)
    scan = root / 'src'; scan.mkdir()
    metrics = root / 'metrics.prom'; health = root / 'health.json'
    baseline = root / 'baseline.txt'; baseline.write_text('')
    env = {k: v for k,v in os.environ.items() if not k.startswith(('AIGON_', '__VERIFY_'))}
    env.update(__VERIFY_ROOT=str(root), AIGON_ROOT=str(root),
               AIGON_LOCKDISC_SCAN_ROOT=str(scan), AIGON_LOCKDISC_BASELINE=str(baseline),
               AIGON_LOCKDISC_METRICS_FILE=str(metrics), AIGON_LOCKDISC_HEALTH_FILE=str(health))
    def clean():
        (scan / 'lib.rs').write_text('fn work() {}\n')
        metrics.write_text('aigon_lock_write_hold_seconds{kind="tick_max"} 1\n'
                           'aigon_lock_write_hold_seconds{kind="acquire_max"} 1\n'
                           'aigon_tick_wedged_total 0\naigon_metrics_snapshot_age_seconds 1\n')
        health.write_text(json.dumps({'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat()}))
    def run(expected, marker):
        p = subprocess.run(['bash', str(gate)], cwd=root, env=env, text=True,
                           capture_output=True, timeout=15)
        out = p.stdout + p.stderr
        if p.returncode != expected or marker not in out:
            raise AssertionError(f'expected rc={expected}/{marker}, got {p.returncode}\n{out}')
    clean(); run(0, 'CERTIFICATION: PASS')
    mutations = [
        ('source unbounded I/O', lambda: (scan/'lib.rs').write_text('async fn work() {\nlet g = runtime.write().await;\nclient.get(url).send().await;\n}\n'), 'LOCKDISC-A2'),
        ('tick hold over budget', lambda: metrics.write_text(metrics.read_text().replace('tick_max"} 1', 'tick_max"} 46')), 'LOCKDISC-B1'),
        ('acquire over budget', lambda: metrics.write_text(metrics.read_text().replace('acquire_max"} 1', 'acquire_max"} 46')), 'LOCKDISC-B2'),
        ('stale metrics', lambda: metrics.write_text(metrics.read_text().replace('snapshot_age_seconds 1', 'snapshot_age_seconds 61')), 'LOCKDISC-B3'),
        ('stale health', lambda: health.write_text(json.dumps({'timestamp': (datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=120)).isoformat()})), 'LOCKDISC-C1'),
    ]
    for label, mutate, marker in mutations:
        mutate(); run(1, marker); clean(); run(0, 'CERTIFICATION: PASS')
        print('CHECKED lock mutation: '+label)
    for law in ('LAW-40', 'LAW-98'):
        print(f'M4_RESULT {law} PASS mutants={len(mutations)} scope=source-and-observed-inputs')
PY
