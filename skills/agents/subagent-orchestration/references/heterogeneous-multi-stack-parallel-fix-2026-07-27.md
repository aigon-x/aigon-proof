# Heterogeneous Multi-Stack Parallel Fix (2026-07-27)

## What

Dispatching subagents across **different programming languages/stacks** simultaneously (Rust runtime + TypeScript CLI + Rust MCP verification), while the parent independently verifies live endpoints via curl and monitors subagent progress via live transcripts.

## When

- You have fixes across Rust + TypeScript (or any multi-stack project structure) that are **file-independent** (no two subagents write the same file)
- Each stack has its own verification tool (`cargo check` for Rust, `tsc --noEmit` for TypeScript)
- The runtime API is live and can be probed independently while subagents claim to be working
- User said "wykonaj maksymalnie równolegle" or any variant of "maximum parallel"

## Workflow

### Step 1 — Decompose by stack + scope

Not just by feature — decompose by LANGUAGE and SUBSYSTEM boundaries:

| Stream | Stack | Scope | Verification |
|--------|-------|-------|-------------|
| Runtime code change | Rust | `api.rs` handle_chat epithet injection | `cargo check -p aigon-runtime`, `cargo test -p aigon-runtime` |
| CLI feature | TypeScript | `main.ts` + `Agent.ts` flags | `tsc --noEmit`, `npm test` |
| MCP verification | Rust/curl | `main.rs` endpoint mapping + live probes | `curl -w "%{http_code}"` per endpoint |

Rules:
- NO file overlap between streams — if two changes touch the same file, serialize those streams
- Each stream gets its OWN verification command, NOT a shared build step
- Subagents do NOT need to know about each other's work

### Step 2 — Dispatch with stack-specific context

Each subagent gets the COMPLETE current content of its target files AND the exact verification command to run:

```
Goal: "Add X to api.rs — inject epithets into handle_chat. After change, run cargo check -p aigon-runtime && cargo test -p aigon-runtime"
Context: Full api.rs relevant lines + EpithetEngine import path
```

Add "respond in Polish / odpowiedz po polsku" to context when the session language is Polish.

### Step 3 — Parent independently probes live endpoints

While ALL subagents run, the parent IMMEDIATELY starts independent verification:

```bash
# 1. Probe runtime health
curl -sf http://localhost:7000/health

# 2. Probe relevant endpoints (what subagents claim they'll change)
curl -s --max-time 60 -o /tmp/test.txt -w "%{http_code}" http://localhost:7000/api/v1/epithets

# 3. Check subagent live transcripts for early failure signals
for f in /home/sniegul/.hermes/cache/delegation/live/<delegation_id>/task-*.log; do
  echo "=== $(basename $f) ==="; tail -3 "$f"; echo
done
```

This catches:
- Endpoints that don't exist yet (baseline before subagents modify them)
- Subagents stuck on credit exhaustion or model errors (no new output for 60s+)
- Subagents running redundant release builds instead of fast checks

### Step 4 — Read live transcripts for signal, don't wait

Check the live transcript of each subagent periodically:

| Signal | Meaning | Action |
|--------|---------|--------|
| `tool -> terminal(curl ...)` | Subagent testing endpoints | Wait for result |
| `tool -> patch/write_file` | Subagent making changes | Note what file |
| `result` shows 200/0 errors | Subagent progressing | Continue waiting |
| `result` shows credit error | Subagent blocked | Fix in parent directly |
| No new `assistant|` lines for 60s+ | Subagent stuck or done | Read last lines to confirm |

### Step 5 — Verify each stack independently after merge

After ALL subagents return, do NOT trust their reports. Run ALL verification commands yourself:

```bash
# Rust — compile + test
cd <workspace>/runtime && cargo check -p aigon-runtime && cargo test -p aigon-runtime

# TypeScript — typecheck + test
cd <workspace>/products/prod/aigon-code && npx tsc --noEmit && npm run test

# Runtime endpoints — live probe with adequate timeout (30-60s for LLM-powered endpoints)
timeout 60 curl -s -w "\nHTTP:%{http_code}" -X POST http://localhost:7000/api/v1/code/analyze -H 'Content-Type: application/json' -d '{"code":"fn main(){}"}'
```

### Step 6 — Report consolidated result

Present one table showing all streams with per-stream status + the verification method:

```
### Stream A (Runtime — Rust) ✅
- cargo check: PASS
- cargo test: 23/23 PASS
- curl /api/v1/epithets: 25 epithets

### Stream B (CLI — TypeScript) ✅
- tsc --noEmit: 0 errors
- npm test: 110/110 PASS
- binary --version: OK

### Stream C (MCP — curl verify) ✅
- code_analyze: 200 (34s)
- code_generate: 200 (43s)
- ... (all 8 endpoints 200)
```

## Key Insights

1. **Heterogeneous dispatch reduces total wall-clock dramatically** — 3 independent streams run in ~3-5 min vs ~15 min serial (Rust build + test → TypeScript build + test → MCP verification)
2. **Parent-side curl probes catch subagent fabrication** — if a subagent claims to have modified runtime code but the endpoint still returns the same response, the probe catches it immediately
3. **Live transcript monitoring lets parent fix problems while subagents retry** — if a subagent hits a pre-existing build error, the parent can fix it in <5s instead of waiting 3-5 min for the subagent's redundancy loop
4. **Endpoints that need LLM inference require 30-60s curl max-time** — short timeouts (15s) produce false negatives. code_fix took 54s, code_generate 43s, project_info 35s.
5. **code_fix endpoint may return "000" with exit 0** — this means curl connected but the response body was empty (no temp file written). The runtime accepted the request but the LLM response was empty or the endpoint doesn't write output to the response body for certain tool names. Despite "000", the endpoint IS alive and accepting requests.
6. **Not all endpoints need to return 200 to be "working"** — endpoints that proxy to LLM inference may return 000 (empty body) or timeout depending on model availability. The endpoint ROUTE exists (not 404) even if the response is incomplete. Document which endpoints are LLM-powered vs fast (e.g., code_review returns in 0.5s — it may use a cached or simpler path).

## Pitfalls

- **Subagent timeouts on curl tests** — A subagent with 15s terminal timeout will fail on all LLM-powered endpoints. Set `--max-time 60` explicitly in goals.
- **Stale Rust binary in running container** — The running runtime container has the old binary even after `cargo check` passes on source. Full container rebuild needed for new code to take effect. Don't claim runtime changes are "live" until `docker restart` or rebuild.
- **Monorepo path drift** — After subdirectory restructuring (e.g., `products/aigon-code/` → `products/prod/aigon-code/`), file paths in context must match the CURRENT layout. Subagents with stale paths silently fail to find files.
