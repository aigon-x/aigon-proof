# Gitleaks scan modes — controlled-experiment evidence (2026-09-03)

Context: <workspace> verify/certification gates SEC-001 / SEC-D-07 ("working tree")
kept FAILing while HEAD was provably clean. Investigation produced hard evidence
for how gitleaks 8.x treats --source in a git repo. All findings below were
verified empirically, not assumed from docs.

## Setup of the experiment

Repo: <workspace> (git, branch main). Known state at the time:
- HEAD `212fba91` — clean (secrets redacted to `[REDACTED-2026-09-03]`).
- Commit `326952f5` (2026-08-30) — contained a Cloudflare API token (LXUm...)
  in `skills/shared/cloudflare-dns-tunnel/SKILL.md` — file since redacted in HEAD.
- Commit `56bd0195` (initial) — contained live SSH keys `runtime/.krono-ssh/id_aigon_*`.
- Large ignored dirs: `products/akceleratory/EIC_ACC/.eic-chrome-profile*` (~173 MB),
  plus `.krono-ssh`, datastores. `.gitleaks.toml` has `[allowlist].paths` regexes for them.

## Evidence table (all runs: `gitleaks detect --config .gitleaks.toml --no-banner`)

| Command | Result | Interpretation |
|---|---|---|
| `--source $REPO` (bare) | 384 findings incl. LXUm with `Commit: 326952f5` | scans git log of current branch = HISTORY |
| `--log-opts="-1"` | 0 findings | HEAD commit only |
| `--log-opts="--all"` | 390 findings (default rules) / 384 (custom config) | full multi-branch history |
| `--no-git` | timeout after 200 s, 54 min CPU user | physical walk of everything incl. .git |
| `--pipe` fed `git ls-files -z` output | "no leaks found" on a tree WITH real secrets | stdin scanned as file CONTENT, not paths → FALSE PASS |
| `--pipe` fed a file containing an explicit token | "no leaks found" | same — even real content piped in is misread |

## Key deductions

1. **`--source` in a git repo == history, not worktree.** The mechanism: gitleaks
   shells out to `git log` against the source path when it detects a `.git`.
   Redacting the current file NEVER changes results; only history rewrite does.
   This is why SEC-D-07 (labelled "working tree") was a silent duplicate of the
   history check SEC-R-10 — and why both went red on old commits.

2. **`--log-opts="-1"` is the correct "working tree / clean HEAD" probe.**
   After redaction, `--log-opts="-1"` → 0 findings proved HEAD was clean and
   isolated the remaining failures to genuinely historical secrets.

3. **Allowlist paths filter RESULTS, not reads.** With `.eic-chrome-profile*`
   in `[allowlist].paths`, findings from those dirs → 0, but stderr still shows
   hundreds of `No such file` access errors (gitleaks reads .gitattributes of
   dirs it later filters). Scripts that fail on "stderr is not empty" stay red
   forever — gate on exit code + count instead.

4. **`--pipe` is dangerous.** It treats stdin as the content to scan. Piping
   filenames in = scanning filenames = guaranteed false PASS. A positive-control
   test (pipe a file with a real-looking token) still reported "no leaks found",
   proving the tool was not scanning the intended input at all.

## Positive-control rule

Any change to a scanner invocation must be validated against a tree that you
KNOW contains a leak (e.g. `echo 'token=sk-LIVE123...' > /tmp/probe; gitleaks
detect --pipe < /tmp/probe` should find it). A "fix" that makes results cleaner
on a dirty tree is lying. This caught the `--pipe` regression before it shipped.

## Remediation recipe used

1. Classify hits: real vs documentation curl-auth examples (~350) vs test
   fixtures (fake RSA key in unit test). Real ones only ~36.
2. Redact real secrets in tracked files → `[REDACTED-2026-09-03]` marker
   (dated, greppable, tells future agents when it was done).
3. Untrack runtime artifacts holding live JWTs (Playwright
   `e2e/.auth/user.json`) with `git rm --cached` + a `.gitignore` entry.
4. Verify HEAD clean: `gitleaks detect --source . --log-opts="-1"` → 0.
5. Escalate history exposure (live SSH keys since initial commit, GitHub
   origin) as P0 needing user decision — purge (filter-repo) + rotation is
   destructive and can lock out node access; never auto-allowlist it.
