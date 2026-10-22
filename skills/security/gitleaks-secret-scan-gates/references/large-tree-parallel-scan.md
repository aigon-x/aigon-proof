# Large-tree parallel scan — incident + contract (2026-10-13)

## Problem measured
`tools/verify/security/secrets.sh` (SEC-001) delegates to `gitleaks detect --source <workspace>
--no-git --no-banner` — a SINGLE process walking the whole monorepo (products/, runtime/,
node_modules, .venv, agent-env ...). Observed run: **20+ min, no output**, blocking
`tools/verify/verify.sh reconcile` (the whole certification) and saturating the host.

Root cause is NOT bandwidth — it is (a) no parallelism (independent dirs done serially),
and (b) no admission control when several heavy scans run at once.

## Fix: sharded parallel scan
`tools/security/secret-scan-parallel.sh <ROOT> [jobs]`
- shards = top-level dirs of ROOT (exclude .git/.hg); loose files in root -> shard `_root`.
- `xargs -P "$JOBS" -I{} bash -c 'scan_one "$@"' _ {}` — one `gitleaks detect --source
  $ROOT/$shard --no-git --report-format json --report-path rep-$shard.json --exit-code 1`
  per shard.
- Python merge: concat all `rep-*.json` arrays -> `merged.json`; count findings.
- Exit: 0 clean / 1 leaks (any shard exit 1 or merged total > 0) / 2 any shard exec-error.

## Fix: load-aware admission (added by a concurrent agent, same day)
At the top of the scanner:
```
POLICY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$POLICY_ROOT/scripts/lib/bulk-resource-admission.sh"
bulk_scan_admit "$POLICY_ROOT" "$JOBS" || exit 75
JOBS="$AIGON_BULK_SCAN_JOBS"
```
`bulk-resource-admission.sh` reads `config/resource-governor.yaml` `bulk_scan:` policy
(max_jobs, threads_per_job, reserve_cores, max_load_per_core, max_psi_cpu), measures
`/proc/loadavg` + `/proc/pressure/cpu` (PSI avg10), computes capacity, and returns 75
(DEFERRED) on overload/unknown-policy; holds a host-wide flock lease
`/run/lock/aigon-bulk/secret-scan.lock` so concurrent scans serialise.

## Why it matters (self-inflicted outage)
Running 20-24 gitleaks + the test suites + a pg_basebackup at once took load to **424 on
24 cores**. Symptoms that LOOK like infra defects but were host saturation:
- mesh tailscale per-stream throughput 0.98 -> 0.22 MB/s (pairs were DIRECT, 121 ms WAN);
- `pg_basebackup` 83 MB crawling at ~27 kB/s (per-file I/O over a busy link);
- public product panels returning intermittent 502 (frontends timing out).
Lesson: heavy parallel jobs need admission control; a saturated host libels the network.

## Verification contract
- `bash -n` the scanner; `chmod 755` (group aigon needs r).
- Under load (load > cores): must print `DEFERRED load=... cores=... psi_cpu=...` and exit 75.
- Under idle: clean dir -> exit 0; injected known-bad token (e.g. an AWS example key) -> exit 1.
- The scanner file may be edited by a PARALLEL agent (this one was): re-check mtime/owner and
  re-read before trusting your own last write.
