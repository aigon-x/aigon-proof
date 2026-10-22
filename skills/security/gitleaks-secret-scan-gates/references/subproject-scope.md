# Subproject-in-parent-repo: why a secret-scan gate goes false-RED

## Symptom
`bash scripts/verify.sh` reports `FAIL gitleaks: wykryto sekrety` for a project
subtree that has **zero** secrets of its own. The gate has always been green in
isolation.

## Root cause
The scanned directory is **not its own git repository** — it is a subfolder of a
larger parent repo. `gitleaks detect --source <subdir>` resolves the SCM root by
walking UP, so it scans the whole parent repo (all commits, all sibling projects).

Concrete trace (2026-09-29, `zoneguard` inside `/opt/projects/inorg`):
```
$ ls -la zoneguard/.git          → absent (NO .git)
$ git -C zoneguard rev-parse --show-toplevel
/opt/projects/inorg              → parent repo (319 commits, ~58 MB)
$ gitleaks detect --source zoneguard --config .gitleaks.toml
... 319 commits scanned, ~58335188 bytes, leaks found: 19
```
Every one of the 19 findings' `File` paths pointed at **siblings**:
`phoneguard/`, `buzz/`, `kosci/`, `parafia/`, `przyczepy/`,
`wynajem-capability/`, `tools/...` — none under `zoneguard/`.

## Decisions this drives
- The FAIL is a **gate scope bug**, not a security defect in the target subtree.
  Classify it as false-RED and say so explicitly; do NOT redact sibling projects.
- Conversely, do not conclude "clean" from a green that scanned the wrong tree.

## Fix (gitleaks 8.19+)
| Goal | Invocation |
|---|---|
| Current state of one subdir, no history | `gitleaks dir <subdir> --config <cfg>` |
| Directory walk of one subdir (incl. ignored/untracked) | `gitleaks detect --source <subdir> --no-git` |
| History scoped to just the subproject | run from a standalone checkout of that subproject |

## Positive control
After changing the invocation, run it on a directory you KNOW contains a leak and
confirm it still fails. A scope "fix" that only makes the sibling noise disappear
must still catch a real token planted inside `<subdir>`.

## Adjacent gotcha (same session family)
A project with no `.git` of its own cannot host a real "fresh clone → verify" G9
gate until it is either its own repo or the CI runs against the parent repo with
an explicit `--source`/`dir` scope. Record the repo boundary in the handover doc.