---
name: mcp-tools-fix
description: Diagnostic and repair workflow for broken MCP tools (empty schemas, mock backends, timeouts, dead handlers)
---


# MCP Tools Fix Workflow

Use when MCP tools have empty schemas, return mock responses, or timeout.

## Symptoms
- `inputSchema: {}` or empty descriptions in tools/list
- Tools return "[Mock] ..." responses
- "error sending request for url" from reqwest proxy
- Hardcoded template responses ("Generate code templates...")

## 0. Server completely down / bring-up checklist

When Hermes logs `MCP: registered 0 tool(s) from 0 server(s) (1 failed)` / `Connect call failed ('<ip>', 17004)`, the bridge itself is down — schema/handler fixes above are irrelevant until it listens again.

Diagnose in this order (on the MCP host, e.g. `ssh contabo-aigon`):
```bash
ss -tlnp | grep 17004                       # is anything listening?
docker ps -a | grep -iE 'mcp|aigon-code'    # container gone or exited?
systemctl list-unit-files | grep -i mcp     # unit masked? (mcp-mesh-router.service was found masked)
journalctl -u <unit> -n 50                  # why it died
```

Bring-up facts (verified 2026-07-22):
- Source + Dockerfile live at `<workspace>/products/aigon-code/mcp-rs` (crate `aigon-code-mcp`, axum, EXPOSE 17004, `/health` healthcheck). Build: `docker build -t aigon-code-mcp products/aigon-code/mcp-rs` or `cargo build --release` and scp the binary.
- Run with `--network host` (see 6c1) and env `AIGON_V2_RUNTIME_URL`, `AIGON_BACKEND_URL`, `AIGON_API_KEY`.
- Hermes side: `~/.hermes/config.yaml` → `mcp_servers.aigon-code.url: http://contabo-aigon:17004/mcp/message` with `Authorization: Bearer ${MCP_AIGON_CODE_API_KEY}` from `~/.hermes/.env`. After restart, `/reload-mcp` or new session — `hermes mcp test aigon-code` to verify.
- A masked systemd unit (`mcp-mesh-router.service masked`) means someone deliberately disabled the old supervisor — unmask only if you intend to restore systemd management, otherwise run via docker `--restart unless-stopped`.

## 1. Check Schemas
The MCP server (mcp-rs) defines tools in `runtime_tools()`.

Three groups in order of appearance in `call_tool`:
1. **Explicit handlers** — specific `match name { ... }` arms (hardcoded templates, dead code)
2. **CC_CAPABILITIES** — 47 generic tools with `{files: string[], context: object}` schema
3. **GATEWAY_TOOLS** — gateway-proxied tools like `web_search`, `media__video`
4. **VAIRIFY_TOOLS** — Vairify-proxied tools
5. **Catch-all** — `_ => Err("Unknown tool")` for unlisted tools

**Fix schemas**: RUNTIME_TOOL_DEFS must include `description` and `inputSchema` with proper JSON Schema (not `{}`).

## 2. Fix Dead Handlers
Some tools are listed in RUNTIME_TOOL_DEFS for listing but have NO handler in `call_tool` (fall through to "Unknown tool"). Others have hardcoded templates that bypass the runtime.

**Check call_tool**: for each RUNTIME_TOOL_DEFS entry, verify there's a corresponding match arm that proxies to the runtime API.

## 3. Fix Mock Backend
Runtime endpoints like `/api/v1/code/:tool` call `handle_capability_call` which routes through `infer_adaptive`. If the provider cascade falls through to Mock (prio 99), the response starts with `[Mock] ...`.

**Root cause**: MCP server proxies to CONTABO's runtime which has NO Ollama → fall through to Mock.

**Fix**: Point MCP to LOCAL's runtime directly:
```
AIGON_V2_RUNTIME_URL=http://<LOCAL_IP>:7000
```

## 4. Fix Timeouts
reqwest client has a global 30s timeout. Code generation inference takes 40-60s.

**Fix**: Set both client-wide and per-request timeout to 120s.
```rust
let http = reqwest::Client::builder()
    .timeout(Duration::from_secs(120))
    .build()?;
match state.http.post(&url).json(args)
    .timeout(Duration::from_secs(120))
    .send().await { ... }
```

## 5. Add Debug to Errors
All `Err(e)` handlers that use `format!("...{}...", e)` should include `{:?}` for the reqwest Error kind:
```rust
format!("... {} [{:?}]", e, e)
```

This reveals the actual error type (TimedOut, Connect, Request, etc.) instead of just the message.

### Handling nested-quote json! errors
When the err handler uses `json!({"error": format!("msg {}", e)})` inside Rust source, the `patch` tool may reject it due to escape-drift (nested `\"` in the Rust string literal). Bypass with `sed -i` directly:

```bash
sed -i 's/old pattern/new pattern/g' src/main.rs
```

For the two-step Vairify fix (display → display+debug):
```bash
# Step 1: add placeholder
sed -i 's/Vairify proxy error: {}/Vairify proxy error: {} [{:?}]/g' src/main.rs
# Step 2: add second argument
sed -i 's/Vairify proxy error: {} \[{:?}\]", e)/Vairify proxy error: {} [{:?}]", e, e)/g' src/main.rs
```

## 6. Capability Wiring Audit (Learning, Reasoning, RAG, CC)

Beyond the MCP bridge itself, the capabilities it exposes may not be truly wired to a backend. Run this audit when capabilities return `"status":"available"` but no real work, or when MCP tools return 404 despite being in the catalog.

See `references/capability-wiring-map.md` for the full handler routing table.

### 6a. Check Capability Registry vs Handler Reality

The DB catalog (`mcp_aigon_code_capabilities_list`) may list 80+ capabilities as `active` but the MCP server's `call_tool` routes most to a catch-all `_` that returns only a descriptor, not a real result.

**Signature of a stub handler** (catch-all in `handle_capability`):
```json
{"capability":"code__xxx","status":"available","handler":"mcp-bridge-local","mode":"request-response","context_present":false,"files_provided":0}
```

**Fix**: Each capability needs either:
- A proxy endpoint on the runtime (`proxy_get`/`proxy_post`)
- A local handler with real logic
- A routing to backend-rs for domain-specific endpoints

### 6b. ai::learning / ai::metalearning — Wrong URL Bug (FIXED)

`ai__learning` and `ai__metalearning` POST to `state.runtime_url/api/v1/memory/ingest`
but `state.runtime_url` points to the **runtime engine** (`:7000`). The `/api/v1/memory/*`
endpoints are on **backend-rs** (`:8080`).

**Root cause**: `handle_capability` used `state.runtime_url` for memory endpoints.

**Fix**: Add separate `state.backend_url` (from env `AIGON_BACKEND_URL`, default
`http://localhost:8080`) and `state.api_key` (from env `AIGON_API_KEY`). Add both
to `AppState` struct and initialization. Then use `state.backend_url` for all
`/api/v1/memory/*` calls plus both auth headers. Remove `.ok()` that swallowed errors
so backend responses are visible in the response.

```rust
// In AppState:
struct AppState {
    runtime_url: String,
    backend_url: String,   // NEW
    api_key: String,       // NEW
    // ...
}

// In main():
let state = AppState {
    runtime_url: runtime_url.clone(),
    backend_url: backend_url(),  // NEW: env_or("AIGON_BACKEND_URL", "http://localhost:8080")
    api_key: api_key(),          // NEW: env_or("AIGON_API_KEY", "")
    // ...
};

// In handle_capability for learning/metalearning/memory:
let ingest_url = format!("{}/api/v1/memory/ingest", state.backend_url);
let mut req = state.http.post(&ingest_url).json(&body).timeout(Duration::from_secs(10));
if !state.api_key.is_empty() {
    req = req.header("Authorization", format!("Bearer {}", state.api_key));
    req = req.header("X-API-Key", &state.api_key);
}
let ingest_result = req.send().await;
let backend_status = match &ingest_result {
    Ok(r) => format!("{}", r.status()),
    Err(e) => format!("error: {}", e),
};
```

**Symptom** (before fix): MCP returns `{"capability":"ai__learning","status":"available"}` but the POST to `/api/v1/memory/ingest` either 404s (wrong URL) or 401s (missing auth).

**Verification** (after fix): MCP returns `{"backend_status":"201 Created",...}` — the
chunk was ingested into PostgreSQL. `ai__memory_extended` returns chunks via search.

### 6c. Missing Auth Headers for Backend-rs Calls

Even after fixing the URL, backend-rs (`:8080`) requires BOTH headers (the `require_auth` middleware tries Authorization Bearer first, then X-API-Key):

```
Authorization: Bearer <JWT>
X-API-Key: <JWT>
```

The JWT must be a valid token signed with `AIGON_JWT_SECRET`. The session token from `~/.aigon/session.json` works. A PAT (`AIGON_API_KEY`) may be expired — use the session JSON token instead.

```rust
// Required fix pattern in handle_capability — both headers:
let mut req = state.http.post(&url).json(&body);
if !state.api_key.is_empty() {
    req = req.header("Authorization", format!("Bearer {}", state.api_key));
    req = req.header("X-API-Key", &state.api_key);
}
```

### 6c1. Docker network: host services unreachable from containers

When the MCP container runs on default bridge (`172.17.0.0/16`), the host's services (backend-rs on port 8080) may be blocked by Docker firewall rules — connection timeouts even on the Docker gateway IP (`172.17.0.1`).

**Fix**: add `--network host` to the `docker run` command so the container can reach `localhost:8080` directly.

```bash
docker run -d --restart unless-stopped --network host --name aigon-x-gateway-mcp \
  -v /path/to/binary:/usr/local/bin/aigon-code-mcp:ro \
  -e AIGON_V2_RUNTIME_URL=http://<LOCAL_IP>:7000 \
  -e AIGON_BACKEND_URL=http://localhost:8080 \
  -e AIGON_API_KEY='<session_token>' \
  <image> aigon-code-mcp
```

⚠️ Trade-off: `--network host` means the container shares the host's full network stack — no port isolation. Acceptable for the MCP bridge which only listens on port 17004.

### 6d. ai::reasoning — Fake Stub

`ai__reasoning` generates 6 hardcoded chain-of-thought strings without invoking any LLM:

```rust
// main.rs:422-437 — zero LLM calls
chain.push("1. Input analysis: parsing request and identifying key elements");
chain.push(format!("2. Input length: {} characters", input.len()));
chain.push(format!("3. Token estimate: ~{} tokens", word_count * 2));
chain.push("4. Context assembly: gathering relevant knowledge and constraints");
chain.push("5. Logical deduction: applying rules and patterns");
chain.push("6. Conclusion: synthesized output");
```

This is a development stub. The output is always the same structure regardless of input. Fix requires wiring to an actual LLM via `proxy_post` to the runtime's `/api/v1/infer` endpoint.

### 6e. RAG / Knowledge Search — Mock Fallthrough

`knowledge_search` MCP tool falls through to the Mock LLM provider (returns `[Mock] You are the AIGON-X capability 'code::'...`). No real RAG exists:

| Check | Finding | Fix |
|-------|---------|-----|
| `knowledge_list` | `[]` — empty | Ingest knowledge sources via `knowledge_create` |
| Qdrant on PROD (`127.0.0.1:6333`) | exists, empty | Index markdown files into Qdrant |
| Knowledge files on disk | `products/aigon-code/knowledge/` exists | Vectorize with embedding model |
| `knowledge__discovery` MCP | Reads filenames from disk | Not semantic search; upgrade to vector |
| Embeddings used | `[0.0; 384]` placeholder | Replace with real embedding API call |

### 6f. CC Capabilities — All Are Descriptor Stubs

All capabilities in groups `code::*`, `ops::*`, `media::*`, `storage::*`, `knowledge::*`, `geo::*`, `web::*`, `product::*`, `security::*`, `compute::*`, `business::*`, `communication::*`, `marketing::*`, `run::*` route to the `handle_capability` catch-all `_` which returns only a descriptor JSON with no real processing.

**35+ capabilities affected.** Each needs a dedicated handler that either:
- Proxies to a real backend endpoint
- Runs local code (e.g., disk-based knowledge discovery)
- Delegates to an external service

## 7. Remove Duplicate Match Arms (same tool, two handlers)

After adding real proxy handlers that route to the runtime API, the old local stub handlers may remain in the same match statement, making the proxy handlers unreachable. Symptom: `warning: unreachable pattern` during compilation.

### Pattern: find and remove the old local handlers

```rust
// BAD — two handlers for the same tool. The first one (local stub) always matches:
"code_review" => { /* local file reader — reachable */ }
...
"code_review" => { /* proxy to runtime — unreachable! */ }
```

**Fix workflow:**
1. Build with `cargo build --release` — read compiler warnings for unreachable patterns
2. Identify which set is the old local stub (reads files locally, returns JSON templates) vs the new proxy handler (calls `proxy_post`/`proxy_get` to runtime API)
3. Remove the old local handlers — keep the proxy handlers (they work on all nodes, not just the MCP bridge host)
4. Rebuild and verify 0 warnings

### Second duplicate pattern: CC_CAPABILITIES in catch-all

All 44 CC_CAPABILITIES are matched explicitly before `_ =>`. A `for (tool, _desc, method, endpoint) in CC_CAPABILITIES` loop in the catch-all is unreachable dead code:

```rust
// In call_tool:
"code__architecture" | "code__bench" | ... => handle_capability(name, args, state).await,
...
_ => {
    // This loop is unreachable — all CC_CAPABILITIES matched above:
    for (tool_name, _, method, endpoint) in CC_CAPABILITIES { ... }  // DELETE THIS
    // Keep these — they handle GATEWAY_TOOLS and VAIRIFY_TOOLS:
    for (tool_name, _) in GATEWAY_TOOLS { ... }
    for (tool_name, method, endpoint) in VAIRIFY_TOOLS { ... }
}
```

### Real session example (2026-07-21)

8 tools had duplicate handlers (local file-reader + proxy): `code_analyze`, `code_generate`, `code_review`, `code_fix`, `test_run`, `project_info`, `knowledge_search`, `deploy_docker`. All 8 local handlers removed, file shrunk by 31 lines. Plus removed unreachable CC_CAPABILITIES loop from catch-all (13 lines). Build went from 7+ warnings to 0.

## UCB Adapter Invoke (Runtime side)

When the **consumer** side of MCP (the adapter inside `aigon-ucb` crate) uses simulated/mock responses instead of real HTTP calls to the Runtime.

### Symptoms
- `McpAdapter::invoke()` returns hardcoded mock JSON (e.g. `"status":"ok","model":"mock-model"`) for all tools
- UCB capabilities report `handler:"mcp-adapter"` but no actual MCP traffic happens
- Tests pass but integration fails — no real tool execution

### Fix: swap mock → real HTTP client

**File**: `runtime-v2/crates/aigon-ucb/src/mcp_adapter.rs`

#### 1. Add reqwest dependency
```toml
# Cargo.toml of aigon-ucb
reqwest = { workspace = true, features = ["blocking"] }
```

#### 2. Add static HTTP client + imports
```rust
use reqwest::blocking::Client;
use std::sync::LazyLock;

static MCP_HTTP_CLIENT: LazyLock<Client> = LazyLock::new(|| {
    Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .expect("Failed to create MCP HTTP client")
});
```

#### 3. Rewrite invoke() with real JSON-RPC POST

The method sends a JSON-RPC 2.0 request to `{self.server_url}/mcp/message` and handles three operations:
- **`list_tools`** — `{"jsonrpc":"2.0","method":"tools/list","id":1}` → returns tool list
- **`call_tool`** — `{"jsonrpc":"2.0","method":"tools/call","params":{"name":"...","arguments":{...}},"id":1}` → returns tool result
- **`get_tool_info`** — calls `tools/list` then filters by name

```rust
fn invoke(&self, operation: &str, params: &HashMap<String, serde_json::Value>) -> Result<AdapterOutput, UcbError> {
    let url = format!("{}/mcp/message", self.server_url);
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": match operation {
            "list_tools" | "get_tool_info" => "tools/list",
            _ => "tools/call",
        },
        "params": match operation {
            "list_tools" | "get_tool_info" => serde_json::json!({}),
            _ => serde_json::json!({ "name": operation, "arguments": params }),
        },
        "id": 1,
    });

    let response = MCP_HTTP_CLIENT
        .post(&url)
        .json(&body)
        .send()
        .map_err(|e| UcbError::invocation_failed(format!("MCP request failed: {e:?}")))?;

    let response_body: serde_json::Value = response
        .json()
        .map_err(|e| UcbError::invocation_failed(format!("MCP response parse: {e:?}")))?;

    let result = response_body.get("result")
        .ok_or_else(|| UcbError::invocation_failed("MCP response missing 'result'"))
        .cloned()?;

    Ok(AdapterOutput::new(result))
}
```

#### 4. Fix error constructors
`UcbError` uses constructor functions (NOT variant names):
- `UcbError::invocation_failed(msg)` — variant `InvocationFailed(String)`
- `UcbError::capability_not_found(id)` — variant `CapabilityNotFound(String)`

Do NOT use `UcbError::AdapterError(...)` — that variant does not exist. Use `.to_string()` instead of `.into()` for string literals to avoid ambiguity with `reqwest::Body::From<&str>`.

#### 5. Verify compilation
```bash
cargo check -p aigon-ucb
cargo check -p aigon-runtime-bin  # full dependency chain
```

### Pitfalls
- `UcbError::AdapterError` does NOT exist — use `UcbError::invocation_failed()` or `UcbError::capability_not_found()`
- `.into()` on a `&str` literal is ambiguous when `reqwest` types are in scope — use `.to_string()` instead
- The `LazyLock<Client>` must have a long enough timeout (15s minimum) for real MCP calls
- After patching, always run full `cargo check` on both the crate and the top-level binary to catch enum mismatch errors

## Pitfalls
- **order matters** in `call_tool` match — explicit handlers catch names before the catch-all
- **duplicate match arms** — adding proxy handlers without removing the old local stubs creates unreachable code; always check for compiler warnings after editing `call_tool`
- **node-local.yaml** `listen_addr` must be `0.0.0.0:7000` (not localhost) for mesh access
- **Ollama on LOCAL only** — CONTABO runtime falls through all provider cascade to Mock
- **Docker /tmp noexec** — on some hosts `/tmp` has `noexec` mount flag; use `/opt/` for binary mounts
- **Edition lint errors** — mcp-rs Cargo.toml has `edition = "2021"` but lint warns 2015; these are pre-existing and don't affect compilation
- **Hot-swap via bind mount** — when MCP container has binary bind-mounted (e.g. `-v /tmp/aigon-code-mcp:/usr/local/bin/aigon-code-mcp:ro`), `docker cp` fails with device or resource busy. Fix: copy new binary to host bind-mount path (`scp binary <host>:/opt/aigon-code-mcp`) then `docker restart`. For env changes, `docker rm -f` + `docker run` with `--network host`.

## 6. Post-deploy: test every node
After deploying the MCP fix, verify every runtime node and MCP itself:

### Test MCP tool call
```bash
# Via MCP server (CONTABO:17004)
curl -sf -X POST http://localhost:17004/mcp/message \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
       "params":{"name":"code_generate",
                 "arguments":{"specification":"rust fn add","files":[],"context":{}}}}'
# Expect: real LLM response (not "[Mock]..."), ~40-60s
```

### Test all node runtimes
```bash
# Direct health check (clusters of 4-5 in parallel)
for node in LOCAL:<host> CONTABO:<host> PROD:<host> \
            OPTIQ:<host> SITE:<host> MONITOR:<host> \
            MAIL:<host> KAMIL-DEV:<host>; do
  name=${node%:*}
  ip=${node#*:}
  curl -sf --connect-timeout 5 "http://$ip:7000/health" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); \
      print(f'$name: boot={d.get(\"boot_phase\")} kernels={d.get(\"config_fingerprint\",{}).get(\"kernel_count\")}')" \
    || echo "$name: FAIL"
done
```

### Verify mesh on master node
```bash
curl -sf http://<host>:7000/health | python3 /tmp/list_mesh.py
# Expect: 6-7 Healthy nodes, 13 kernels each

### Post-deploy scripts (bundled)
Two companion scripts in `scripts/`:
- `scripts/list_mesh.py` — Pipe: `curl -sf http://<node>:7000/health | python3 scripts/list_mesh.py`
- `scripts/check_all_nodes.py` — Runs standalone: tests all 9 known nodes (LOCAL, CONTABO, PROD, OPTIQ, SITE, MONITOR, MAIL, KAMIL-DEV, SNOWAJ). Exits non-zero on any failure.
```
