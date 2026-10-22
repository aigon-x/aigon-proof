# Multi-Gap Parallel Implementation — aigon-code CLI (2026-07-27)

## Context

Audyt aigon-code CLI w `<workspace>/products/prod/aigon-code/cli/src/` zidentyfikował 6 niezależnych luk:

1. **Metalearning** — tylko iniekcja previousFeedback, brak adaptacji strategii
2. **Proxy pipeline** — compress/amplify/injectDomain były no-op
3. **Hallucination detection** — stub zawsze zwracający `checked: false`
4. **Skills system** — brak skili w stylu Hermes
5. **Auto-compaction** — CLI wysyłał całą historię bez kompresji
6. **Self improvement** — brak analizy wzorców użycia, auto-tuningu

## Dispatch Strategy

Przed wysłaniem subagentów przeczytano 20+ plików źródłowych (~29k LOC) aby zbudować pełny obraz:

- `proxy/capabilities.ts` — 885 linii, 40+ capability, wzorzec middleware
- `proxy/ProxyLayer.ts` — 108 linii, do przepisania
- `proxy/HallucinationDetector.ts` — 70 linii, stub
- `proxy/transforms.ts` — 378 linii, już zaimplementowane transformacje ale nie podpięte
- `agent/Agent.ts` — 2037 linii, toolCallingLoop
- `agent/model.ts` — CapabilityId, ALL_CAPABILITY_IDS
- `memory/MemoryMesh.ts` — embedding, search, cloud ingest
- `memory/store.ts` — local chunk persistence
- `runtime/client.ts` — HTTP client, SSE streaming
- `runtime/types.ts` — ChatMessage type
- `components/MissionConsole.tsx` — 1539 linii, TUI
- `proxy/index.ts` — re-export
- `agent/decomposition.ts` — task decomposition

Każdy subagent otrzymał dokładny kontekst: ścieżki plików, istniejące snippet-y, interface types, wzorzec middleware.

## Per-Gap Context Construction

### Gap 1 — Metalearning (deleg_b0f32279)
- **Goal**: Rozszerzyć ai::metalearning o pętlę feedbackową, dodać postProcess, zapis metryk
- **Context**: Patterny capabilities.ts (linie 364-399), MemoryMesh, store.ts, embed.ts
- **Files**: capabilities.ts, memory/feedback.ts (new), memory/index.ts, MemoryMesh.ts
- **Verification**: npx tsc --noEmit

### Gap 2 — Proxy pipeline (deleg_59ed6b66)
- **Goal**: ProxyLayer.run() musi iterować przez middleware, używać transforms.ts
- **Context**: ProxyLayer.ts (108 linii), OPTION_TO_CAPABILITY mapowanie
- **Files**: ProxyLayer.ts tylko
- **Verification**: npx tsc --noEmit
- **Result**: ProxyLayer z use/remove/loadOptionMiddleware/run pipeline + error isolation

### Gap 3 — Hallucination detection (deleg_2ae3bd6b)
- **Goal**: Zastąpić stub realną implementacją z heurystykami + Vairify API
- **Context**: Istniejące typy HallucinationResult, HallucinationSignal, VairifyCheckResult
- **Files**: HallucinationDetector.ts
- **Verification**: npx tsc --noEmit, npm run test (110/110 passed)
- **Result**: 573 linii — detectHallucinations, quickScan, checkViaVairify, localVairifyCheck, KNOWN_VERSION_WHITELIST

### Gap 4 — Skills system (deleg_5a0d8475)
- **Goal**: Dodać ~/.aigon/skills/ z plikami markdown jako capability middleware
- **Context**: Wzór Hermes SKILL.md, frontmatter YAML, pattern rejestracji capability
- **Files**: skills/ (new dir z loader.ts, types.ts, index.ts), capabilities.ts, model.ts
- **Verification**: npx tsc --noEmit

### Gap 5 — Auto-compaction (deleg_b65a6271)
- **Goal**: Context auto-compression zamiast wysyłania całej historii
- **Context**: Agent.ts toolCallingLoop, MissionConsole.tsx, MAX_HISTORY_MESSAGES
- **Files**: runtime/context.ts (new), Agent.ts, MissionConsole.tsx, capabilities.ts
- **Verification**: npx tsc --noEmit

### Gap 6 — Self improvement (deleg_20fda34a)
- **Goal**: EvolutionEngine z UsagePattern, auto-tuning, regression detection
- **Context**: model.ts CapabilityId, agent/config patterns, toolCallingLoop lifecycle
- **Files**: agent/evolution.ts (new), agent/evolution-index.ts (new), capabilities.ts, Agent.ts
- **Verification**: npx tsc --noEmit

## Results

| Subagent | Duration | Files Changed | Verification |
|----------|----------|---------------|-------------|
| proxy-pipeline | 354s | ProxyLayer.ts | tsc OK, 109/110 tests passed |
| hallucination | 474s | HallucinationDetector.ts (573 lines) | tsc OK, 110/110 tests passed |
| metalearning | ~300s | capabilities.ts, memory/feedback.ts, MemoryMesh.ts | tsc OK |
| skills | ~300s | skills/ (3 files), capabilities.ts, model.ts | tsc OK |
| autocompact | ~300s | runtime/context.ts, Agent.ts, MissionConsole.tsx, capabilities.ts | tsc OK |
| self-improvement | ~300s | agent/evolution.ts, evolution-index.ts, capabilities.ts, Agent.ts | tsc OK |

Total wall-clock: ~8 min (6 subagents ~5 min, merge+verify ~3 min).\n\n## Post-Merge: CLI Wrapper Fix\n\nAfter `npm run build` succeeded, `aigon-code --version` failed with `MODULE_NOT_FOUND`. The wrapper at `~/.local/bin/aigon-code` had:\n```bash\nREAL_BIN=\"<workspace>/products/aigon-code/cli/dist/aigon-code.js\"   # STALE — missing prod/\n```\n\nCorrect path:\n```bash\nREAL_BIN=\"<workspace>/products/prod/aigon-code/cli/dist/aigon-code.js\"\n```\n\n**Lesson:** After any subagent batch that modifies CLI source files:\n1. `npm run build` — succeeds\n2. `<cli-name> --version` — may fail if wrapper points to stale path\n3. Fix wrapper or `package.json bin` field\n\nThe build itself produced correct files. The issue was the wrapper's hardcoded path from a prior repo restructure (`products/aigon-code` → `products/prod/aigon-code`).

## Key Learnings

1. **Batch size**: 6 subagents dispatched in 2 calls of 5+1 due to max_concurrent_children=5 constraint. Should have dispatched all 6 in one call (the constraint wasn't hit).
2. **No file collisions**: Each gap touched completely different files. This made merge trivial.
3. **Per-subagent tsc**: Each subagent independently verified tsc passed, so merge had zero compilation errors.
4. **Context accuracy**: Giving subagents exact file snippets (not descriptions) eliminated ambiguity. No subagent asked clarifying questions.
5. **Parent backfill**: While subagents ran, parent prepared build pipeline and monitored transcripts via `tail -f` — no wall-clock time wasted.
