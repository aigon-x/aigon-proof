---
name: gitleaks-secret-scan-gates
description: Design and debug gitleaks-based secret-scan gates in verify/CI pipelines — scan-scope semantics (working tree vs git history), the --pipe false-PASS trap, allowlist behavior, and classification of scanner hits (real secret vs documentation pattern vs test fixture). Use whenever a secret-scan gate FAILs unexpectedly, a "clean HEAD" still reports leaks, or you must write a scanner invocation that only checks current tracked state.
---


# Gitleaks Secret-Scan Gates

## When to use
- A verify/CI gate named "no secrets in working tree" FAILs although HEAD looks clean.
- You must write or repair a gitleaks invocation whose scope is "current tracked state only" vs "whole history".
- A scan reports hundreds of hits and you must separate real leaks from documentation examples and test fixtures.

## Scan-scope semantics (empirically verified on gitleaks 8.x, 2026-09-03)

`gitleaks detect --source $REPO` inside a git repo scans **the ENTIRE HISTORY of the current branch** (`git log HEAD`), NOT the working tree. A finding is attributed to the old commit that introduced it (e.g. `Commit: 326952f5`), and redacting the current file NEVER changes the result. This is the #1 source of confusing gate failures.

| Invocation | Actual scope |
|---|---|
| `detect --source $REPO` (bare) | full history of current branch — NOT worktree |
| `detect --source $REPO --log-opts="-1"` | **HEAD commit only** = clean-HEAD / "working tree" check |
| `detect --source $REPO --log-opts="--all"` | all branches, full history |
| `detect --no-git --source $REPO` | physical directory walk incl. .git, node_modules, ignored dirs — unusably slow on large trees |
| `detect --pipe` | **stdin is scanned as FILE CONTENT, not a path list** — piping filenames in = false PASS |

Consequences for gate design:
- A check labelled "working tree" that invokes bare `--source` is actually duplicating your history check. Fix: `--log-opts="-1"` for worktree/HEAD; keep a separate `--log-opts="--all"` check for history. Do NOT allowlist old secrets to silence the worktree gate — that masks real history leaks.
- After redaction, `--log-opts="-1"` → 0 findings proves HEAD is clean and isolates remaining failures to genuine historical secrets.

## The --pipe trap (dangerous)
`--pipe` reads stdin as content to scan. Piping `git ls-files` output scans the filenames themselves → always "no leaks found". A positive control (pipe a file containing a real token) still reports clean, proving the input is misread. Never use --pipe to limit scope to tracked files.

## Allowlist behavior
`[allowlist].paths` regexes in `.gitleaks.toml` filter **results** (findings from ignored dirs drop to 0) but do NOT stop gitleaks from reading those dirs — stderr access-error noise persists. Scripts that fail on "stderr is not empty" stay red forever regardless of allowlist. Gate on exit code + findings count, never on empty stderr.

**Suppressing a FALSE hit (fixture, dedup hash) — the regexes syntax is a trap.**
Measured on gitleaks 8.30.1 (7 variants A–G, 2026-09-30): only
`regexTarget = "match"` works for `regexes`; `"secret"` and the default do NOT
filter. Use LITERALS (`api_key`), never escapes (`api_key: \*\*\*` — 3 leaks).
Use `[[allowlists]]` (array-of-tables), not the old `[allowlist]`. `targetRules`
does NOT narrow to one rule. Full evidence table + diagnosis recipe (including
`--redact=0` to see the REAL matched value, since default reports redact the
secret to `***` and mislead):
`references/gitleaks-allowlist-syntax.md`.

## Classifying hits before remediation
1. **Real secret** → redact in tracked files with dated marker `[REDACTED-YYYY-MM-DD]`; untrack runtime artifacts that hold live tokens (e.g. Playwright `e2e/.auth/user.json` storage state) via `git rm --cached` + `.gitignore`; treat any history exposure as P0.
2. **Documentation pattern** (e.g. `curl -u admin:<PASSWORD>` examples in security testing/skills docs — can be hundreds of hits) → NOT secrets; leave content, silence via ignore fingerprints if they block a gate.
3. **Test fixture** (deliberately fake key in a unit test) → not a leak; annotate clearly.
Prove a hit is real before redacting: byte-compare material from `git show HEAD:path` against the live credential (sha256 match), don't assume from file location.

## P0 escalation (never auto-allowlist)
Live SSH keys committed at the repo's initial commit whose hash matches keys still in use on production nodes. With a GitHub origin, anyone with repo access holds production keys. Remediation = rotation + history purge (`git filter-repo`) — destructive, needs explicit user approval (lockout risk). A redacted HEAD does not fix history exposure.

## Positive-control rule for scanner edits
Any change to a scanner invocation must be validated against input you KNOW contains a leak. A "fix" that makes results cleaner on a dirty tree is lying. This rule caught a `--pipe` regression that would otherwise have shipped as a false-PASS gate.

### The negative-control false-FAIL trap: `set -o pipefail` + `grep -q`
Measured 2026-10-15 (spyskaner verify/CI harness): the negative control read
`if gitleaks dir … | grep -q "leaks found: 1"; then ok; else no; fi` and reported
**FAIL „konfiguracja OŚLEPIŁA regułę"**, while a manual run of the identical command
printed `WRN leaks found: 1` — the config was fine, the *control* was broken.
Cause: gitleaks **exits 1 when it finds leaks**, and under `set -o pipefail` the
pipeline status is the rightmost non-zero → the `if` sees failure even though `grep`
matched. The same shape bites every scanner that signals "found something" through
its exit code (trufflehog, semgrep, actionlint). Fix — capture, then match:
```bash
neg="$(gitleaks dir --no-banner --redact --config .gitleaks.toml . 2>&1 || true)"
printf '%s' "$neg" | grep -q "leaks found: 1" && ok || no
```
Rule: **never let a control depend on pipeline status when the tool under test uses
exit code as a signal; assert on captured stdout.**


## Subproject-in-parent-repo scope trap (false-RED)
When the directory you scan is **NOT its own git repo** (no `.git` of its own) but a
subfolder of a larger parent repo, `gitleaks detect --source <subdir>` silently walks
**UP to the parent SCM root** and scans the ENTIRE parent history. Findings get
attributed to **sibling projects outside your subtree** → the gate goes red for secrets
you do not own. (Observed 2026-09-29: a subproject scanned 319 commits / 58 MB of the
whole monorepo; all 19 hits sat in sibling products, zero in the target subtree.)

Diagnose before believing a red:
```
ls -la <subdir>/.git                       # absent ⇒ not its own repo
git -C <subdir> rev-parse --show-toplevel  # prints the PARENT repo root
```
Cross-check every finding's `File` path against your subtree. If all hits are under
sibling dirs (other products in the monorepo), none belong to you → **false-red, not a
defect**. Report it as a gate scope bug, do NOT touch the sibling code.

Fix the scope (gitleaks 8.19+):
- `gitleaks dir <subdir>` — scans only that directory's files (current state, no history).
- `gitleaks detect --source <subdir> --no-git` — directory walk of subdir only (slower;
  includes ignored/untracked files).
- Need history but only your subtree? Scan from a proper standalone checkout of the subproject.
Never allowlist sibling hits to silence the gate — that masks real leaks elsewhere and
leaves the scope bug in place. Full recipe: `references/subproject-scope.md`.

## Scanning a huge tree fast — parallel shards + load-aware admission (measured 2026-10-13)

`detect --no-git --source <workspace>` on a monorepo of tens of thousands of files
(products/, runtime/, node_modules, .venv) runs as ONE process and took **20+ min**,
blocking the whole verify/certify pipeline and starving the host. The work is
independent per directory, so serialising it is a pipeline bug:

- Shard top-level dirs, run N gitleaks in parallel, union the JSON reports —
  `tools/security/secret-scan-parallel.sh` (shard = top-level dir; `xargs -P N`;
  merge `rep-*.json`; exit 0 clean / 1 leaks / 2 exec-error). Wall-clock ≈ slowest shard.
- **It MUST be load-aware, not just `-P $(nproc)`.** Firing 20–24 gitleaks on an
  already-busy host drove load 196 → 424 on 24 cores; the host then made UNRELATED
  things fail — mesh per-stream throughput collapsed 0.98 → 0.22 MB/s, an 83 MB
  pg_basebackup stalled at ~27 kB/s, public sites started returning 502. Admission
  before the scan (`scripts/lib/bulk-resource-admission.sh`): read
  `config/resource-governor.yaml`; capacity = min(max_jobs, requested,
  (cores − reserve − load) // threads_per_job); **DEFER (exit 75)** when
  `load/cores ≥ max_load_per_core` OR PSI-CPU ≥ max — plus a host-wide flock lease so
  two scans never overlap.
- **Exit 75 means "not run", NEVER "clean".** A gate must treat 75 as WARN/retry, not PASS
  (else the deferral becomes a silent false-green).
- Falsification the admission needs: under load → exit 75 + `DEFERRED` on stderr;
  under idle → exit 0 on a clean dir. Both must hold or the guard lies.
- Verify sharding didn't change the verdict: the shard+merge path must detect an
  injected known-bad token (positive control), same as any scanner change.
- Full recipe + contract: `references/large-tree-parallel-scan.md`.

## Pitfalls
- Editing N parallel copies of a scan script (SEC-001, SEC-D-07, gate scripts): re-test every copy; one missed instance keeps the gate red.
- Test keys like `-----BEGIN RSA PRIVATE KEY-----\nabc` may still flag under private-key rules — classify, don't assume.
- Full reproduction recipe + evidence table: `references/gitleaks-scan-modes.md`.
