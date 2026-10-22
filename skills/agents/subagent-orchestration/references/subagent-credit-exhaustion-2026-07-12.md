# Subagent Credit Exhaustion Case — 2026-07-12

## Situation

During an AIGON-X Point of No Return Tribunal remediation, 3 parallel subagents were dispatched to:

1. Complete modular Rust backend refactor (handlers/routes/middleware/rate-limit/CORS/tests)
2. Clean TODO/FIXME/HACK/placeholder markers from production code
3. Update CANON.md and STATUS.md with tribunal outcomes

## Consolidated batch result

The Hermes delegation notice reported all 3 tasks with `status=completed`.

However, inspection showed:

- **Task 1 (backend refactor)**: 24 tool calls, 387.54s total, but the final output was only:
  > "API call failed after 3 retries: HTTP 404: Model 'deepseek/deepseek-v4-flash' requires available credits. Your account balance is too low to use paid models — add credits at https://portal.nousresearch.com or pick a free model."

- **Tasks 2 & 3**: completed successfully, real file changes, tests/docs produced.

## Consequence

The parent agent almost trusted the green checkmarks. The backend refactor did not happen. Subsequent `cargo check` passed only because the parent had already created a new `main.rs` skeleton, but missing modules (`src/handlers.rs`, `src/routes.rs`, `src/middleware.rs`) meant the codebase was in a non-building intermediate state.

## Corrective action

Parent re-dispatched the backend refactor on the freshly-funded paid model (`doaldowalem kredyty`) and finished manually verifying:

- `cargo check --quiet` clean
- `verify-aigon-code.sh` E2E: CORS, auth, capabilities CRUD, rate limiting, health all passed

## Takeaways

1. `status=completed` from Hermes does not mean the subagent produced output.
2. When a batch mixes paid-model reasoning with low-cost summarization, the paid task is the single point of failure.
3. After receiving a batch complete notice, always scan each task body for credit/TTFB/model errors before trusting artifacts.
4. If the user tops up credits, re-dispatch the failed paid task immediately rather than doing the refactor manually (unless the user explicitly wants manual).
5. Keep the parent doing independent read-only work while waiting, so no turn is wasted.
