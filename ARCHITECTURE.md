# Architecture

```
                ┌──────────────────────────────┐
  MCP client ──▶│ /mcp  (Streamable HTTP)      │
  stdio client ─▶│ stdio                        │──▶ tools ──▶ data layer ──▶ canonical files
  browser ──────▶│ /  + /api/*  (axum)          │                    │
                └──────────────┬───────────────┘                    │
                               │                                     ▼
                        OTLP/HTTP traces                    OnceLock caches
```

## Layers

1. **Data** (`src/data.rs`) — parses YAML/JSON canon into typed structs, caches with `OnceLock`,
   exposes search, stats, classification, matrix and budgeted context.
2. **Tools** (`src/mcp.rs`) — 25 MCP tools; every tool returns JSON text through
   `ContentBlock::json`, so clients get structured data without a custom schema per call.
3. **Transport** (`src/web.rs`) — axum router with the web explorer, JSON API and the rmcp
   Streamable HTTP service mounted at `/mcp`; gzip/brotli via `tower-http`.
4. **Execution** (`src/runner.rs`) — the only side effect: `gates_run` invokes a gate script
   inside allowlisted roots, as an argument vector, with a 20 s timeout and `kill_on_drop`.
5. **Telemetry** (`src/telemetry.rs`) — OTLP/HTTP trace export when the endpoint is configured;
   otherwise a plain `tracing` subscriber on stderr.
6. **Proof** (`src/proof.rs`) — deterministic policy, fail-closed HMAC passports and a crash-test lab.

## Decisions

* **Rust + rmcp 3.6** — the official SDK negotiates protocol `2025-11-25` and provides the
  Streamable HTTP transport, so the server speaks the current spec instead of a hand-rolled JSON-RPC.
* **Read-only by construction** — no tool has a write path; canonical files are opened read-only.
* **Deterministic classifier** — completeness is derived from the catalogue and the filesystem,
  not from a model, so a judge can reproduce every number.
* **Budgeted context** — `context_pack` is the answer to context windows: it packs the canon into
  a character budget and says when it truncated.

## Failure modes

| Situation | Behaviour |
|---|---|
| Canon file missing/malformed | 503 on `/api/health`, error text on the tool call; never an empty rulebook |
| Gate script outside allowlist or traversal attempt | request rejected before any process starts |
| Gate selftest exceeds 20 s | process killed, `timed_out: true` |
| OTLP endpoint unreachable | server still starts; export errors are logged, requests unaffected |

## Limits

* Hybrid retrieval needs the local ONNX model; lexical fallback stays available.
* Bundled fixtures are the fallback; live `/opt/PROD` files win when present.
* `POST /api/gates/{id}/run` is a trusted-network endpoint; set `AIGON_ALLOW_RUN=0` to disable.
