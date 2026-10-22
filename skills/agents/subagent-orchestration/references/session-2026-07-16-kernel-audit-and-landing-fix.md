# Session 2026-07-16 — Kernel Audit, Landing Fix & Max-Parallelism Wave Orchestration

## Key Patterns Used

### 1. Wave-Based 3-Phase Orchestration
Dispatched 37 tasks across 6 pillars in ~30 minutes using the Wave pattern:
- **Wave 0 (21h est.)**: Prerequisites — all independent, all concurrent
- **Wave 1 (64h est.)**: Per-pillar tasks — 3 parallel groups
- **Wave 2 (61h est.)**: Dependent tasks — built on Wave 1 completions
- **Wave 3**: Integration validation + CANON update

Real-world result: 146h estimated → ~30min runtime on 28 workers with 3 concurrent subagents.

### 2. CANON vs Implementation Audit
Systematic methodology:
1. Read CANON.md sections I-IX in full
2. For each claim, grep for the actual Rust/TS function
3. Check if it's called in tick()/boot()/main flow
4. Check if it produces real data or stubs
5. Report discrepancy + evidence

Found 10 critical discrepancies in one pass.

### 3. All-Crates Audit
For each of 68 crate directories:
1. Check workspace Cargo.toml membership
2. Check lib.rs import
3. Check boot()/tick() callsites
4. Quality assessment (REAL/PARTIAL/STUB)

Found: aigon-engines not in workspace, 4/12 kernels unregistered, 6 crates unwired.

### 4. Landing Page API Integration Gotcha
The capabilities catalog API returns field names that differ from what the component expected:
- `id` values use single underscore (`agent_swarm`) NOT double underscore (`agent__swarm`)
- Domain comes from `tags[0]` NOT from `id.split('__')[0]`
- Always check the actual API response shape before building filters

## User Style Notes
- "maksymalnie rownolegle" = dispatch everything, don't serialize
- "nie pytaj" = don't ask questions mid-work, just do
- "natychmiast" = immediate execution, no planning phase
- "wszystko na raz" = parallel dispatch all pending tasks
- "kontynuowac" = resume interrupted work without recap
- Expects CONCRETE TOOL OUTPUT as proof, not descriptive summaries
- Polish language for context/explanation, English for code/terms

## Verification Pattern Used
After each subagent batch return:
1. Run `cargo check` in affected workspace
2. Run `npm run build` for frontend
3. Query DB/API for state verification
4. Check `git status` for artifacts
5. Report PASS/FAIL per task with evidence
