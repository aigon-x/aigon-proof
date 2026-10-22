# Partial subagent credit-failure recovery

**Date:** 2026-07-13
**Repo:** <workspace> (aigon-code monorepo)
**Lesson class:** Subagent reports `status=completed` but its paid model ran out of Nous credits mid-run, leaving partial or untrusted edits in both the working tree and git index.

## What happened

- Three parallel leaf subagents were dispatched for: (1) frontend/landing, (2) runtime-v2 Rust cleanup, (3) encyclopedia/repo hygiene.
- Subagents 2 and 3 returned `status=completed` but contained:
  - `API call failed after 3 retries: HTTP 404: Model 'deepseek/deepseek-v4-flash' requires available credits`
  - Modified and *staged* files across `runtime-v2/` and `products/aigon-code/`
- The consolidated result did warn that files were modified; it did **not** mean the work was correct.

## Recovery steps performed

1. Inspect git state immediately after the batch:
   ```bash
   git status --short
   ```
2. Do not trust staged changes from a credit-failing subagent. Reset affected subtrees:
   ```bash
   git reset HEAD runtime-v2
   git checkout HEAD -- runtime-v2
   ```
3. Verify the reset restored a working build:
   ```bash
   cd runtime-v2 && cargo test --workspace
   ```
4. For the remaining product changes, diff each file and revert anything that looks like incomplete subagent formatting or stale artifacts.
5. Re-apply only the minimal intended fixes in the parent session and re-verify with canonical commands (`cargo fmt`, `cargo clippy -- -D warnings`, `cargo test`, `npx tsc --noEmit`, `npm run build`).
6. Commit and push only after verification passes.

## Key takeaways

- `status=completed` + `api_calls=0` or a credit error body = **task did not finish cleanly**.
- Credit-failing subagents may still have written to disk/index, producing a false-green state.
- When credits are restored and the user says "kontynuuj", either re-dispatch on the now-funded model, use a free model, or finish the task manually — but always invalidate any pre-failure edits first.
- For a subsystem that a recent commit broke wholesale, the fastest safe fix is usually to check out the last known-good commit for that subtree and cherry-pick the intended minimal changes, rather than debugging corrupted intermediate state.
