---
name: mcp-bridge-gateway-connection-fix
description: Fix MCP bridge/gateway connection failures — API key auth, SSE streaming, concurrent server startup, Docker DNS networking
source: auto-skill
extracted_at: '2026-06-18T21:56:49.189Z'
---


# MCP Bridge / Gateway Connection Fix

Fix an MCP bridge (MCP Gateway) that cannot connect to local or remote MCP servers. Covers the four most common failure modes:

1. **API key missing** — client sends HTTP requests without `X-API-Key` header
2. **SSE streaming blocking** — `response.text().await` blocks forever on persistent SSE streams
3. **Server startup before connections** — health endpoint unavailable while connections are pending
4. **Docker DNS vs localhost** — container cannot reach host service via `localhost`

## Diagnostics

Check the MCP bridge logs for the error pattern:

```
WARN Failed to connect ... error=SSE discovery failed: error sending request for url
WARN Failed to initialize ... error=Request failed: error sending request for url
```

Also check:
```
curl -sf http://localhost:PORT/health   # fails or returns empty
docker logs aigon-x-router --tail 20
```

## Fix 1: API Key Missing

**Problem:** `McpServerConnection::send_request()` sends HTTP requests without `X-API-Key` header. The runtime requires this header.

**Fix:** Add `api_key: Option<String>` field and set it as a default header on the HTTP client builder.

```rust
struct McpServerConnection {
    config: McpServerConfig,
    client: HttpClient,
    api_key: Option<String>,
    // ... other fields
}

impl McpServerConnection {
    fn new(config: McpServerConfig, api_key: Option<String>) -> Self {
        let mut builder = HttpClient::builder()
            .timeout(Duration::from_secs(
                if config.timeout_secs > 0 { config.timeout_secs } else { 30 },
            ));
        if let Some(ref key) = api_key {
            let mut headers = reqwest::header::HeaderMap::new();
            headers.insert(
                "X-API-Key",
                reqwest::header::HeaderValue::from_str(key)
                    .expect("Invalid API key header value"),
            );
            builder = builder.default_headers(headers);
        }
        let client = builder.build().expect("Failed to build HTTP client");
        // ...
    }
}
```

Read API key from env var:
```rust
let api_key = std::env::var("API_KEY")
    .or_else(|_| std::env::var("AIGON_API_KEY"))
    .ok();
```

## Fix 2: SSE Streaming Read

**Problem:** SSE endpoints send a persistent stream that never closes. `response.text().await` waits for the END of stream, which never comes — blocks forever.

**Fix:** Read the SSE response as a streaming `bytes_stream()` instead.

```rust
use futures::StreamExt;

async fn connect(&self) -> Result<(), String> {
    let sse_url = format!("{}/sse", self.config.url.trim_end_matches('/'));
    let response = self.client.get(&sse_url)
        .header("Accept", "text/event-stream")
        .send().await
        .map_err(|e| format!("SSE discovery failed: {}", e))?;

    let mut stream = response.bytes_stream();
    let mut buffer = String::new();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);

    loop {
        if std::time::Instant::now() > deadline {
            break;
        }
        let chunk = tokio::time::timeout(
            Duration::from_secs(1),
            stream.next(),
        ).await;
        match chunk {
            Ok(Some(Ok(chunk))) => {
                buffer.push_str(&String::from_utf8_lossy(&chunk));
                if buffer.contains("/mcp/message") {
                    // Found endpoint — success
                    return Ok(());
                }
            }
            Ok(Some(Err(e))) => return Err(format!("SSE stream error: {}", e)),
            Ok(None) => break,
            Err(_) => continue,
        }
    }
    Err("No endpoint event received from SSE".to_string())
}
```

## Fix 3: Server Startup Before Connections

**Problem:** The Axum/HTTP server starts AFTER `connect_all()` and `initialize_all()` complete. If remote gateways have 30s timeouts, the health endpoint is unavailable for 30+ seconds.

**Fix:** Start Axum server concurrently with connections via `tokio::spawn`.

```rust
pub async fn run_gateway(...) -> Result<(), Box<dyn std::error::Error>> {
    let registry = Arc::new(McpServerRegistry::new(configs, api_key));

    // Create Axum app FIRST
    let state = AppState { registry: registry.clone() };
    let app = Router::new()
        .route("/health", get(handle_health))
        .with_state(state)
        .layer(CorsLayer::permissive());

    let listener = TcpListener::bind(&addr).await?;

    // Spawn connections as background task
    let reg = registry.clone();
    tokio::spawn(async move {
        reg.connect_all().await;
        reg.initialize_all().await;
    });

    // Run server forever — health endpoint available immediately
    axum::serve(listener, app).await?;
    Ok(())
}
```

## Fix 4: Docker DNS vs Localhost

**Problem:** Container uses `http://localhost:PORT` to reach another container. `localhost` resolves to the container itself, not the host.

**Diagnosis:** Check the container's network mode:
```bash
docker inspect <container> --format '{{.HostConfig.NetworkMode}}'
```

- If output is `host` → container shares host networking → `localhost` reaches the host's services. Use `http://localhost:PORT`.
- If output is a bridge network (e.g. `aigon-x-net`) → use Docker service name `http://<service-name>:PORT`.

**When to use what:**

| Network Mode | Runtime URL | Why |
|-------------|-------------|-----|
| `host` | `http://localhost:14500` | Container shares host network — localhost = host |
| bridge (e.g. `aigon-x-net`) | `http://aigon-x-runtime:14500` | Docker DNS resolves service names on the same network |

**Fix:** Set the URL based on the container's network mode. For `host` mode:
```json
{
  "id": "aigon-x-runtime-local",
  "url": "http://localhost:14500",
  "enabled": true
}
```

For bridge mode, use the Docker service name:
```json
{
  "id": "aigon-x-runtime-local",
  "url": "http://aigon-x-runtime:14500",
  "enabled": true
}
```

Verify DNS resolution:
```bash
docker exec <container> curl -s http://<service-name>:<port>/sse
```

## Verification

After all fixes:

```bash
# Health endpoint must return immediately
curl -s http://localhost:17002/health

# Expected response:
# {"status":"healthy","servers_total":N,"servers_connected":M,...}

# Check for "Connected to MCP server" in logs
docker logs aigon-x-router | grep "Connected"
```

## Fix 6: Router Missing SSE Endpoint (remote connectivity)

**Problem:** Remote MCP bridges connect to each other at `http://{peer}:17002/sse`, but the aigon-x-router only exposes `/health`. Returns 404 on `/sse`, causing remote gateways to show `connected: false`.

**Root cause:** The aigon-x-router (MCP gateway binary) serves as an MCP *client* (connects TO MCP servers) but doesn't serve as an MCP *server* (no own SSE endpoint for incoming connections).

**Fix:** Add an `/sse` handler to the Axum server that proxies to the local runtime's SSE:

```rust
async fn handle_sse() -> Response<Body> {
    use axum::response::{Response, Body};
    use futures::stream::StreamExt;
    use reqwest::Client as HttpClient;

    let client = HttpClient::builder()
        .no_proxy()
        .build()
        .unwrap_or_else(|_| HttpClient::new());
    let api_key = std::env::var("AIGON_API_KEY")
        .or_else(|_| std::env::var("API_KEY"))
        .ok();
    let sse_url = "http://localhost:14500/sse";

    let mut req = client.get(sse_url).header("Accept", "text/event-stream");
    if let Some(ref key) = api_key {
        req = req.header("X-API-Key", key);
    }

    match req.send().await {
        Ok(upstream) if upstream.status().is_success() => {
            // Prepend MCP endpoint discovery event, then stream upstream events
            let prefix = Bytes::from("event: endpoint\ndata: /mcp/message\n\n");
            let upstream_stream = upstream.bytes_stream().map(|r| r.map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e)));
            let stream = futures::stream::once(async { Ok(prefix) }).chain(upstream_stream);
            
            Response::builder()
                .header("Content-Type", "text/event-stream")
                .header("Cache-Control", "no-cache")
                .header("Connection", "keep-alive")
                .header("X-Accel-Buffering", "no")
                .body(Body::from_stream(stream))
                .unwrap()
        }
        Ok(resp) => Response::builder()
            .status(502)
            .body(Body::from(format!("Upstream SSE error: HTTP {}", resp.status())))
            .unwrap(),
        Err(e) => Response::builder()
            .status(502)
            .body(Body::from(format!("Upstream connection failed: {}", e)))
            .unwrap(),
    }
}
```

Register the route:
```rust
.route("/sse", get(handle_sse))
```

**Verification:** After deploying, all remote MCP gateways should connect:
```bash
curl -s http://localhost:17002/sse | head -1
# Expected: event: endpoint
curl -s http://localhost:17002/health | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['servers_connected'])"
# Expected: > 1 (runtime + remote gateways)
```

**Important:** The SSE handler reads `AIGON_API_KEY` then falls back to `API_KEY` env var. Ensure at least one is set in the container environment. Also use `.no_proxy()` on the reqwest client to avoid proxy interference.

**Problem:** `reqwest::Client` respects system HTTP proxy settings by default. In Docker environments, `http_proxy` / `https_proxy` environment variables may be set (pointing to a proxy that doesn't exist or can't route internal traffic). This causes all requests to `localhost:PORT` or Docker DNS names to fail with `error sending request for url` — a generic transport error.

**Symptoms:**
- `curl -H "X-API-Key: ..." http://localhost:14500/sse` works (curl ignores proxy)
- `reqwest::Client` POST/PUT requests to the SAME URL fail with `Request failed: error sending request for url`
- No DNS resolution or timeout messages — just a generic transport failure

**Fix:** Add `.no_proxy()` to the reqwest client builder:

```rust
let client = reqwest::Client::builder()
    .no_proxy()                    // <-- ADD THIS
    .timeout(Duration::from_secs(30))
    .default_headers(headers)
    .build()
    .expect("Failed to build HTTP client");
```

**Where to apply:** Every `reqwest::Client::builder()` or `reqwest::blocking::Client::builder()` that makes requests to internal Docker services or localhost.

```rust
// Applies to both async and blocking clients
reqwest::Client::builder().no_proxy()...
reqwest::blocking::Client::builder().no_proxy()...
```

**Note:** `.no_proxy()` is safe in all environments — it only affects system proxy configuration, not network connectivity. It prevents the HTTP client from attempting to route internal traffic through an external HTTP proxy that doesn't understand AIGON-X internal APIs.
