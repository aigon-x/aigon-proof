# MCP Bridge Handler Routing Map — AIGON Code

**Source:** `products/aigon-code/mcp-rs/src/main.rs` (1282 lines)
**Date:** 2026-07-22

## Handler Dispatch Order (`call_tool`, line 531)

Tools are matched in this order — first match wins:

### Group 1: Explicit Runtime Handlers (lines 533-654)

| Tool Name | What It Does | Lines | Status |
|-----------|-------------|-------|--------|
| `runtime_health` | GET `/health` | 533-536 | ✅ works |
| `runtime_query` | Generic runtime proxy (GET/POST) | 537-548 | ✅ works |
| `runtime_kernels` | GET `/api/v1/kernels` | 549-552 | ✅ works |
| `echo` | Echo server info | 553-556 | ✅ trivial |
| `tui__gateway` | Returns TUI socket info | 557-573 | ✅ local |
| `runtime_tools` | GET `/api/tools` | 574-577 | ✅ works |
| `web_search` | DuckDuckGo HTML search | 578-597 | ✅ works |
| `web_extract` | HTTP GET page content | 598-618 | ✅ works |
| `web_crawl` | Crawl4AI → direct fetch fallback | 619-654 | ✅ works |
| `filesystem` | Local dir/list/read | 691-710+ | ✅ local |

### Group 2: AI Capabilities — Fixed (proxied to backend-rs postgres) (line 366-460)

| Tool Name | Handler | What It Actually Does | Status |
|-----------|---------|----------------------|--------|
| `ai__learning` | `handle_capability` | POST embedding to backend-rs:8080/api/v1/memory/ingest — **201 Created** | ✅ fixed |
| `ai__metalearning` | `handle_capability` | Same as ai__learning (identical code path) | ✅ fixed |
| `ai__memory_extended` | `handle_capability` | POST query to backend-rs:8080/api/v1/memory/search — returns chunks | ✅ fixed |
| `ai__reasoning` | `handle_capability` | Generates 6 static COT strings — **no LLM** | ❌ stub |

### Group 3: CC Capabilities — All Catch-All Stubs (lines 659-689)

ALL of these route through the catch-all `_` in `handle_capability` (line 461-472), returning only a JSON descriptor:

- `code__architecture`, `code__bench`, `code__bugs`, `code__canon`, `code__deps`, `code__docs`, `code__migrate`, `code__perf`, `code__plan`, `code__quality`, `code__rca`, `code__refactor`, `code__review`, `code__security`, `code__test`
- `business__report`, `communication__email`
- `compute__background_jobs`, `compute__federated`, `compute__gpu`
- `geo__maps`, `geo__places`
- `knowledge__discovery`, `knowledge__memory`
- `marketing__content`, `media__animation`, `media__audio`, `media__image`, `media__video`
- `ops__deployment`, `ops__ha_continuity`, `ops__ha_failover`, `ops__ha_multiregion`, `ops__monitoring`
- `product__copy`, `product__ux`, `run__benchmarks`
- `security__audit`, `storage__tenant_db`, `storage__vector`
- `web__analytics`, `web__geo`, `web__seo`

**Status: ALL ❌ stubs** — return `{"capability":"name","status":"available","handler":"mcp-bridge-local","mode":"request-response"}`

### Group 4: Gateway Tools (lines 690+)

| Tool Name | What It Does | Status |
|-----------|-------------|--------|
| `filesystem` | Local file listing/reading | ✅ local |
| `deploy_docker` | Docker build+deploy proxy | ⚠️ compile warning (unreachable) |
| ... others in GATEWAY_TOOLS | Proxied via `proxy_gateway_tool` | ✅ | 

### Group 5: Vairify Tools

Proxied via Vairify backend (port 10081). Active if `VAIRIFY_PROXY_UPSTREAM_URL` is set.

### Group 6: Catch-All (line ~last)

`_ => Err("Unknown tool".into())` — returns error for truly unknown names.

## Capability Catalog vs Reality

| Source | Count | Actual Implementation |
|--------|-------|----------------------|
| DB `capabilities_list` | 83+ | All marked `active` |
| MCP `tools/list` | 87 | Listed with schemas |
| **Real handlers** | ~15 | runtime_health, runtime_kernels, web_search, web_extract, web_crawl, runtime_query, echo, tui__gateway, runtime_tools, filesystem, + **ai__learning, ai__metalearning, ai__memory_extended** (proxied to backend-rs) |
| **Stubs (AI/CC)** | 38+ | Return descriptor only |
| **Fixed (learning/memory)** | 3 | ai__learning, ai__metalearning, ai__memory_extended — proxied to backend-rs postgres |
| **Broken (wrong URL)** | 0 | ~~ai__learning, ai__metalearning, ai__memory_extended~~ ✅ fixed |

## Backend-rs Endpoint Map (for fixing learning/memory routes)

Backend-rs runs on PROD host, port 8080. **From Docker containers** that are not on the host network, the host's port 8080 may be firewalled — use `--network host` for the MCP container, or use a network that routes to the host.

**Auth:** Backend-rs requires BOTH headers (the `require_auth` middleware checks in this order):
```
Authorization: Bearer <JWT>
X-API-Key: <JWT>
```

The JWT must be a **session token** signed with `AIGON_JWT_SECRET` (the long key). A PAT (`AIGON_API_KEY`) may be expired/revoked — use the session token from `~/.aigon/session.json` instead.

The CLI client (TypeScript) builds headers as follows:
```typescript
function authHeader(apiKey: string): string {
  const token = apiKey.trim();
  return looksLikeJwt(token) ? `Bearer ${token}` : token;  // looksLikeJwt = startsWith("eyJ")
}
// Sends both:
headers["Authorization"] = authHeader(apiKey);   // "Bearer <jwt>" if starts with eyJ
headers["X-API-Key"] = apiKey.trim();            // raw key always
```

In Rust MCP bridge, replicate with:
```rust
let mut req = state.http.post(&url).json(&body);
if !state.api_key.is_empty() {
    req = req.header("Authorization", format!("Bearer {}", state.api_key));
    req = req.header("X-API-Key", &state.api_key);
}
```

| Endpoint | Method | Purpose | Auth Required |
|----------|--------|---------|---------------|
| `/api/v1/memory/ingest` | POST | Store memory chunk | Both Bearer + X-API-Key JWT |
| `/api/v1/memory/search` | POST | Semantic memory search | Both Bearer + X-API-Key JWT |
| `/api/v1/memory/sync` | POST | Sync memory across mesh | Both Bearer + X-API-Key JWT |
| `/api/v1/code/generate` | POST | Code generation proxy | Both Bearer + X-API-Key JWT |
| `/health` | GET | Health check | No |
