---
name: mcp-api-key-separation
description: >
  Fix MCP Gateway authentication by separating API keys — use dedicated MCP_GATEWAY_API_KEY
  env var instead of sharing AIGON_API_KEY between client auth and service-to-service auth.
source: auto-skill
extracted_at: '2026-07-03T03:25:00.746Z'
---


# MCP Gateway API Key Separation

## Problem

Runtime uses `AIGON_API_KEY` for BOTH:
1. Authenticating HTTP API clients (frontends, CLI)
2. Authenticating to MCP Gateway (service-to-service)

If the MCP Gateway (router) has a different `AIGON_API_KEY`, the runtime gets 401 Unauthorized when trying to connect. Changing `AIGON_API_KEY` to match the router breaks all API clients.

## Root Cause

- Runtime `lib.rs` line ~7497: `std::env::var("AIGON_API_KEY")` used for MCP Gateway auth header
- Router validates incoming `X-API-Key` header against its own `AIGON_API_KEY`
- No mechanism to use a different key for MCP vs client auth

## Fix Steps

### 1. Code Change (lib.rs)

Replace:
```rust
let api_key = std::env::var("AIGON_API_KEY")
    .map_err(|_| { tracing::debug!("not set"); })
    .ok();
```

With:
```rust
let api_key = std::env::var("MCP_GATEWAY_API_KEY")
    .or_else(|_| std::env::var("AIGON_API_KEY"))
    .map_err(|_| { tracing::debug!("not set"); })
    .ok();
```

### 2. Compose Env (docker-compose.yml)

Add to runtime service env:
```yaml
- MCP_GATEWAY_API_KEY=${MCP_GATEWAY_API_KEY:-${AIGON_API_KEY}}
```

### 3. Host .env (deploy/compose/.env)

Set the correct router key:
```
MCP_GATEWAY_API_KEY=<router's AIGON_API_KEY value>
```

### 4. Secret File (deploy/compose/secrets/aigon_api_key)

Keep as runtime's own key (for client auth). Do NOT change to router's key.

## Architecture Principle

```
┌──────────────┐     X-API-Key: AIGON_API_KEY     ┌──────────────┐
│  API Clients  │ ──────────────────────────────→  │   Runtime    │
│ (frontends)  │                                   │ (port 14500) │
└──────────────┘                                   └──────┬───────┘
                                                           │
                                              X-API-Key: MCP_GATEWAY_API_KEY
                                                           │
                                                           ▼
                                                   ┌──────────────┐
                                                   │ MCP Gateway  │
                                                   │ (port 17002) │
                                                   └──────────────┘
```

- `AIGON_API_KEY` = what clients use to authenticate to the runtime
- `MCP_GATEWAY_API_KEY` = what runtime uses to authenticate to MCP Gateway
- These should be DIFFERENT values

## Verification

```bash
# Test router's key works:
curl -H "X-API-Key: <router-key>" http://localhost:17002/health

# Test runtime's key fails:
curl -H "X-API-Key: <runtime-key>" http://localhost:17002/health
# → {"error":"Unauthorized — missing or invalid API key"}
```

## Check for Triple-Key Chaos

Systems with split-brain key management often have THREE keys:
1. `AIGON_API_KEY` in root `.env` (router's key)
2. `AIGON_API_KEY` in `deploy/compose/.env` (runtime's key)
3. `MCP_GATEWAY_API_KEY` in `deploy/compose/.env` (some third key)

Fix: align #3 with #1 (router's key for MCP auth), keep #2 for client auth.
