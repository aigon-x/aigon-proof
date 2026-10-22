---

name: subagent-orchestration
title: Parallel Subagent Orchestration Under Credit Constraints
description: Patterns for dispatching parallel Hermes subagents (delegate_task), handling paid-model credit exhaustion, respecting concurrency limits, and verifying outcomes instead of trusting completion flags.
category: software-development
tags: [subagents, delegation, parallelism, hermes, credit-exhaustion, verification, max-concurrency]
trigger: user writes "maksymalnie równolegle", "nie pytaj wszystko rownolegle do ukonczenia zadania", "kontynuuj", "delegacja", "subagenty", asks for Wave-based task execution (Wave 0/1/2 pattern), or explicitly asks to run multiple agents in parallel
context:
  - You are in a long-running coding session on a Polish-speaking project (AIGON-X)
  - The user expects maximum parallelism and treats credit-top-up/retry as continuation, not reboot
  - Paid models (deepseek/deepseek-v4-flash, etc.) may run out of Nous credits mid-work
  - Subagents return a consolidated batch result; the parent must decide whether to re-dispatch, finish manually, or abort
see_also: ['diff', 'execution-architecture-audit', 'hyperframes', 'init']
---

# Subagent Orchestration — Parallel Work Under Credit Constraints

## When to Use

- User says "maksymalnie równolegle", "kontynuuj", "doładuj i jedź dalej"
- A task naturally splits into 2-3 independent workstreams (e.g., refactor + scan + docs update)
- You need external verification or code review without blocking the current turn
- Manual work is not acceptable; the user expects parallel background execution

## Core User Constraint: "Agenty muszą pracować — nie mogą raportować sukcesu jeśli go nie ma"

This is the user's explicit, non-negotiable requirement (2026-07-23, after 15 subagents fabricated SSH deployment results):

**Subagents MUST produce verifiable evidence of completion, NOT self-reported success narrative.** A task is NOT done until you can prove it:
- `ssh target 'sha256sum /usr/local/bin/<binary>'` — same hash = no change
- `git diff --name-only` — empty diff = fabrication
- `curl -sf http://target:7000/health` — missing = no deploy
- `docker ps --format '{{.Status}}'` — same uptime = no restart

**SSH-based operations NEVER work via delegate_task.** Subagents cannot resolve hostnames, have no SSH keys. Always run remote ops directly via `terminal(background=true)`.

**When a batch returns fabricated results, do NOT re-dispatch.** Fix directly in the parent. See pitfall #23 for full analysis.

## Core Workflow

### 1. Split into independent, non-conflicting tasks

Subagents are ephemeral and have no shared context beyond what you pass. Each task must be self-contained.

Bad split:
- Subagent A: refactor `backend-rs/src/main.rs`
- Subagent B: also refactor `backend-rs/src/main.rs`

Good split:
- Subagent A: refactor backend into modules
- Subagent B: clean TODO/FIXME/HACK/placeholder from product code
- Subagent C: update STATUS.md and CANON.md with tribunal outcomes

Rule: **no two subagents should write the same file at the same time**. If they must touch the same file, serialize those two tasks and dispatch other tasks in parallel.

### 2. Batch order respects the concurrency ceiling

The runtime limits `max_concurrent_children` (commonly 3). If you pass 4 tasks to a single `delegate_task`, it rejects the call.

Options:
- Reduce the batch to ≤ the limit
- Split into multiple sequential `delegate_task` calls
- Combine two small tasks into one subagent goal

### 3. Check the consolidated result, not just the checkmarks

Hermes batches return `[ASYNC DELEGATION BATCH COMPLETE]` with per-task status. A task marked `status=completed` is **not** a guarantee the work was done, especially when credits run out.

Always scan the per-task output for strings like:

- `API call failed after 3 retries: HTTP 404: Model '...' requires available credits`
- `Your account balance is too low`
- `status=completed, api_calls=0`
- Empty file list / no diff / no test output despite a completed task

### 4. Decide based on verified evidence

| Finding | Action |
|---------|--------|
| Completed + real diff/build-run/test output | Accept and proceed |
| Completed + 0 output + `api_calls=0` | Reject; likely no execution happened |
| Completed + credit error in body | Re-dispatch on a free model or finish manually |
| Completed + tool error unrelated to model | Re-dispatch or finish manually depending on blocker |

### 5. Re-dispatch or backfill manually

If the user has just topped up credits (`doaldowalem kredyty`), re-dispatch the same task(s) on the paid model that previously failed.

If the user says they have added credits but you still see paid-model failures, verify the provider named in the subagent summary matches the funded provider (e.g., `deepseek/deepseek-v4-flash`). Re-dispatch on the correct model.

If credits are still missing or a re-dispatch keeps failing:
- Use a free model for the subagent (slower but no cost), OR
- **Do the work yourself in the parent while waiting** — this is *active backfill*. Run read-only audits, expand verification scripts, or fix small unrelated issues instead of sitting idle.

Never leave the user with a false-green report.

### 6. Avoid edit collisions between parent and subagents

6. **Letting the parent sit idle.** If one subagent is blocked on credits, continue independent work in the parent (read-only probes, manual tasks that don't conflict).
7. **Subagents may stage changes to the git index.** A failed subagent can leave both modified working-tree files and staged index entries. Run `git status --short` and, if the diff is untrusted, reset both index and working tree to HEAD (`git checkout HEAD -- <paths>` and `git reset HEAD <paths>`) before continuing.
8. **Trying to repair a broken subsystem in its corrupted state.** If a recent commit broke a whole subsystem, revert that subtree to the last known-good commit and re-apply only the intended minimal changes, rather than debugging the broken intermediate state.

## Verification Patterns

### A. Subagent outcome triage (fast)

For each task in the consolidated result:

1. Read the `Summary` section
2. Look for concrete artifacts: file paths created/modified, command outputs, test counts
3. If any artifact-promising task is missing artifacts, inspect the full subagent output path

### B. Ad-hoc verification after subagent edits

When a subagent claims to have built something, run independent commands **in strict mode first**:

```bash
cd <project> && cargo clippy -- -D warnings  # Rust — catches syntax/import/doc lint issues fast
cd <project> && cargo check --quiet          # Rust compile-only fallback
cd <project> && npx tsc --noEmit             # TypeScript
cd <project> && npm test -- --run             # Full test suite — catches semantic bugs invisible to typecheck (e.g. hash-chain payload inconsistency)
cd <project> && npm run build                # Node bundle
cd <project> && pytest -q                    # Python
```

Use `clippy -- -D warnings` before `cargo test`; many subagent defects (unused imports, missing braces, broken doc formatting) fail compilation only under clippy's stricter checks.

Do not reuse the subagent's own verification if it itself reported success but did no work.

### C. Post-survey domain project gap (2026-07-27)

After any container-based infrastructure survey (tenant_deployments, service inventory), system nginx on the host (port 443/80) may serve user-specific domains that containers miss. Check:

```bash
# System nginx config for user domains
ssh PROD 'sudo nginx -T 2>&1 | grep -E "server_name|proxy_pass"'

# DNS trace — Cloudflare IPs mean the origin is behind proxy_pass
for d in szamani.ai fartpol.com vairify.online; do dig +short "$d"; done

# Trace nginx proxy_pass → actual port → container
#   szamani.ai → proxy_pass 127.0.0.1:10000 → szamani-app (Port 3003)
#   fartpol.com → root /home/operator/sites/fartpol-cf (bind mount, not Docker)
#   vairify.online → proxy_pass 127.0.0.1:10081 → vairyfy-frontend (:5005)
```

**Root causes** of the gap:
1. `docker ps` lists only containerized services — system nginx, Caddy, systemd-managed tools are invisible
2. Domain mapping requires nginx config inspection, not just port listing
3. User's personal domains need a **separate tenant** (not "AIGON Mesh") with its own projects

**Fix**: Create tenant + projects + deployments for discovered domains. See `references/infrastructure-parallel-seed-verify-2026-07-27.md` for the full pattern.

### D. Live Transcript Monitoring — Watch Subagents While They Run

When 3+ subagents are running simultaneously (possible but time-consuming), you can monitor progress in real-time without waiting for the final consolidated result:

```bash
# Watch ALL subagent transcripts simultaneously (grouped by task ID)
for f in /home/operator/.hermes/cache/delegation/live/<delegation_id>/task-*.log; do
  echo "=== $(basename $f) ==="; tail -1 "$f"; echo
done
```

Or stream live with separate terminals:
```bash
# One terminal per subagent — use pty per call
tail -f /home/operator/.hermes/cache/delegation/live/<delegation_id>/task-0.log
tail -f /home/operator/.hermes/cache/delegation/live/<delegation_id>/task-1.log
# etc.
```

Each log line is timestamped (e.g. `05:12:04 assistant| ...`) showing what the subagent just said or did. After a `delegate_task` dispatch, the delegation_id appears in the dispatch response. Use it to construct the live transcript paths.

**Timing cue:** Long-running subagents that have been running for 60s+ with no output signal at the `assistant|` level may be stuck or credit-exhausted. Check if `api_calls` increments in their output — if stuck at 0 for 30s+, the subagent may be waiting on a credit check. Proceed with direct parent work rather than waiting.

```bash
git status --short
ls -la <modified_paths>
```

### D. Re-read files before editing

If you (the parent) need to continue a task started by a subagent, re-read the file first. Subagents may have written partial or conflicting content.

### E. Live transcript monitoring for parallel blocker fix — fix while subagent retries

When a subagent reports a **pre-existing build error** (missing import, wrong syntax, struct-reachability issue in an unrelated file), do NOT wait for the subagent to diagnose and retry itself. The subagent will spend 3-5 minutes running redundant verification commands before finally retrying. Instead:

1. **Detect**: While the subagent runs, tail its transcript: `tail -f /home/operator/.hermes/cache/delegation/live/<delegation_id>/task-0.log`
2. **Diagnose**: The subagent's first `cargo build` output already shows the exact error and the helptext fix (`help: consider importing this enum` + the exact `use` line to add). Read the file on the main thread and apply the fix.
3. **Fix**: Patch the file immediately on the main thread. One `patch()` call is enough for mechanical fixes like missing imports.
4. **Verify**: Run `cargo check -p <affected-crate>` on the main thread to confirm the fix compiles.
5. **Result**: When the subagent finishes its redundancy loop and retries the build, it compiles cleanly.

**Timing advantage:** The subagent's `cargo build --release` (185s) + redundant grepping (4 × 1-185s each) gives the parent 60-200s of head start. The fix takes <5s. The total wall clock for the task is the subagent's next build attempt, not its failed first attempt + its own diagnosis + fix + retry.

**When NOT to use this pattern:**
- The error is a design/implementation gap (wrong algorithm, missing feature) — let the subagent redesign and retry
- The error spans multiple files with cross-crate dependency — the subagent has better context to plan the fix
- The error originates from the subagent's own code (wrong method signature) — fix by re-reading the subagent's output and fixing in the parent after the subagent returns

**Real example (2026-07-27):** Subagent STREAM F ran `cargo build --release -p aigon-runtime-bin` → `error[E0428]: use of undeclared type 'RecordKind'` in `knowledge_pipeline.rs`. The error's helptext showed `12 + use crate::time_machine::RecordKind;`. Parent read the file at lines 1-19, patched `use crate::time_machine::TimeRecord;` → `use crate::time_machine::{RecordKind, TimeRecord};`, ran `cargo check -p aigon-runtime` (0 errors). The subagent's subsequent retry compiled cleanly in 1.21s. Total parent time: ~15s. Estimated subagent self-diagnosis time: 3-5 minutes (it was reading files, searching for `pub enum RecordKind`, running redundant greps).

## Concurrency Limit Workarounds

If `max_concurrent_children=3` but you have 4 tasks:

### Option A: Squash two small tasks
Combine a read-only audit task with a small write task under one subagent:

> "Audit TODO markers in backend/ and delete the obvious placeholder comments. Return a diff and run `cargo check`."

### Option B: Sequential batches

```typescript
// First batch of 3
await delegate_task({ tasks: [A, B, C] })
// Second batch of remaining tasks
await delegate_task({ tasks: [D] })
```

Use this when the left-out task depends on A/B/C outputs.

### Option C: Move trivial checks into the parent

## Parallel File Modifications with Shared Interface Contract

A specific pattern for dispatching subagents to make **compile-dependent changes** across a Rust/TypeScript workspace. Unlike independent workstreams, these subagents share a common interface contract (types, method signatures, import paths) and each modifies a different file. The key risk: individual crate checks pass, but cross-crate integration fails due to naming drift.

### When to use

- You need to add new protocol messages, API endpoints, and wiring code across multiple files
- Each file can compile independently (`cargo check -p <crate>`) without the other changes
- The changes share a common interface contract (enum variants, method signatures, type paths)
- User said "maksymalnie równolegle" for implementing a multi-file change

### Workflow

**Step 1: Read ALL files first** — Read every file that needs modification in one batch. Understand the current structure, imports, and patterns for each file.

**Step 2: Define the interface contract** — Before dispatching, define the exact signatures that ALL subagents will share. The contract must specify exact method signatures, type paths, and import strings — not descriptions.

```
RIGHT:
  Runtime::set_mesh_transport(transport: Arc<TcpMeshTransport>)
  Runtime::dispatch_task(target_node_id: &NodeId, task_id: Uuid, payload: &str) -> Result<(), String>
  TcpMeshTransport::send_task(target_node_id: &NodeId, task_id: Uuid, payload: &str) -> Result<(), String>

WRONG:
  "Add a way to send tasks through the mesh transport"
```

**Step 3: Dispatch one subagent per file** — Each subagent gets:
- The FULL current contents of its file (from Step 1 reads)
- The EXACT interface contract (what the other files expect from it)
- Its goal: modify ONE file, no others
- `cargo check -p <its-crate>` as verification

**Step 4: After ALL return, verify workspace integration** — After all subagents complete:

```bash
cargo check --workspace 2>&1  # or equivalent full build
```

The single-file checks pass before the subagent returns, but the full workspace check reveals interface drift (wrong method names, missing imports across crate boundaries) that the isolated checks couldn't catch.

### Risks and mitigation

**Risk 1: Naming drift** — One subagent names a method `dispatch_task()` but another subagent calls it `send_task_to_mesh()`. File-level checks pass, cross-crate integration fails.

**Mitigation:** Specify the exact method signature (name + params + return type) in EVERY subagent's goal. The signature is the atom of the contract.

**Risk 2: Import path mismatch** — One subagent uses `aigon_mesh::transport::TcpMeshTransport` while another uses `aigon_scheduler::mesh::TcpMeshTransport`.

**Mitigation:** Specify the EXACT import path in each subagent's goal: `use aigon_mesh::transport::TcpMeshTransport;  // ONLY this path`

**Risk 3: Unsynchronized struct+constructor** — One subagent adds a field to a struct but another needs to modify the constructor in the same file.

**Mitigation:** Never split a struct definition + constructor across two subagents. Include constructor/initializer changes in the same subagent's scope. The split boundary should be at file boundaries, not function boundaries.

**Risk 5: Cross-language type naming drift (Rust ↔ TypeScript)** — When dispatching subagents to align Rust structs and TypeScript interfaces, one subagent renames `verified` → `verified_claims` in Rust while another expects `verified` in TypeScript. Types are independently validated (Rust cargo check, TypeScript tsc), so each side can pass individually while being mutually incompatible.

**Mitigation:** Embed the **COMPLETE target struct definitions** (not just deltas) in every subagent's context. Each subagent must construct the full struct from the embedded definition, not infer field names from context.

```
RIGHT — embed complete struct in every subagent's context:
  DashboardStats { verified_claims: u64, hallucinated_claims: u64, ... (11 fields) }

WRONG — subagent must guess from incomplete description:
  "Rename verified to verified_claims on DashboardStats"
```

**Risk 6: Incomplete new-field defaults cause runtime panics or zero values** — When adding new fields (e.g. `average_trust_score`, `active_mcp_servers`) to backend structs, subagents set defaults like `0` or `Utc::now()`. But if some subagent constructs the struct via a different code path (store.rs vs db.rs vs main.rs) and uses a different default, the field has inconsistent values at different endpoints.

**Mitigation:** Include a **defaults cheat sheet table** (type → new field → default value) in every subagent's context. All subagents must use the EXACT same defaults from the table for every construction site of the new field. Cross-check after merge by searching for all construction sites of the changed types.

### Real example — Vairyfy SaaS FE↔BE alignment (2026-07-24)

- 5 subagents dispatched in parallel, each modifying different files
- Shared target: full struct definitions (18 Rust structs, 14 TypeScript interfaces) with 20+ field renames and 15+ new fields
- Every subagent received the COMPLETE target types.rs content in its context
- Files: `types.rs`, `types/index.ts`, `main.rs`, `store.rs`, `db.rs`, `governance.rs`, `api.ts`, `dashboard/page.tsx`
- All 5 individual checks passed; workspace integration verified with `cargo check + cargo test + npm test`
- Total wall-clock time: ~3 min vs ~15 min serial (estimated)

**Mitigation:** Keep the contract to the MINIMAL set of shared types/signatures. The cross-crate integration check catches any mismatch. Let each subagent implement internal logic as it sees fit.

### Real example

From AIGON-Runtime v2 Phase 1 Foundation (2026-07-23):
- 4 subagents dispatched simultaneously, each modifying one Rust file
- Shared contract: ExecuteTask/TaskResult message types, send_task/set_mesh_transport/dispatch_task method signatures
- Files: `aigon-mesh/src/transport.rs`, `aigon-runtime/crates/aigon-runtime/src/lib.rs`, `aigon-runtime-bin/src/main.rs`, `aigon-runtime/crates/aigon-runtime/src/api.rs`
- All 4 individual `cargo check -p <crate>` passed
- Full workspace check after merge catches any cross-crate import drift
- Total time: ~2-3 min (parallel x4) vs ~8-10 min serial

### Provider stream error — retry with shorter prompt

`Provider returned an empty stream with no finish_reason` (possible upstream error or malformed SSE response)

| Scenario | Signal | Response |
|----------|--------|----------|
| **Single subagent failing** (others succeed) | One task in batch returns empty stream | Reduce the subagent goal to the simplest possible instruction. The empty-stream error is correlated with prompt length/complexity. After shortening, retry once. If it fails again, do the work directly in the parent. Do NOT keep retrying with the same long prompt. |
| **ALL subagents failing (batch-wide)** | Every task returns the same empty-stream error | **Do NOT re-dispatch.** The error is NOT prompt-length related — the provider itself is failing on this count of parallel requests. Do the work directly in the parent. The parent already has all context and can produce artifacts faster than waiting on a failing provider. |
| **ALL subagents fail with `.claude` model shown** despite config saying `deepseek` | Batch result header shows `Model: .claude` even though parent uses `deepseek-v4-flash` | **Delegation provider pinning trap.** Check `~/.hermes/config.yaml → delegation.*`. If `delegation.provider` and `delegation.model` are explicitly set, they override the parent session model entirely. Even if the parent uses `deepseek/deepseek-v4-flash`, the pinned delegation may route through a different fallback chain — possibly via `aigon-runtime → qwythos-9b` which can't handle 10+ parallel streams. **Fix:** Either remove the delegation pins entirely (so subagents inherit parent model) or set both to match the parent: `hermes config set delegation.provider deepseek && hermes config set delegation.model deepseek-v4-flash`. **Diagnosis:** `grep -A5 'delegation' ~/.hermes/config.yaml` |
| Concurrency error | `Too many tasks: 4 provided, but max_concurrent_children is 3` | Reduce batch size or split into multiple calls |
| Overlapping file edits lead to stale patches | Patch fails with "unique match" errors | Re-read file and rewrite or use `write_file` |\n| Concurrent edits to same file produce structural corruption | `cargo check` fails with orphaned code, duplicate match arms, dangling expressions | **Never dispatch two subagents to the same file in parallel.** Serialize same-file tasks. Clean up by re-reading the file, removing orphaned blocks, and re-applying only the intended minimal changes. |\n| Subagent claims success but verification fails | Build/typecheck fails after merge | Treat as incomplete; the subagent may have had stale context |
| User revokes subagent permission mid-task | Out-of-band message like "nie wciskaj subagentow", "dzialaj sam", "no subagents" | Stop immediately. Do not start new subagents or re-dispatch. Complete the work directly in the parent (if feasible) or report remaining blocker to the user. Discard any subagent results that arrive later unless the user re-authorizes them. |
| Connection error on a single task | One task returns `Connection error` but others succeed | The provider/mesh is flaky but reachable. Re-dispatch only the failed task once. If it fails again, do the work directly in the parent. The parent has the same context and can produce artifacts faster than retrying a failing provider. |
| Connection error on ALL tasks (batch-wide) | Every task in the batch returns `API call failed after 3 retries: Connection error` | **Do NOT re-dispatch.** This is not a model/credit issue — the mesh network is down, the provider is unreachable, or the subagent endpoint itself is unhealthy (common even when the parent's direct chat still works on the same provider). The subagent dispatch infra and the parent chat may use different routes. **Backfill technique (proven on 52 crates):** Use `execute_code` to batch 3-5 `write_file` calls per turn. Group by concern (all engine crates, all provider crates, all infrastructure crates). Before writing, check each crate's `Cargo.toml` for `anyhow`/`serde`/`thiserror` deps — many stub Cargo.tomls have an empty `[dependencies]` section. After writing, run `cargo test -p crate-a -p crate-b` on all changed crates, fix compilation errors (missing deps, borrow-checker issues, fencepost errors — `>=` vs `>` for max limits, zero-vector cosine similarity), and repeat until all pass. The parent has all the context and produces artifacts faster than retrying a failing provider. After finishing, check subagent health separately: the issue may be transient. |
| Provider stream error — retry with shorter prompt | `Provider returned an empty stream with no finish_reason` (possible upstream error or malformed SSE response) | **Single subagent failing (others succeed):** Reduce the subagent goal to the simplest possible instruction. The empty-stream error is correlated with prompt length/complexity. After shortening, retry once. If it fails again, do the work directly in the parent. Do NOT keep retrying with the same long prompt. **ALL subagents failing (batch-wide):** The provider is down, not the prompts. Do NOT retry at all — do the work directly in the parent. The parent already has all context and can produce artifacts faster than waiting on a failing provider. |

## Credit-Efficient Patterns

- Use free/cheap models for subagents that only need to `grep`, summarize, or generate boilerplate
- Reserve expensive models for subagents doing complex reasoning (architecture refactor, security audit, code synthesis)
- When the current provider is exhausted, ask the user to top up; do not silently retry the same paid model endlessly
- Keep subagent prompts focused; shorter context = fewer tokens and fewer failures

## Pitfalls

1. **Subagents run on ONE host, not the mesh.** Hermes `delegate_task` spawns subagents as isolated conversations within the same Hermes process on the LOCAL machine. Despite an 8-node AIGON-X Mesh with 7 healthy peers, MAIPS bridge (port 9001), and yairoslaw consensus, subagents NEVER use remote nodes. The Runtime mesh transport (`MeshMessage` enum in `transport.rs`) has only: Handshake, Heartbeat, HeartbeatAck, StateUpdate, Disconnect — NO ExecuteTask, DispatchAgent, or RemoteSpawn protocol. `TcpMeshTransport` exists in code but is never started from `main.rs` or `Runtime::boot()`. All schedulers (`AdaptiveScheduler`, `CarbonScheduler`, `MasterScheduler`) operate on local CPU cores only. Remote nodes advertise only `["kernel","tick"]` capabilities — no "compute" or "executor". **Implications:** 7 remote nodes sit idle while all agent work queues on one machine. CPU-bound tasks don't benefit from 24+16 cores on other nodes. GPU inference can't be offloaded. **Verification:** `/health` shows peers with capabilities. **Fix requires extending mesh protocol + wiring TcpMeshTransport.** See `execution-architecture-audit` skill for the methodology to trace this gap.

2. **Trusting `status=completed` blindly.** The status is "agent loop finished", not "work was produced". Always require evidence.
3. **Subagent returns `completed` after a model credit failure.** When the subagent's own model is exhausted, it may report completion while producing no useful output and leaving files corrupted. Inspect for `HTTP 404: Model '...' requires available credits` and treat the task as unfinished.
4. **Subagent leaves code in a broken state even when it claims success.** Because ephemeral subagents may write malformed or partial edits after credit errors or context drift, the parent must verify the build and, if broken, fall back to `git checkout -- <file>` and re-apply only the intended minimal change.
4. **Ignoring credit errors.** They look like model-provider errors wrapped in subagent output; the first glance scan misses them.
5. **Dispatching overlapping writers.** Two subagents editing the same file produce patch conflicts and silent overwrites.
6. **Asking the user questions mid-dispatch.** User explicitly stated "nie pytaj wszystko rownolegle do ukonczenia zadania" — dispatch everything you can, then report results when done. Do NOT pause to ask for decisions mid-work.
7. **Single-batch-at-a-time dispatch.** When you have multiple batches (e.g. Wave 0 has 9 tasks → 3 batches of 3), dispatch ALL batches immediately. They queue at the `max_concurrent_children` ceiling. Don't wait for batch 1 to finish before dispatching batch 2 — this wastes time.
8. **Not committing + pushing before declaring done.** Final deliverable is always: commit → push → verify → report. User expects "zacomituj zmerguj" as part of done.
9. **Using emoji in enterprise/production content.** User explicitly said "nie chcemy emotek" — no emoji icons in landing pages, UIs, or documentation for enterprise products. Use inline SVGs or plain text instead.
10. **Not checking user's local env before fixing local issues.** When user reports "lokalnie nie dziala backend", first check `ps aux | grep aigon-code-server`, `docker ps`, `cat .aigon/wallet.json`, `cat .aigon/settings.json` — don't assume cloud vs local.
11. **Rate-limited subagent creates empty directories.** When a subagent hits HTTP 429 (credit exhausted), it may still report `status=completed` but only created empty directory stubs (e.g. `tools/`, `scripts/` with no files). Always verify that expected files exist with actual content, not just that directories were created. Check with `find <dir> -type f` not just `ls <dir>`.
12. **Multiple subagents concurrently patching the same file can produce structural corruption, not just patch-failures.** When subagent A inserts one set of match arms and subagent B inserts different match arms in the same block, both patches can *succeed* against the base file but the merged result contains orphaned/duplicate code — the file still has balanced braces but semantically invalid structure (e.g., duplicate match arms, dangling expressions between closing braces). This is more dangerous than a patch failure because `cargo check` is needed to catch it, and the file appears superficially correct. **Never dispatch two subagents to edit the same file.** If the task genuinely requires parallel edits to one file, serialize those tasks and parallelize the rest.
13. **Exceeding `max_concurrent_children`.** The call is rejected; you must split the batch.
14. **Letting the parent sit idle.** If one subagent is blocked on credits, continue independent work in the parent (read-only probes, manual tasks that don't conflict).
15. **Not verifying after batch merge.** Each batch can change the codebase; run the canonical verification (`cargo check`, `tsc --noEmit`, etc.) after applying changes.
16. **Not requiring precise reporting from subagents.** Subagents default to summaries. Always add "Report ALL results precisely" to the task goal so the parent gets exact outputs (file paths, error counts, test passes/fails) not narrative descriptions.
17. **Not specifying the output language for subagents.** When the user communicates in a non-English language (Polish, etc.), subagents default to English summaries. Add "respond in Polish" / "odpowiadaj po polsku" / "zwróć wyniki po polsku" to each task's `context` field. Without this, subagent summaries arrive in English and the parent must manually translate them.
18. **Subagent model lacks tools.** Subagents inherit the parent model. If the parent runs on a model without tool access (e.g. qwythos-9b on Ollama mesh), subagents will also lack tools — they complete with `api_calls=0` and produce no artifacts. Verified 2026-07-18: 7 subagents dispatched across 2 batches, all ran on qwythos-9b, all returned `status=completed` with no actual work. Subagent summary shows `<tool_code>...</tool_code>` blocks describing what they WOULD do, but no terminal/file execution. **Fix:** Before dispatching subagents, verify the active model supports tools. If not, switch to a tool-capable model (deepseek-v4-flash, claude-sonnet, etc.) first. The subagent model is not independently selectable — it inherits from the parent's conversation context.
19. **Subagent silently changes infrastructure config in unrelated projects.** When dispatching subagents to fix frontend lint, type errors, or similar narrow-scope tasks in a monorepo, subagents may independently find and modify sibling CLI projects — changing `baseUrl`, port numbers, API keys, or provider routing (e.g., changing `localhost:7000` to `prod-aigon:7000` in `aigon-code/cli/src/runtime/client.ts`). They may also CREATE new files in unrelated projects (e.g., `providers.ts` in a sibling CLI package). These changes are outside the task scope and silently break local development. **Detection:** Always run `git diff --stat` AND `git status --short` across the whole repo after subagent completion. Check for new untracked files in unexpected directories. **Fix:** Revert with `git checkout HEAD -- <file>` for modified files and `rm -f <new-file>` for created files. **Prevention:** Pin scope explicitly in BOTH the `goal` and `context` fields. Add "Do NOT modify files outside `products/vairyfy-saas/frontend/src/`" — set the strict boundary in both fields so the subagent sees it in its goal summary AND in its context preamble. This guards against the subagent ignoring one of the two fields.
20. **Subagent task without `workdir` may roam beyond the project.** When the parent's session cwd is a monorepo root, subagents default to that root and may edit any sibling package. To contain edits to one subtree, add the scope restriction to both `goal` and `context` AND mention the absolute path of the allowed directory.
21. **`delegation.provider` points to remote runtime that may be unhealthy.** `config.yaml: delegation.provider: aigon-prod` resolves `prod-aigon:7000` to a remote node via Tailscale. If that node's runtime is restarting, subagents timeout silently — each subagent waits ~30s on connection before the batch completes with empty results. **Diagnosis:** Check `getent hosts prod-aigon` and `curl -sf --max-time 30 http://prod-aigon:7000/health`. If the remote node is cycling, switch delegation to `aigon-runtime` (localhost:7000) which is always available. The local runtime routes inference to the same backends. **Fix:** `hermes config set delegation.provider aigon-runtime`
22. **Subagent with `.mesh` model (AIGON runtime) — ACCT injection corrupts output.** When dispatching subagents using the `.mesh` model alias (routes through `qwythos-9b` on AIGON runtime), the runtime injects ACCT (Adaptive Cognitive Computation Topology) meta-program data into the system prompt. The subagent receives this meta-programming output instead of its task context, producing ACCT instruction blocks as its "investigation results." Verified 2026-07-21: 2 subagents dispatched to trace chat completion pipeline and check mesh swarm architecture — both returned ACCT program instruction blocks. **Symptom:** Subagent output starts with `[Mock] ## ACCT Program { "instructions": [...] }` followed by skills listing instead of investigation findings. **Fix:** Use a non-mesh tool-capable model for investigation/analysis subagents (e.g., `deepseek-v4-flash`, `claude-sonnet-4`). Do NOT use `.mesh` alias for subagents that need to read files and produce structured output.

23. **Subagent claims deploy/restart completion without executing — SSH, SCP, and Docker.**  

    **Related — safe remote process kill:** When you (parent) must kill a remote runtime process directly from the parent's `terminal()` session, use `pidof aigon-runtime-v2` not `pgrep -f aigon-runtime-v2`. The `-f` flag matches the SSH connection's process list (which includes the full command string containing "runtime"), killing your own SSH session and leaving the remote node inaccessible. `pidof` matches only the exact binary name and is safe. Also beware of heredoc or eval'ed sub-commands that contain the binary name in their string — they can also match `pgrep -f` and terminate the SSH connection.

    **Silent kill failure — process owned by another user.** Even `pidof` + `kill` can fail silently. The `kill` command returns exit code 0 and prints no error, but the process remains alive because the target PID is owned by a different user (e.g., the runtime was started by `claude` user, but you SSH as `sniegul`). Shell `kill $PID 2>/dev/null` swallows the EPERM error. **Detection:** After `kill $PID; sleep 3; pidof aigon-runtime-v2`, if the same PID still appears, check its owner: `ps -o user= -p $PID`. If it says a different user, you cannot kill it without sudo. **Fix:** Use `sudo kill $PID` when available, or SSH as the process owner directly. When neither is possible, accept the ghost process and start a new instance — the old one won't interfere as long as it doesn't hold the listen port.

    **SCP-specific limitation:** Even subagents that CAN authenticate and SSH (not fabricated) cannot SCP files from the parent's LOCAL filesystem. The subagent runs in an isolated conversation with its own terminal session — it has no access to `/home/operator/bin/`, `<workspace>/runtime/target/release/`, or any other path on the parent machine. A subagent task with `scp <workspace>/runtime/target/release/aigon-runtime-v2 sniegul@remote:/tmp/` will fail because the source path doesn't exist in the subagent's filesystem. **Fix:** Pre-copy the binary to every remote node from the parent (`terminal()`), THEN dispatch subagents for any remaining orchestration tasks (config edits, service restarts, verification). Or dispatch background `terminal()` processes from the parent for the entire SCP+kill+restart flow rather than using subagents at all.

    Subagents dispatched to operate on remote machines (SSH commands, SCP, Docker cp+restart, apt/npm/pip installs) may report `completed` with `api_calls=1-2` and a narrative like "I'll copy the binary and restart" — but no actual commands were executed. Verified 2026-07-23: 15 subagents dispatched to install aigon-code, claude, hermes, ollama, API keys, and runtime fix on 6 remote nodes via SSH. ALL 15 returned `completed` with fabricated output. Reality: zero SSH/SCP processes seen on any target, files absent, versions unchanged.

**Root cause:** Subagents inherit the parent model but exist in ISOLATED conversation contexts with NO memory of the parent's SSH config, known_hosts, agent forwarding, or target hostnames. When a subagent's goal says "SSH into prod-aigon and run X," it cannot resolve the hostname and has no credentials — so it generates a narrative describing what it WOULD do and returns `completed`. Subagents do not intentionally deceive; they lack environmental access they assume exists.

**Detection patterns:**

| Method | Command | Signal |
|--------|---------|--------|
| **Processes on target** | `ssh target 'ps aux \| grep -E "(ssh\|scp\|apt\|npm\|pip)"'` | Zero SSH-originated processes → no connection |
| **File existence** | `ssh target 'ls -la /usr/local/bin/<expected>'` | File absent → no deploy happened |
| **Binary hash** | `ssh target 'sha256sum /usr/local/bin/<binary>'` | Same hash pre- and post-dispatch → no replacement |
| **Version string** | `ssh target '<command> --version'` | Unchanged from expected → no action |
| **Container uptime** | `docker ps --filter name=$CONTAINER --format '{{.Status}}'` | Same uptime → no restart |
| **Container image tag** | `docker inspect $CONTAINER --format '{{.Config.Image}}'` | Wrong tag (`:latest` vs `:landing`) → subagent verified container exists but did not check WHICH image is running. Common failure: a SEPARATE container with the new image was created (e.g. `aigon-runtime-v2-landing` on port 8081) while the MAIN container on the expected port still runs the old image. Subagent reports "already running" because it sees the container name, not the image tag. Verify with `docker ps --format '{{.Names}} {{.Image}} {{.Ports}}'` to catch split deployment. |
| | **Variant: subagent claims image tag check passed** | Subagent reports "already running `:landing` image, verified" but `docker inspect $CONTAINER --format '{{.Config.Image}}'` shows `:latest`. The subagent's "verification" is fabricated — it describes what it WOULD check, not what it actually checked. Always re-verify the image tag yourself after ANY subagent deployment. |

subagent-orchestration/skill — SSH fabrication pitfall

**Fix:** Do NOT dispatch subagents for SSH-based remote operations.

=== CORNER CASE — SSH deploy via bash script on /tmp/ ===

The ONE pattern where subagent-mediated SSH deployment works:

1. Subagent writes a deploy bash script to the parent's filesystem via write_file
2. Subagent executes it via terminal()
3. The script runs on the PARENT machine, inheriting SSH config, keys, and network

Why this works: the terminal() call runs on the parent shell, not in the subagent's
isolated context. The bash script on /tmp/ has full access to:
- SSH config (~/.ssh/config, ~/.ssh/config_aigon) with IdentitiesOnly=yes key files
- SCP source files at parent paths
- Tailscale network resolution for remote IPs

Critical conditions:
- The script MUST use SSH config aliases (e.g. prod-aigon), not raw sg@IP
- Raw Tailscale IP SSH with non-local user fails (Tailscale SSH interception)
- After the script completes, verify via parent SSH: ssh alias 'docker ps'

Example verification after deploy script:
```bash
for alias in prod-aigon contabo-aigon; do
  ssh $alias 'docker ps --filter name=aigon-runtime-v2 --format "{{.Names}} {{.Status}}"'
done
```

Real example (2026-07-27): Subagent wrote /tmp/deploy-runtime-v2.sh via write_file,
then terminal("bash /tmp/deploy-runtime-v2.sh"). Script deployed Docker image to
6 remote nodes in parallel. All 6 showed DEPLOY OK + Up (healthy) on verification.

=== Standard SSH operations still fabrication-prone ===

Before dispatching any subagent for remote operations, check:

24. **Commit-push-build-deploy-e2e is the completion pipeline.** User expects commit → push → build → deploy to ALL remote nodes → test e2e as ONE deliverable after changes compile. Do NOT stop after `cargo check` passes — continue through build, SCP to every remote node, restart containers, and run end-to-end verification (curl health, POST to new endpoints, verify log output). User says "gdy skonczysz commit,push, build deploy na wszystkie remote test e2e" — this defines "done". Stopping at "compiles OK" is incomplete.

26. **Subagent using `.claude` / `codex` / `opencode` model
    - **T1**: dispatched to fix `crates/aigon-kir/src/pipeline.rs` (replace mocked KVMExecute with real `KnowledgeVM::execute(module)`). Returned 376s narrative covering file creation, struct modification, constructor update, `cargo check` and `cargo test` verification — but `git status` showed no changes.
    - **T7**: dispatched to wire MemorySystem into KVM (add `memory: Option<MemorySystem>`, wire 6 instruction handlers). Returned 773s narrative with the same claim structure — `git status` clean, no files modified.

    **Root cause:** These CLI-based delegation models (`.claude`, `codex`, `opencode`) run as separate processes that may open files, generate diffs in their own context, but never write to the parent's working tree. The subagent's isolated terminal session has a different working directory, a stale git index, or the model generates patch descriptions without executing file-write tool calls. The `api_calls=1` may represent a single interaction (opening the file) rather than any write operation.

    **Detection patterns:**

    | Check | Command | Finding → Action |
    |-------|---------|------------------|
    | Git status | `git status --short` | Empty → fabrication. Do NOT trust the subagent's report of modified files. |
    | Git diff | `git diff --name-only` | Empty → no files changed. The file content is exactly as before dispatch. |
    | File checksum | `sha256sum <file>` | Same as before dispatch → no modification. |
    | Test results | `cargo test -p <crate>` | Same pass/fail pattern as before dispatch → no code changed. |

    **Mitigation:**
        1. **Before dispatching**, record `sha256sum` of target files and `git diff --name-only` as baseline.
        2. **After the subagent returns** (before acting on its report), re-run `git diff --name-only`. If empty, the subagent fabricated its work — re-do manually.
        3. **Avoid `.claude`/`codex`/`opencode` delegation models** for tasks requiring local file modifications unless you have verified they can write to the working tree. Prefer `leaf` subagents that inherit the parent's tool-capable model (e.g. `deepseek-v4-flash`) for file-editing tasks — these do use the same Hermes `write_file`/`patch`/`terminal` toolset.
        4. **If you must use a CLI-based delegation model**, add a verification step to the task goal: "After modifying files, run `sha256sum <target-file>` and `git diff --stat` and include the output in your summary." This forces the subagent to actually touch the filesystem, or reveal the fabrication when it returns unchanged hashes.

## Reference

- `references/subagent-credit-exhaustion-2026-07-12.md` — real transcript from an AIGON-X session where a subagent reported `completed` but produced no backend refactor because `deepseek/deepseek-v4-flash` ran out of Nous credits.
- `references/subagent-syntax-defect-checklist-2026-07-13.md` — checklist of syntax/lint defects left by a successfully-completed subagent batch, and the strict-lint verification that catches them.
- `references/concurrent-editor-corruption-maips-bridge-2026-07-15.md` — transcript of three subagents concurrently editing the same Rust file, producing orphaned match arms and structural corruption despite all patches succeeding individually.
- `references/pillar-wave-orchestration-2026-07-16.md` — Wave-based 3-phase orchestration pattern used to complete 37 tasks across 6 pillars in 30 minutes. Includes task-plan format, batch dispatch strategy, and post-Wave verification.
- `references/claude-code-local-fabrication-2026-07-23.md` — Full transcript of a `.claude` model subagent that fabricated file modifications.
- `references/mass-parallel-crate-implementation-2026-07-23.md` — Pattern for dispatching 40+ subagents to implement 52 stub Rust crates across 2 batched `delegate_task` calls.
- `references/self-awareness-roadmap-parallel-dispatch-2026-07-24.md` — Pattern: save a skill THEN immediately dispatch parallel execution of its recommendations.
- `references/subagent-rust-brace-fix-pattern-2026-07-24.md` — Systematic repair of subagent-generated Rust code.
- `references/audit-findings-parallel-fix-2026-07-25.md` — Audit → decompose N bugs per-file → subagent failure → direct parallel fallback.

27. **Delegation model pin staleness — API provider dropped support.** When `~/.hermes/config.yaml` has `delegation.model` pinned to a model the provider no longer serves (e.g. `deepseek-reasoner` deprecated in favour of `deepseek-v4-flash`/`deepseek-v4-pro`), ALL subagents fail identically with `HTTP 400: The supported API model names are ...`. Every delegation call fails silently.

    **Symptom:** ALL subagents in a batch return `status=completed` with `api_calls=1` each, and the consolidated result shows `Model: deepseek-reasoner` (stale model) even though the parent session runs a different model. The single `api_call` is the HTTP 400 — no tool execution occurs.

    **Diagnosis:** `grep -A3 'delegation' ~/.hermes/config.yaml`

    **Fix (agent can't write ~/.hermes/config.yaml directly):**
    ```bash
    python3 -c "
    import re
    with open('/home/operator/.hermes/config.yaml') as f:
      content = f.read()
    content = re.sub(
      r'delegation:\s*\n\s+model: deepseek-reasoner',
      'delegation:\n  model: deepseek-v4-flash',
      content
    )
    with open('/home/operator/.hermes/config.yaml', 'w') as f:
      f.write(content)
    "
    ```

    **Prevention:** Periodically verify `delegation.model` matches a currently-supported provider model. API deprecation is async — you only discover it when delegation starts returning 400s.

28. **Subagent leaves `***` placeholder text in TypeScript code** — Subagents that cannot determine a parameter type or value may write `apiKey: ***` as a placeholder instead of the correct type. `***` appears in THREE distinct contexts, each with a different fix:

    | Context | Example | Meaning | Fix |
    |---------|---------|---------|-----|
    | **Type interface field** | `SaasContext { apiKey: *** }` | The field type is undefined. ALL consumers break — not just this file. | Replace with the correct type (`ApiKey`, `string`, etc.) in the interface definition FIRST, then re-check dependent files. |
    | **Function parameter** | `function resolveApiKey(apiKey: ***, db)` | The parameter type is missing. | Replace with the correct type. If the parameter is a raw string (from headers), use `rawKey: string` — see naming convention below. If it's a full DB record, use the imported interface name. |
    | **Returned/assigned value** | `return { tenant, apiKey: *** }` | The VALUE is a placeholder — not just the type. | Determine the correct runtime value (e.g., the `candidate` from a loop, or the `resolution.apiKey` from a DB query result). |

    **Naming convention:** When a raw API key string (from `x-api-key` header) coexists with an imported `ApiKey` type, name the parameter `rawKey: string` — NOT `apiKey: string`. This prevents shadowing the type name and makes it clear at a glance whether the variable holds the raw header value or the database record.

    **Chain resolution:** `***` in a type INTERFACE (types.ts) cascades to all files that import it. Fix the root definition first, then downstream files. In one session, fixing required a 3-file chain: types.ts (SaasContext.apiKey type) → resolve.ts (KeyResolution.apiKey + parameter) → saasMiddleware.ts (construction of SaasContext).

    **Type-safe construction with `satisfies`:** When constructing an object that satisfies an interface with replaced `***` fields, use the `satisfies` keyword instead of `as InterfaceName`. `satisfies` catches structural mismatches (missing fields, wrong types) at compile time, while `as` silently permits any shape:
    ```ts
    // RIGHT — fails at compile time if shape is wrong
    { tenant, apiKey, policy } satisfies SaasContext;
    // WRONG — silently permits wrong shapes
    { tenant, apiKey } as SaasContext;
    ```

    **Detection:**
    ```bash
    grep -rn '\*\*\*' src/ --include='*.ts' --include='*.tsx'
    ```
    Always run this after any subagent batch that produces TypeScript code. Also check for double-dot syntax errors and `\brawKey\b` naming:
    ```bash
    grep -rn '\\.\\.\w' src/ --include='*.ts' | grep -v '\\.\\.\\.' | grep -v '/\*\*'
    ```
    (Catches `config...iKey`, `state..status`, and similar subagent syntax defects.)

    **Fix:** Replace `***` with the correct type/parameter. Check the function signature or interface the file imports from.

    **Prevention:** In every TypeScript-generating subagent goal, add: "Do NOT use `***` as placeholder text. If you cannot determine a type, import from the canonical source or use `any` with a `// TODO` comment."

29. **Express `express.raw()` before `express.json()` for Stripe webhook** — When mounting a Stripe webhook handler that verifies signatures, the raw-body parser must be applied to the webhook route BEFORE the global `express.json()`. If `express.json()` runs first, `stripe.webhooks.constructEvent()` fails with `400: No signatures found`.

    **Known working pattern:**
    ```ts
    app.use((req, res, next) => {
      if (req.path === '/stripe/webhook') {
        express.raw({ type: 'application/json' })(req, res, next);
      } else {
        express.json()(req, res, next);
      }
    });
    ```

    **Detection:** Webhook always returns 400 on signature verification despite correct key. Check `req.body` type — if it's an object (not Buffer), the raw parser is missing.

30. **Write-path / verify-path payload inconsistency in hash-chain or checksum code** — When subagents (or any code generation) produce both a "record" function and a "verify" function over hash-chained data, the canonical payload fed to the hash function MUST be IDENTICAL in both paths. A common manifestation: the record function includes a zero-value or empty field (e.g. `hash: ''`) in the serialized payload because that field is set before computing, while the verify function strips the hash field before recomputing. The JSON strings differ by a single key-value pair — typecheck passes, but the test (`verifyAuditChain()` returning `{ valid: false }`) catches it.

    **Mitigation:**
    - Extract a shared payload-construction helper used by BOTH write and verify paths. Never construct the payload independently on each side.
    - After generating write+verify logic, run the full test suite (not just typecheck) — the test is the only signal for this class of bug.
    - Trace the EXACT value being serialized on both sides by capturing `JSON.stringify()` output and diffing.
    - See `references/write-verify-payload-inconsistency-2026-07-25.md` for a full transcript.

    **Example fix (TypeScript):**
    ```diff
    - record.hash = computeAuditHash(record, prevHash);
    + const { hash: _h0, ...recordForHash } = record;
    + record.hash = computeAuditHash(recordForHash, prevHash);
    ```

31. **Subagent adds struct field init without adding the field to the struct definition** — A subagent tasked with wiring a new subsystem into the Runtime constructor may independently add `secret_guardian: tokio::sync::Mutex::new(...)` as a field initialization in `fn new()` without checking whether the struct actually has a field named `secret_guardian`. Individual `cargo check -p aigon-runtime` passes (cached build artifact), but `cargo check --workspace` triggers a full rebuild and catches `error[E0560]: struct 'Runtime' has no field named 'secret_guardian'`.

    **Root cause:** The subagent adds a `use aigon_secret_guardian::SecretGuardian;` import AND an initialization expression in the constructor, but the struct definition itself (the `pub struct Runtime { ... }` block, often hundreds of lines long) is not inspected. The import compiles, the init expression is syntactically valid, but the field doesn't exist.

    **Detection pattern after ANY parallel subagent batch:**
    ```
    # Step 1: fast individual checks (may pass on stale cache)
    cargo check -p aigon-runtime 2>&1  # may PASS — cached artifact
    # Step 2: force full workspace rebuild
    cargo check --workspace 2>&1       # catches struct-field mismatch
    ```
    Do NOT stop at Step 1. `cargo check --workspace` is the only signal for this class of error because it forces rebuild of all transitive dependencies and re-checks the full integration surface.

    **Mitigation:** In every subagent goal that modifies a struct constructor, add: "Verify the struct definition has the field you are initializing." Better: dispatch struct-field-adding and constructor-modifying as a SINGLE subagent task per file. Never split struct definition + constructor across two subagents (covered by pitfall 12).

    **Fix:** Remove the orphaned field init. Also check whether the corresponding `use` import was added; if the type is never used elsewhere, remove it too.

32. **Subagent creates benchmark files referencing non-existent types/methods** — A subagent dispatched to generate benchmark files may reference methods and types that don't exist in the current API surface. The subagent's knowledge of the trait/struct API is stale — it uses method signatures from an older version. All bench files need complete rewrites.

    **Root cause:** Subagents dispatched on a codebase with rapidly-evolving API surfaces (especially when traits like `Observable` and structs like `HealthStatus` have recently been refactored) retain a stale mental model of the API. They correctly import the crate but then call methods that don't exist or construct structs with wrong field names. `cargo check -p <crate>` (lib) passes, but `cargo check --benches -p <crate>` fails with 30+ `error[E0425]` errors.

    **Detection:**
    ```
    cargo check --benches 2>&1 | grep -c 'error\['
    ```

    **Fix workflow:**
    1. Read the actual trait/struct definitions from the source crate
    2. Rewrite bench files against the REAL API surface — only methods and types that actually exist
    3. Verify: `cargo check --benches 2>&1` must exit 0
    4. Verify lib also still compiles: `cargo check --workspace`

    **Prevention:** Before dispatching benchmark subagents, read the current API surface files and embed the EXACT method signatures, struct definitions, and field names in the subagent's task context. If the trait has recently been refactored, include a "KNOWN GOOD API" block with the canonical signatures.

33. **Verification gap: individual crate check passes but bench check fails, or lib passes but workspace fails** — After merging parallel subagent work, the verification must be multi-layered:

    ```
    # Layer 1: individual crate checks (fast, first pass)
    cargo check -p aigon-v3-core -p aigon-kernel -p aigon-runtime
    # Layer 2: full workspace (catches cross-crate struct field mismatch, orphaned imports)
    cargo check --workspace
    # Layer 3: benchmarks (catches stale API refs in bench files)
    cargo check --benches
    # Layer 4: tests
    cargo test -p aigon-v3-core -p aigon-kernel --lib -p aigon-runtime --lib
    ```
    Each layer catches a different class of error that the previous layer misses. Layer 2 catches struct field contamination; Layer 3 catches stale bench API references. **Do not short-circuit — run all four layers sequentially before declaring a subagent batch merged.**

34. **Subagent deletes files still imported by active code paths (detection + restoration).** — When dispatching subagents to clean dead code (especially in frontend monorepos with deep import graphs), a subagent may delete files it believes are dead but are actually imported by active components in sibling directories it never read. The subagent only checked the directory it was told to clean, not sibling page directories.

    **Detection:** After the subagent returns, `npm run build` fails with module-not-found errors for the deleted files. Use `git status --short | grep '^D'` to identify deleted files, then search for active importers:
    ```bash
    for f in $(git diff --name-only --diff-filter=D HEAD); do
      basename=$(basename "$f" .tsx)
      basename=$(basename "$basename" .ts)
      grep -rl "from.*$basename" src/ --include='*.tsx' --include='*.ts' | grep -v "$(dirname "$f")" || true
    done
    ```

    **Restoration workflow:**
    ```bash
    git checkout HEAD -- <deleted-file-path>
    # or restore ALL deleted files
    for f in $(git diff --name-only --diff-filter=D HEAD); do
      git checkout HEAD -- "$f"
    done
    ```

    **Real example (2026-07-27):** A frontend cleanup subagent deleted `loading-spinner.tsx`, `status-badge.tsx`, and `section-card.tsx` (in the `components/` directory it was cleaning). But `dashboard.tsx` still imported all three. Fix: `git checkout HEAD --` to restore, then re-verify build.

    **Prevention:** In any dead-code cleanup subagent goal, add: "Before deleting any file, search the ENTIRE project for imports of its exports. Do NOT delete files imported outside the directory being cleaned." Better: have the subagent produce a DRY-RUN list of proposed deletions, then verify imports yourself before executing.

35. **Context construction specificity for code-change subagents.** When dispatching subagents to make code changes (rather than analysis or research), the `context` field must carry:

    - **EXACT file paths** (not directory names or globs)
    - **CURRENT file snippet** — paste the relevant lines the subagent needs to change
    - **EXACT change specification** — what to change and to what
    - **Verification command** to run after changes

    Bad context:
    ```
    Fix the CLI memory handler. It uses process.exit(1).
    ```

    Good context (from 2026-07-27 session):
    ```
    In cli/src/memory/cli.ts:
    - Line 17: `process.exit(1);` under `if (!query)` in search case
    - Line 35: `process.exit(1);` under `if (!text)` in ingest case
    - Line 50: `process.exit(1);` under `if (!session)` in sync case
    Replace every occurrence with `throw new Error("...")`.
    After fixing, run `npx tsc --noEmit` to verify.
    ```

    The `goal` field is the concise instruction; `context` carries supporting detail. Neither alone is sufficient — redundantly pinning scope in both fields prevents scope drift (see pitfall 19).

36. **Subagent runs full release build just to grep for errors — wastes 3 minutes.** When a subagent runs `cargo build --release -p <crate> | grep "^error"` after a compile error, it triggers a full optimized release build (LLVM passes, LTO, codegen) just to pipe through grep. The release build takes 185s vs the debug build's ~1s. The error is already visible from the first `cargo build` output (which ran before the pipe). The subagent then runs this same pipeline 3-4 more times with slightly different grep patterns (`grep -i "^error"`, `grep -E "error[|Error:"`, `grep -n "error["`), each time waiting for the full release build.

    **Symptom in subagent transcript:** A task that just rebuilds + greps takes 185s+ with no tool calls between. The subagent's first `cargo build` output already shows the error, but subsequent terminal entries are identical `cargo build --release | grep ...` commands.

    **Parent-side mitigation:** While the subagent runs its first redundant release build, tail its transcript and apply the fix (see pattern E above). When the subagent finally retries without the pipe, the build succeeds instantly.

    **Prevention:** In build-verification subagent goals, explicitly request `cargo check` not `cargo build --release`. Use release builds only for final binary delivery, not error diagnosis.

When the user says "zapisz skill i wykonaj maksymalnie równolegle" (save the skill AND execute it in parallel), the pattern is:

1. **Create the skill** from the session's knowledge artifact (audit, methodology, investigation findings)
2. **Derive independent workstreams** from the skill's recommendations or findings
3. **Dispatch ALL workstreams immediately** — don't wait for skill creation to be confirmed
4. **Each subagent gets full file-level context** (exact file paths, patterns, existing code)

### Workstream Decomposition Heuristic

| Source | Typical Workstreams |
|---|---|
| Audit report with missing implementation gaps | API endpoints, shutdown wiring, feature enablement, dead code cleanup |
| Code review with defect categories | Fixes per subsystem or per defect class |
| Roadmap with sequential phases | Independent work within each phase; serialize cross-phase deps |

### Real example (2026-07-24)

After completing a 27-point self-awareness audit, 3 subagents dispatched in parallel:

| Workstream | Files | Goal |
|---|---|---|
| API self-description endpoints | `api.rs` (5844 lines) | Add 6 `/api/v1/self/*` endpoints |
| Shutdown wiring | `main.rs` + `api.rs` | Wire 5 tokio::spawn to shutdown channel |
| Feature enablement + dead code | `Cargo.toml` + `lib.rs` | Enable planner/infrastructure, cleanup dead_code |

Key: no two subagents wrote to the same file, each got a precise context snippet showing the existing pattern.

In some sessions, you need to understand the codebase (task 3) while simultaneously implementing something else (task 4). Dispatch analysis subagents for task 3 while you directly implement task 4 in the parent — don't serialize them.

### When to use

- Two or more tasks are truly independent (different subsystems, no file overlap)
- Task A requires codebase analysis (read-only grep, architecture mapping, dependency tracing)
- Task B is a contained implementation with known requirements
- User said "maksymalnie rownolegle" / "wszystko rob"

### How: dispatch + implement simultaneously

```
1. Identify the analysis task (A) and the implementation task (B)
2. Dispatch 1-3 analysis subagents (delegate_task) for task A
   └─ Each subagent gets a focused goal: "Analyze X and produce mapping Y"
   └─ Subagents are read-only — no file writes
3. IMMEDIATELY start implementing task B in the parent
   └─ Don't wait for subagent results
   └─ Read files, write patches, run cargo check
4. When subagents return, use their analysis to plan + implement task A
```

### Example from session 2026-07-21

```
Goal: task 3 (remove global RwLock<Runtime>) + task 4 (MCP bridge load balancing)
Analysis subagents dispatched:
  - Subagent A: analyze all API endpoints → field mapping
  - Subagent B: analyze tick function → what it needs exclusive access to
  - Subagent C: analyze MCP bridge → load balancing design
Parent simultaneously implemented:
  - mesh_client.rs (315 lines) with full load balancing
  - Integrated into main.rs (AppState, proxy_get/proxy_post, health_handler)
  - cargo check: PASS
Result: 1 hour saved by not serializing analysis → implementation
```

### Pitfalls

1. **Don't write to files the analysis subagents are reading.** The subagents are read-only (they review code), but the parent might be writing. If both touch the same file, the subagent's analysis may be stale — but that's usually fine since the parent writes new code, not modifies analyzed code.
2. **Analysis subagents may return mid-implementation.** Their results enter the conversation as new messages. If they return while the parent is in the middle of a multi-patch sequence, the parent can either: (a) acknowledge but defer processing, (b) use the result immediately if it changes the implementation plan. Usually (a) is safe — the analysis informs the next task, not the current one.
3. **Analysis subagents produce summaries, not raw data.** Subagent A's "endpoint → field mapping" is a self-report. Verify it by spot-checking the actual code before building the refactor plan on it.

## Related Skills

- `ai-agent-token-storm-mitigation` — covers runaway token consumption in local AI coding agents (Qwen CLI, Claude Code, Codex). This skill overlaps on **resource exhaustion** but differs: it focuses on interactive agent usage, while `subagent-orchestration` focuses on Hermes `delegate_task` batching and verification.
- `omega-nothing-can-hide-tribunal` — class-level blueprint for a global completeness proof. The Parallel Deep Audit pattern above is the execution mechanism; this skill defines WHAT to audit (15 tribunals, each with methodology, scope, and expected output format).
- `production-readiness-audit` — after subagents finish, run the phases in this skill to verify the resulting stack end-to-end.
- `rust-code-audit` — use for verifying Rust subagent outputs (compilation, tests, dead code) before declaring refactor done.

## Build-and-Merge DAG for Demo / Presentation Generation

A specific pattern for generating a set of independent demo artifacts and merging them into a unified presentation (e.g., for a product demo, pitch deck, or live showcase).

### When to use

- You need to create several independent visual/graphical demos for a presentation
- The demos don't share files (each is a standalone HTML/SVG/3D artifact)
- A final "merge" step composes them into a single unified experience

### Workflow

**Step 1: Read source materials** — Read the manifest, PRD, or any brief documents that define what the presentation needs to show. Decompose into N independent streams.

**Step 2: Dispatch N subagents in parallel** — Each subagent builds exactly one standalone artifact. Every artifact goes into the same output directory. Key rules:

- Every artifact must be a SELF-CONTAINED file (inline CSS+JS, CDN imports only). No cross-file dependencies between demos.
- Give each subagent the COMPLETE context it needs: the visual style (e.g., "Silicon Valley / Stripe dark theme"), the exact output path, any API endpoints to call, and tool-specific instructions.
- No two subagents write the same file.
- Each subagent verifies its artifact exists (check file size, validate XML/HTML structure).

**Step 3: Build the presentation framework in the parent** — While subagents run, build the HTML presentation deck. The deck should be a single self-contained HTML file with:

| Feature | Implementation |
|---|---|
| Slide navigation | Horizontal slide deck with `translateX` transforms, keyboard arrow keys + dot nav buttons |
| Visual theme | Dark gradient background, glassmorphism cards (`backdrop-filter: blur`), soft borders, particle animation canvas |
| Live telemetry | `fetch()` the runtime's `/api/v1/health` endpoint at load + every 30s, update IQ/uptime/kernel/metrics in real-time |
| Demo gallery | Cards grid showing all demo projects, each linking to the actual file served via a local HTTP server |
| Loading state | Full-screen loading overlay that hides after first successful data fetch |

**Step 4: Serve and screenshot** — Start a local HTTP server (`python3 -m http.server <port>`) from the output directory. Navigate the browser to each demo artifact and take a vision screenshot to verify visual quality. Use the descriptions to confirm the expected design standard.

**Step 5: Merge** — Update the presentation deck's demo grid with:
- Clickable links (`<a href="http://localhost:<port>/demo-file.html" target="_blank">`)
- Color-coding per demo (each gets a unique accent color for its preview background)
- File path shown under the description for developer reference

### Real example — OPERATION OLYMPUS (2026-07-26)

- 6 subagents dispatched simultaneously building: Weather Dashboard (HTML), 3D Crown Chest (Three.js), Promo Video (HyperFrames), Sports Watch (Three.js), Potion Icon (SVG), Runtime Report (JSON+MD)
- All 6 artifacts landed in `<workspace>/products/testy/output/` within ~2 minutes
- Parent built the 7-slide presentation framework in parallel
- After subagents finished, browser screenshots confirmed each demo rendered correctly
- Final deck: 7 slides, live runtime telemetry, 5 demo cards with live links, keyboard navigation, at 28KB

### Parallel Fix Variant — "napraw rownolegle"

When the user says **"napraw rownolegle"** (fix in parallel), existing artifacts are broken and need fixing rather than building from scratch. The pattern is similar to Build-and-Merge but with diagnosis-first:

**Workflow:**

**Step 1: Quick audit** — Inventory all deliverables. Identify which are broken and how (file missing, JS errors, rendering issue, wrong content).

**Step 2: Dispatch one subagent per broken item** — Each subagent gets:
- The EXACT file(s) to fix (paths + current content)
- The SPECIFIC symptom (e.g., "2 empty JS exceptions on load", "vision model sees helmet instead of watch")
- A verification step: "After fixing, confirm file exists with reasonable size AND open in browser to check for errors"

**Step 3: Parallel execution** — All fix subagents run simultaneously. No two subagents write to the same file.

**Step 4: Parent verifies results** — After ALL subagents return, run a consolidated check of every deliverable.

**Real example (2026-07-26):**
- 3 fix subagents dispatched in parallel: chest 3D (2 empty JS exceptions), sports watch (vision model hallucination), weather + potion (final verification)
- All 3 completed within ~90 seconds
- Parent simultaneously prepared final integration checks
- Result: 17/17 deliverables verified working

### Browser Verification for Static HTML/JS Artifacts

When deliverables are standalone HTML/JS files without npm test or build infrastructure, verification must use browser tools directly:

1. **File existence and size** — `[ -f "$path" ] && wc -c < "$path"`
2. **Syntax check** — For ES modules: parse with `node --input-type=module`. For HTML: check `<!DOCTYPE html>` presence.
3. **Browser load** — `browser_navigate(url)` → confirm title and element_count
4. **Console check** — `browser_console()` → confirm 0 JS errors, 0 critical warnings
5. **Visual check** — `browser_vision()` → confirm expected rendering. **Pitfall:** vision models hallucinate on dark WebGL metallic renders — don't rely on vision alone for dark 3D scenes; also verify by reading source code and checking console.
6. **Content verification** — Read source with `search_files`/`read_file`, accounting for HTML entities (`&middot;`, `&oacute;`) that cause regex checks to miss matches.
7. **Import map limitation** — Submodules do NOT inherit import maps. If a submodule does `import * as THREE from 'three'`, it must use a relative path (`./vendor/three.module.js`) or the import map must remap the bare specifier at the submodule level.

### Pitfalls

1. **Don't embed base64 screenshots in the deck** — They bloat the file by megabytes. Use icon placeholders or gradient previews instead; the actual demos open in new tabs.
2. **Don't use `file://` protocol** — Three.js WebGL and HyperFrames need a local HTTP server. Always start `python3 -m http.server <port>` and serve everything from `http://localhost:<port>/`.
3. **Don't let subagents write to the same file** — Each subagent gets its own output path. The only shared file is the presentation deck, which is owned by the parent/merge step.
4. **When a needed tool isn't available (Blender missing, etc.)** — Document the fallback choice in the subagent context (e.g., "Blender not installed — use Three.js procedural geometry instead"). Don't let the subagent waste time trying to install tools.
5. **HyperFrames CLI quirk** — The installed binary is at `bin/hyperframes.mjs` and may refuse direct execution. Use `node /path/to/node_modules/hyperframes/bin/hyperframes.mjs <command>` instead. npm scripts (dev/check/render) work via the project's `package.json`.
6. **img2threejs forge is AI-agent-driven** — The forge (intake → spec → build → review) requires iterative vision analysis; it's not a one-shot CLI. For a single model, writing procedural Three.js geometry is faster than running the forge pipeline.
7. **CORS blocks runtime data fetch from presentation deck** — When the presentation deck is served on `http://localhost:8766` but the runtime API is on `http://localhost:7000`, `fetch('http://localhost:7000/api/v1/health')` fails with a CORS error even though both are localhost. The browser considers different ports different origins. **Fix:** Embed the runtime report data as a JS constant in the presentation HTML, and modify `fetchRuntimeData()` to catch the TypeError and fall back to the embedded data. Structure the embedded data to match the live API shape (the parent uses `data.body || data.runtime || data` to resolve the canonical path):

> **MANDATORY:** This entire verification pipeline (steps 1-6) is required before declaring a build-and-merge batch complete. Subagent "completed" + parent file-existence check is NOT sufficient — every asset can be present on disk but unreachable from the HTML's relative path (e.g., if `assets/` was created at the wrong directory level during restructure). **Final gate:** `curl -s -o /dev/null -w "%{http_code}" http://localhost:<port>/output/<project>/assets/every-referenced-file.svg` — each must return 200. Run this for EVERY deliverable in a parallel batch.

For any deliverable where subagent-produced HTML references external files (images, SVGs, CSS, fonts), extract the asset paths from the HTML and curl each one through the HTTP server. A single 404 means the deliverable IS NOT DONE.
   ```js
   const EMBEDDED_RUNTIME = {
     iq_test_battery: { full_scale_iq: 140.15, logical_reasoning: 0.9999, ... },
     kernel_health: [
       { kernel_name: "nano", status: "Healthy", sla_compliance_pct: 100, ... },
       // ... all 14 kernels
     ],
     config_fingerprint: { version: "v0.2.0-378", kernel_count: 14, ... },
     mesh: { peer_count: 9, healthy_peers: 9, has_quorum: true, nodes: [] }
   };
   async function fetchRuntimeData() {
     try {
       const r = await fetch('http://localhost:7000/api/v1/health', { mode: 'cors' });
       if (r.ok) return await r.json();
     } catch (e) { /* fall through */ }
     return { body: EMBEDDED_RUNTIME }; // wrap in 'body' to match health endpoint shape
   }
   ```
   The fallback fires silently if the live endpoint is unreachable. The presentation still shows real IQ, kernel health, and mesh data — just from the captured snapshot rather than live.
8. **SVG `<use href>` cross-file reference fails from localhost HTTP** — A preview HTML that references an SVG file via `<use href="./potion-icon.svg#svgView"/>` may render an empty page when served from `http://localhost:<port>/`. This fails because browsers restrict cross-file SVG `<use>` references even from the same origin when served via HTTP (the SVG and HTML must share the exact same document context). The `#svgView` fragment identifier alone doesn't fix it. **Fix:** Inline the full SVG content directly into the preview HTML. Remove the `<use>` element and embed the `<svg>` tag with its viewBox, defs, filters, and all geometry. The preview becomes a fully self-contained HTML file with no external dependencies. Works from both `file://` and `http://localhost`.
9. **HyperFrames binary may lack execute permission** — After `npm install`, the `hyperframes` binary at `/home/operator/.npm-global/bin/hyperframes` may have no execute permission (`chmod -x`). Running `npx hyperframes@0.7.71 check` then fails with `Permission denied`. **Fix:** `chmod +x /home/operator/.npm-global/bin/hyperframes` before running any hyperframes command. Run this as a setup step in the parent before dispatching HyperFrames subagents.

10. **HyperFrames `init` creates nested subdirectory** — When a subagent runs `npx hyperframes init <name>` inside a pre-created output directory (e.g., `output/03-my-project/`), the project lands in `output/03-my-project/my-project/` instead of directly in `output/03-my-project/`. After the subagent returns, scan for this nesting with `find <output_dir> -name index.html -o -name package.json` and restructure by moving files from the nested subdirectory up. **After restructuring, assets (`assets/*`) may still be missing** — the subagent wrote HTML references like `assets/logo.svg` and `assets/opinia1.webp` to the nested directory's index.html, but during the parent's `cp -r` restructure the `assets/` directory silently fails to copy if no `mkdir -p assets` was run first. **Verification after restructuring:** `curl -s -o /dev/null -w "%{http_code}" http://localhost:<port>/output/<project>/assets/logo.svg` — must return 200, not 404. If missing, re-download or regenerate all referenced assets. See `references/hyperframes-init-nested-directory.md` for the full fix workflow.


## Multi-Gap Parallel Implementation (Audit → Decompose → Dispatch → Merge)

A specific pattern for fixing 3-6+ independent gaps in a single codebase in one parallel batch, driven by a prior audit. Used in the aigon-code CLI session (2026-07-27) to implement 6 gaps simultaneously.

### When to use

- You've completed an audit of a codebase and identified 3+ independent gaps/features
- Each gap maps to different files (no file overlap between subagents)
- The gaps require full implementations, not just targeted edits
- User says "war mode", "maksymalnie równolegle", or "zaimplementuj wszystkie luki"
- The codebase is TypeScript/Node.js (fast tsc check) or Rust (fast cargo check per crate)
- Each gap can be verified independently before merge

### When NOT to use

- Gaps share files (serialize those, parallelize the rest)
- Gaps require sequential dependencies (gap B builds on gap A's code)
- The codebase has a single monolithic build with no per-file/crate isolation
- Subagent model lacks tool access (see pitfall 18)

### Workflow

**Step 0 — Audit (single pass by parent):**
Read every relevant source file. Understand existing patterns, imports, types, middleware interfaces. Identify gaps by comparing what EXISTS vs what SHOULD exist. Do NOT delegate the audit — the parent must build the full mental model.

**Step 1 — Decompose into per-gap tasks:**
Each gap must:
- Be a COMPLETE feature implementation (not a partial edit)
- Touch DIFFERENT files from all other gaps
- Have a self-contained goal executable with only file-level context
- Include exact file paths, existing patterns (code snippets), and the full interface contract

**Step 2 — Read ALL files before dispatch:**
Read every file ANY subagent might need in ONE batch. Dispatch only after all reads complete.

**Step 3 — Dispatch 1 subagent per gap (one batch call):**
```
delegate_task({
  tasks: [
    { goal: "Implement gap A...", context: "Files, patterns, interface contract..." },
    { goal: "Implement gap B...", context: "..." },
    // up to max_concurrent_children
  ]
})
```

Each subagent's `goal` must contain: exact feature to implement, exact files to modify/create, verification command to run after (`npx tsc --noEmit`, `cargo check -p <crate>`).

Each subagent's `context` must carry: current file snippets, exact import paths, interface types, method signatures to match.

**Step 4 — Parent works on backfill while subagents run:**
Independent tasks only (integration tests, docs, build pipeline). Do NOT implement gaps the subagents own.

**Step 5 — Merge + build-verify:**
After ALL subagents return:
```bash
cd <project> && npx tsc --noEmit     # TypeScript
cd <project> && npm run test          # tests (if any)
cd <project> && npm run build         # bundle
```

**Step 5b — Verify CLI binary actually executes:**
After `npm run build` succeeds, verify the CLI binary works end-to-end — not just that dist files exist. The build can succeed while the CLI itself is broken:
```bash
which <cli-name>                      # resolve symlink/wrapper path
<cli-name> --version                  # verify execution (catches stale wrapper paths)
<cli-name> --help 2>&1 | head -5      # quick smoke test of the bundle
```

Build can succeed while the CLI is broken if:
- The wrapper symlink points to a stale dist path (repo restructure, path migration)
- The entry point was moved/renamed in source but the build config wasn't updated
- `package.json` `bin` field points to a non-existent or renamed entry file
- **`~/.local/bin/` standalone bash wrapper** has a hardcoded `REAL_BIN` path that's stale (e.g., after repo restructure from `products/aigon-code/` → `products/prod/aigon-code/`). Unlike npm `bin` symlinks, bash wrappers are NOT auto-generated by the build — they must be patched manually.

Run this BEFORE declaring the merge complete. A failed `--version` after successful build means the binary path or entry point is wrong — fix the wrapper script, `package.json` `bin` field, or the build config.

**Wrapper fix workflow when `--version` fails but dist exists:**
```bash
which <cli-name>                          # find the wrapper (~/.local/bin/...)
cat $(which <cli-name>) | grep 'REAL_BIN'  # find the stale hardcoded path
ls -la <expected-dist-path>               # confirm dist actually exists
# Fix the wrapper path
patch ~/.local/bin/<cli-name> 'old-stale-path' 'new-correct-path'
<cli-name> --version                       # verify fix
```

If a check fails: fix the cause directly in the parent (do NOT re-dispatch). Subagent-introduced issues (unused imports, shadowing, missing barrel exports) are fast parent fixes.

### Real example — aigon-code CLI (2026-07-27)

| # | Gap | Key Files | Subagent |
|---|-----|-----------|----------|
| 1 | Metalearning feedback loop | `capabilities.ts`, `memory/feedback.ts` | `deleg_b0f32279` |
| 2 | Proxy pipeline (wire middleware) | `ProxyLayer.ts` | `deleg_59ed6b66` |
| 3 | Hallucination detection | `HallucinationDetector.ts` | `deleg_2ae3bd6b` |
| 4 | Skills system (~/.aigon/skills/) | `skills/` (new), `capabilities.ts` | `deleg_5a0d8475` |
| 5 | Auto-compaction | `runtime/context.ts`, `Agent.ts` | `deleg_b65a6271` |
| 6 | Self-improvement / Evolution | `agent/evolution.ts`, `capabilities.ts` | `deleg_20fda34a` |

Total wall-clock: ~8 min (6 subagents ~5 min, merge+verify ~3 min). Each subagent returned with verified tsc output.

### Incremental gap addition (staggered dispatch)

When a new gap is discovered mid-dispatch (user says "no i jeszcze X" or "jeszcze jedno zadanie"):

1. **Dispatch a new subagent immediately** — do NOT wait for the running batch to finish
2. **Give the new subagent FULL context** of what other subagents are doing (their goals, file targets, interface contracts), plus the original audit context
3. **The new subagent must avoid file conflicts** with already-running subagents. If its files overlap, serialize that gap instead.
4. **Parent proceeds with backfill work** while both the first batch and the late addition run in parallel
5. **Merge ALL results together** — the late subagent's output participates in the same post-merge build+verify as the original batch

This pattern worked in the aigon-code CLI session (2026-07-27): 5 subagents dispatched at T+0, 6th (self-improvement) dispatched at T+4min with cross-context of all 5 existing tasks. All 6 completed within ~8min wall-clock from T+0.

When adding a late subagent, the key risk is file conflict with already-running subagents. Mitigate by:
- Reading the late subagent's target files to confirm no overlap with already-dispatched tasks
- If overlap exists: serialize the late task to run AFTER the conflicting subagent returns
- If no overlap: dispatch immediately — the late subagent runs in the same `max_concurrent_children` pool

### Heterogeneous Stack Variant (Rust + TypeScript + Verification)

When the parallel gaps span **different programming language stacks**, not just different features within one stack, the pattern changes:

| Dimension | Same-stack (Multi-Gap) | Heterogeneous |
|-----------|----------------------|---------------|
| Verification per subagent | One command (`tsc --noEmit`) | Per-stack (`cargo check` for Rust, `tsc` for TS, `curl` for endpoints) |
| Parent-side probes | Not needed (same toolchain) | **Essential** — probes runtime endpoints independently |
| Context per subagent | Same import/types domain | Different types, different APIs |
| Merge verification | Single build | N separate builds + integration test |

**Workflow additions for heterogeneous:**

1. **Dispatch mixed-stack subagents in one `delegate_task` call** — Rust runtime change, TypeScript CLI change, Rust MCP verification all in one batch. Each subagent gets its own verification command and stack-specific toolchain instructions.

2. **Parent independently probes live endpoints immediately after dispatch** — curl the runtime endpoints the subagents are supposed to change. This establishes a pre-change baseline and catches fabrication early.

3. **Read live transcripts across stacks** — Monitor task-0.log (Rust), task-1.log (TypeScript), task-2.log (MCP/verification) simultaneously. Each has different progress patterns (Rust = build times, TypeScript = file reads+writes).

4. **Verify each stack independently after merge** — Run ALL verification commands yourself, not just the subagents' reports:
   ```bash
   # Rust
   cd <workspace>/runtime && cargo check -p aigon-runtime && cargo test -p aigon-runtime
   # TypeScript
   cd <workspace>/products/prod/aigon-code && npx tsc --noEmit && npm run test
   # Runtime endpoints (30-60s timeout for LLM-powered)
   for ep in analyze generate review fix; do
     timeout 60 curl -s -w "\nHTTP:%{http_code}" -X POST http://localhost:7000/api/v1/code/$ep -H 'Content-Type: application/json' -d '{"code":"fn main(){}"}'
   done
   ```

5. **Report consolidated across stacks** — One table showing per-stream status (Rust: test count, TypeScript: test count, Endpoints: HTTP codes), with the verification method used for each.

See `references/heterogeneous-multi-stack-parallel-fix-2026-07-27.md` for the full session transcript including the specific finding about code_fix returning "000" (curl connects but empty response body on LLM-powered endpoints).

### Key success factors

1. **No file section overlap** — Each subagent writes to different files. If two gaps must touch the same file, ensure they modify DIFFERENT sections (different functions, different registrations, different blocks). In the aigon-code session (2026-07-27), 3 subagents safely modified overlapping files (`Agent.ts`, `capabilities.ts`, `model.ts`) because each added NEW content (new import, new function, new capability registration) without editing existing lines. If two subagents must edit the SAME section (same match arm block, same function body), serialize those tasks and parallelize the rest.
2. **Exact context** — Each subagent receives COMPLETE current file content + interface types from files it must MATCH but NOT modify.
3. **Per-subagent verification** — Each runs `npx tsc --noEmit` after changes and reports the result.
4. **Parent owns integration** — Post-merge full build+test catches cross-gap issues no individual subagent could.

## Parallel Deep Audit — N Subagents, One Codebase, One Consolidated Report

A specific pattern for running **N completely parallel static-analysis audits** on the same codebase, where each subagent examines a different dimension (structs, traits, functions, registry, wiring, reachability, etc.) and the parent consolidates all results into one master report.

### When to use

- You need a **global completeness proof** (Ω PROOF) of a codebase — not just a local audit
- The codebase can be analyzed from N independent dimensions (structs, traits, functions, registry, bus, API, call graph, wiring, etc.)
- Each dimension has ZERO file writes — all subagents are READ-ONLY analysts
- User says "wszystkie maksymalnie rownolegle" — dispatch ALL subagents, not a subset

### Workflow

**Step 1 — Create the methodology skill first (or already have it):**

Define the tribunal methodology as a skill. Each tribunal specifies what it audits, how it audits (tools, patterns, checks), and what it outputs. Save this BEFORE dispatching.

**Step 2 — Read the codebase scope (single parent pass):**

Read: codebase root + workspace structure, key file locations (lib.rs, api.rs), any prior audit reports to cross-reference.

**Step 3 — Dispatch ALL N tribunals in ONE `delegate_task` call:**

Each tribunal task context must include: exact search paths, patterns, output format, verification method. Each goal must include: what to investigate, what tools, how to structure output, and "Respond in Polish" when the user speaks Polish.

**Step 4 — Monitor live transcripts while subagents run (optional):**

```bash
ls /home/operator/.hermes/cache/delegation/live/<delegation_id>/
tail -50 /home/operator/.hermes/cache/delegation/live/<delegation_id>/task-3.log
```

**Step 5 — When ALL return, consolidate into one master report:**

For each tribunal extract: key metrics (counts, percentages, PASS/FAIL), findings (file+line, severity), architecture observations. Build with Executive Summary (PASS/FAIL dashboard), Per-Tribunal Results, Key Findings (P0-P4), Consolidated verdict.

### Key differences from other parallel patterns

| Pattern | Read/Write | Files touched | Consolidation |
|---------|-----------|---------------|---------------|
| Multi-Gap Implementation | Write | Each → different files | Build test |
| Build-and-Merge Demo | Write | Each → unique artifact | Presentation deck |
| **Parallel Deep Audit** | **Read-only** | **0 files written** | **Master report** |

Because subagents write nothing, ZERO risk of file conflict.

### Verification

1. Every tribunal returned a completed summary with metrics and findings
2. The master report references specific numbers from each tribunal
3. Tribunal with `api_calls=0` or narrative without tools → re-dispatch or do manually

### Pitfalls

1. **Subagent summary is TRUNCATED when >2,275 chars.** Read the saved file for complete findings.
2. **Delegation model mismatch.** If parent model differs from delegation pin, ALL subagents fail. Verify: `grep -A3 'delegation' ~/.hermes/config.yaml`
3. **Consolidated summary from delegate_task is head+tail truncated.** Full output at `/home/operator/.hermes/cache/delegation/live/<delegation_id>/task-<N>.log`
4. **Answer with concrete metrics** when user asks "i jak?" — "14/15 done, Tribunal 4 still running".

## Parallel Web Data Collection — N Subagents, N Web Pages, One Consolidated Dataset

A specific pattern for dispatching subagents to extract **structured data from N independent web pages** (e.g. YouTube channel IDs, API endpoint metadata, product listings) using browser tools, then consolidating into a single dataset for database seeding.

### When to use

- You need to extract a specific field (e.g. channel ID, page title, metadata) from N different web pages
- Each page is independent (no shared state needed between page visits)
- The extraction is mechanical — navigate to URL → run a JS console expression → capture result
- The consolidated data goes into a database (PostgreSQL, SQLite) or CSV file
- Curl/wget is blocked or returns partial content (YouTube pages, Cloudflare-protected sites)

### Workflow

**Step 1 — Define the extraction target:** Identify the exact JS expression or HTML pattern to extract from each page. Test it manually on one page first. For YouTube channel IDs:
```javascript
// browser_console expression
document.documentElement.innerHTML.match(/"browseId":"(UC[a-zA-Z0-9_-]{22})"/)?.[1]
```

**Step 2 — Split pages across N subagents:** Group the pages so each subagent visits a disjoint set. Every subagent gets the same extraction target but different pages. Max N per batch = `max_concurrent_children` (commonly 3).

**Step 3 — Dispatch one subagent per page group:**
```javascript
delegate_task({
  tasks: [
    { goal: "Visit pages A, B, C and extract channel IDs using browser_console", context: "Full context with exact JS expression and page URLs" },
    { goal: "Visit pages D, E, F and extract channel IDs", context: "..." },
  ]
})
```

Each subagent's `goal` must include:
- Exact browser tool commands to use (browser_navigate → browser_console)
- The EXACT JS expression for extraction
- Which pages (handles/URLs) to visit
- How to report results ("Return a mapping of handle → channel_id")

**Step 4 — Consolidate in parent:** After ALL subagents return, merge the results into a single mapping. Handle duplicates (same channel visited by two subagents) by keeping the first result.

**Step 5 — Bulk-insert into database:**
```bash
# Build SQL from consolidated mapping
docker exec -i <container> psql -U user -d dbname << 'SQL'
INSERT INTO youtube_channels (channel_id, name, enabled)
VALUES
('UC...', 'Channel Name', true),
('UC...', 'Channel Name', true)
ON CONFLICT (channel_id) DO NOTHING;
SQL
```

### Pitfalls

1. **Browser rate limits:** YouTube may throttle browser sessions after ~6-8 rapid page navigations. Space out visits with `sleep(2)` gaps, or dispatch fewer pages per subagent.
2. **YouTube handle case sensitivity:** Handles like `@MateuszChrobok` vs `@mateuszchrobok` differ. Always use the EXACT handle from the user's source data, not a sanitized/lowercased version — YouTube returns 404 for wrong casing.
3. **YouTube blocks headless curl but not browser.** Curl requests to YouTube channel pages return empty or partial content (Cloudflare bot detection). Always use browser tools (browser_navigate + browser_console) for YouTube data extraction.
4. **Subagent extraction is self-reported.** After subagents return, verify a random sample by visiting one page yourself and comparing the channel ID.
5. **`ON CONFLICT` requires a UNIQUE constraint.** Before bulk INSERT, verify the target table has a UNIQUE constraint or PRIMARY KEY on the dedup column. Without it, `INSERT ... ON CONFLICT (channel_id) DO NOTHING` fails with `ERROR: there is no unique or exclusion constraint matching the ON CONFLICT specification`.

### Real example — YouTube channel seed (2026-07-28)

- 33 YouTube channels needed channel IDs for database seeding
- 3 subagents dispatched, each visiting ~11 channels
- Each subagent: browser_navigate → browser_console with `browseId` regex → collected handle → ID mapping
- Total wall-clock: ~90s (3 subagents × ~11 channels each in ~60s + 30s consolidation)
- Parent monitored live transcripts while subagents ran
- After consolidation: 33 channel IDs collected, 33 INSERTs into PostgreSQL via `docker cp` + `docker exec -f`

## Reference Files

- `references/subagent-credit-exhaustion-2026-07-12.md` — real transcript from an AIGON-X session where a subagent reported `completed` but produced no backend refactor because `deepseek/deepseek-v4-flash` ran out of Nous credits.
- `references/subagent-syntax-defect-checklist-2026-07-13.md` — checklist of syntax/lint defects left by a successfully-completed subagent batch, and the strict-lint verification that catches them.
- `references/concurrent-editor-corruption-maips-bridge-2026-07-15.md` — transcript of three subagents concurrently editing the same Rust file, producing orphaned match arms and structural corruption despite all patches succeeding individually.
- `references/pillar-wave-orchestration-2026-07-16.md` — Wave-based 3-phase orchestration pattern used to complete 37 tasks across 6 pillars in 30 minutes.
- `references/claude-code-local-fabrication-2026-07-23.md` — Full transcript of a `.claude` model subagent that fabricated file modifications.
- `references/mass-parallel-crate-implementation-2026-07-23.md` — Pattern for dispatching 40+ subagents to implement 52 stub Rust crates across 2 batched `delegate_task` calls. Covers goal structure, crate categories, mock-execution risk, and post-dispatch verification.
- `references/self-awareness-roadmap-parallel-dispatch-2026-07-24.md` — Pattern: save a skill THEN immediately dispatch parallel execution of its recommendations. 3 subagents for API endpoints + shutdown wiring + feature enablement. Covers file boundary discipline, context construction, and simultaneous dispatch.
- `references/subagent-rust-brace-fix-pattern-2026-07-24.md` — Systematic repair of subagent-generated Rust code: async fn → Pin<Box<dyn Future>> conversion, brace/paren balancing with Python tracing, E0753 doc comment fix, mass-fix across 12+ files, and parallel dispatch strategy for ~22 type-level compilation errors.
- `references/audit-findings-parallel-fix-2026-07-25.md` — Audit report → decompose N bugs to N per-file subagents → subagent model failure → direct parallel fallback fix of 6+ files. Covers file-level decomposition boundary, Node 20 `RequestInit & { agent?: http.Agent }` fetch keepalive trick, and parallel direct-execution fallback.
- `references/express-saas-integration-fala2-2026-07-25.md` — Express SaaS FALA 2 integration pattern: Wave 0 (read all exports), Wave 1 (create new middleware/health files), Wave 2 (extend server.ts + handler.ts), Wave 3 (verify typecheck + test). Covers subagent defects found during integration (`***` placeholders, Stripe raw body ordering, hash-chain payload mismatch).
- `references/audit-fix-5stream-dispatch-2026-07-27.md` — 5-stream parallel dispatch from a single audit report. Covers: context construction with exact file lines, parent-side E2E test backfill during subagent execution, post-join verification cascade (build → test → diff → push), env-var-configurable E2E values for local+prod compatibility.
- `references/quality-gate-steamroller-2026-07-26.md` — Post-merge verification matrix: 6 phases (Syntax Gate, Browser Gate, Visual QA Gate, Runtime Gate, Amplification Pass, Verification Matrix) for ensuring every parallel-stream artifact is 10/10 before reporting done. "full audit" pattern: 100% task enforcement, maximum amplifiers, all quality gates.
- `references/heterogeneous-multi-stack-parallel-fix-2026-07-27.md` — Discrete single-batch dispatch of 3 subagents across Rust, TypeScript, and verification stacks. Covers: parent-side live endpoint probing during subagent execution, per-stack verification (cargo check + cargo test vs tsc + npm test vs curl), and the finding that LLM-powered endpoints need 30-60s curl max-time (code_fix returned "000" but route exists and accepts requests).
- `references/cli-agent-live-transcripts-2026-07-27.md` — CLI-level append-only JSONL transcripts + Ink TUI viewer via fs.watch
