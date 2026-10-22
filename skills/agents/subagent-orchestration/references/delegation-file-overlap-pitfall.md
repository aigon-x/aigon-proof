# Delegation File Overlap Pitfall

> **Date**: 2026-07-28 | **Session**: Config-driven provider cascade refactor
> **Severity**: Medium — caught by `cargo test`, not `cargo check`

## What Happened

Three parallel subagents were dispatched to refactor the AIGON-X Runtime provider cascade:

| Task | Target File | 
|------|-------------|
| Task 0 | `aigon-core/src/lib.rs` | 
| Task 1 | `aigon-inference-engine/src/lib.rs` + `Cargo.toml` |
| Task 2 | `aigon-runtime/src/lib.rs` + `aigon-runtime/src/api.rs` + `aigon-inference-engine/src/lib.rs` |

Task 1 and Task 2 **both patched** `aigon-inference-engine/src/lib.rs`, independently adding an `add_from_config` method to `ProviderSelector`. Each compiled in isolation, but when both patches co-existed on disk, the file had **two identical method definitions** — a `duplicate definitions` compile error.

## Detection Signal

```
error[E0592]: duplicate definitions with name `add_from_config`
   --> crates/aigon-inference-engine/src/lib.rs:420:5
    |
335 | pub fn add_from_config(&mut self, configs: &[aigon_core::DynamicProviderConfig]) {
    | -------------------------------------------------------------------- previous definition
420 | pub fn add_from_config(&mut self, entries: &[aigon_core::DynamicProviderConfig]) {
    | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ duplicate definition
```

`cargo check` passed because each subagent ran it in isolation on their own file state. `cargo test` caught it because both patches had been applied.

## Root Cause

Two subagents received task contexts that both identified `aigon-inference-engine/src/lib.rs` as a file to modify. The parent (orchestrator) did not cross-check the `context` strings for file-level overlaps before dispatching.

## Prevention Rules

1. **List exact files in every subagent's `context` field** — use absolute paths, not fuzzy descriptions.
2. **Verify no overlap** before dispatching — every file should appear in at most ONE task's context.
3. **Merge or serialize** when the same file needs changes from multiple angles:
   - Merge: give all related changes to ONE subagent
   - Serialize: dispatch task A, wait for result, then dispatch task B on the updated file
4. **Always run full build/test after delegation** — never trust subagent self-reports alone.

## Configuration-Driven Provider Pattern (what was built)

The task that triggered this pitfall successfully produced:

- `aigon-core::DynamicProviderConfig` — serde-deserializable struct in `aigon-core/src/lib.rs`
- `ProviderSelector::add_from_config()` — loads providers from config instead of hardcoded `add_defaults()`
- Wiring in `Runtime::new()` and `build_api_router()` — conditional: use config providers if present, else fall back to hardcoded defaults
- Example YAML in `config/node-local.yaml` with 17 declarative provider entries

See `aigon-x-runtime` skill → `references/config-provider-wiring-pattern.md` for the full pattern.
