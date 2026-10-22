# Credit-Failure Active Backfill — 2026-07-12

## Situation

During AIGON-X Tribunal remediation, a paid-model subagent (`deepseek/deepseek-v4-flash`) failed to refactor the Rust backend because the account was out of credits. The user topped up (`doaldowalem kredyty`) and asked to continue with maximum parallelism.

## What happened

1. First batch: backend refactor subagent reported `completed` but the body was only a credit-exhaustion error; no files were created.
2. Parent already had a partial skeleton (`main.rs`, `error.rs`, `models.rs`, `state.rs`) that referenced missing modules, so the codebase did not compile.
3. While waiting for the user to fund the account, the parent ran independent read-only work: audits, TODO scan, MCP gap check.
4. After funding, a fresh batch of parallel subagents was dispatched; one completed the modular refactor and another expanded `verify-aigon-code.sh`.
5. The remaining 404 bug in capabilities CRUD was a framework syntax issue in `routes.rs` — axum 0.7 expects `:id`, not `{id}`. The parent fixed it and re-ran the full E2E verify.

## Takeaways

- **Active backfill**: when a paid subagent is blocked on credits, don't idle. Move forward with conflict-free parent work (read-only audits, verification of already-completed subagents, small fixes that don't touch the in-flight files).
- **Re-dispatch precision**: after funding, ensure the re-dispatched subagent uses the exact paid model that previously failed. Generic dispatch may route to a different/cheaper model and miss the reasoning capability needed.
- **Dynamic ports in verify scripts**: a supervisor process kept restarting the old backend on port 8080. The verify script was updated to select a free port dynamically and still check CORS/auth/CRUD/rate limiting end-to-end.
- **Framework-version gotchas**: `axum` 0.7 uses `/:id` for path params; `{id}` is treated as a literal segment and causes 404. Always verify route syntax against the installed crate version after a subagent refactor.
