# CLI-Level Live Transcripts — Agent Transparency Pattern

**Created**: 2026-07-27, aigon-code CLI
**Pattern**: Append-only JSONL transcript files for sub-agent execution, with real-time TUI viewer via fs.watch

## Architecture (3 moduły)

```
┌─────────────────────────────┐
│  BatchOrchestrator          │
│  ├─ Agent 1 + Writer         │  ─┐
│  ├─ Agent 2 + Writer         │   ├─ Promise.allSettled
│  └─ Agent N + Writer         │  ─┘
└──────────┬──────────────────┘
           │ writes to
           ▼
┌─────────────────────────────┐
│  ~/.aigon/live/<batch-id>/  │
│  ├─ agent-0.jsonl (append)  │
│  ├─ agent-1.jsonl           │
│  └─ agent-N.jsonl           │
└──────────┬──────────────────┘
           │ fs.watch
           ▼
┌─────────────────────────────┐
│  LiveTranscriptView (Ink)   │
│  ├─ Left: agent list + stts │
│  ├─ Right: live log stream  │
│  └─ Bottom: agent flipper   │
└─────────────────────────────┘
```

## Komponenty

### 1. LiveTranscriptWriter (`src/agent/live-transcript.ts`)

- Append-only JSONL writer do `~/.aigon/live/<batch-id>/<agent-id>.jsonl`
- Każdy wpis: `{ timestamp, type: "tool_call"|"tool_result"|"assistant"|"user", content, metadata? }`
- Współdzielony między BatchOrchestrator a AgentRunner
- Lazy init — tworzy katalog i plik przy pierwszym write

### 2. LiveTranscriptWatcher

- Owijka wokół `fs.watch` + polling backup
- Emituje events: now_entry, agent_done, agent_error, new_batch
- Opcjonalne callbacki: `onEntry(batchId, agentId, entry)`
- Polling co 500ms jako fallback gdy fs.watch nie działa (NFS, WSL)

### 3. BatchOrchestrator (`src/agent/batch-orchestrator.ts`)

- `runBatch(tasks)` — akceptuje tablicę zadań
- Każde zadanie dostaje własny `LiveTranscriptWriter`
- Wszystkie sub-agenty uruchomione przez `Promise.allSettled`
- Wyniki agregowane w `{ task, status, entryCount, error? }`
- Timeout na cały batch + per-agent timeout

### 4. LiveTranscriptView (Ink komponent)

- React/Ink komponent z trzema panelami:
  - **Lista agentów** (lewy) — każdy agent z kolorową nazwą, statusem (running/done/error), liczbą wpisów
  - **Szczegóły** (prawy) — ostatnie 20 wpisów wybranego agenta, auto-scroll, kolorowanie typów
  - **Flipper** (dół) — Tab/Shift+Tab do przełączania agentów, Esc do zamknięcia
- Używa `useInput` z Ink dla klawiatury
- Odświeżanie przez `setInterval` co 500ms + `fs.watch` na katalogu

## Integracja z CLI

W `MissionConsole.tsx`:

```tsx
// State
const [liveViewBatchId, setLiveViewBatchId] = useState<string | null>(null);

// Command handler
case "/live":
case "/transcripts":
  setLiveViewBatchId(trimmed.split(/\s+/)[1] ?? "");
  // Domyślnie wyświetla listę batchy
  break;

// Render (nad tab content)
{liveViewBatchId !== null && (
  <LiveTranscriptView
    initialBatchId={liveViewBatchId || undefined}
    onClose={() => setLiveViewBatchId(null)}
  />
)}
```

Komendy:
- `/live` — lista ostatnich batchy
- `/live <batch-id>` — podgląd w czasie rzeczywistym

## File layout

```
~/.aigon/live/
├── <batch-id>/
│   ├── agent-0.jsonl
│   ├── agent-1.jsonl
│   └── metadata.json     # task descriptions, start time, model
└── latest -> <batch-id>  # symlink do ostatniego batcha
```

## JSONL Entry Format

```json
{"timestamp":"2026-07-27T20:00:00.123Z","type":"tool_call","tool":"terminal","input":"cargo check -p aigon-runtime","agent":"Agent-1"}
{"timestamp":"2026-07-27T20:00:01.456Z","type":"tool_result","tool":"terminal","result":"exit_code=0","duration_ms":1234,"agent":"Agent-1"}
{"timestamp":"2026-07-27T20:00:02.789Z","type":"assistant","content":"Build passes.","agent":"Agent-1"}
```

## Verification

- `npm run build` — kompilacja
- `npx tsc --noEmit` — zero błędów TypeScript
- `npm run test` — testy przechodzą
- CLI: `/live` pokazuje listę, `/live <id>` otwiera podgląd
- Tworzenie plików: `ls ~/.aigon/live/` po uruchomieniu BatchOrchestrator

## Pliki źródłowe

- `cli/src/agent/live-transcript.ts` — Writer + Watcher + listBatches
- `cli/src/agent/batch-orchestrator.ts` — BatchOrchestrator
- `cli/src/components/views/LiveTranscriptView.tsx` — Ink TUI
- `cli/src/components/MissionConsole.tsx` — integracja (/live command)
