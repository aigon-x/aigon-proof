# Runtime Prove Cache Snapshot Fix — Parallel 3-Agent Dispatch

## Date: 2026-07-28
## Pattern: "wszystko równolegle"

## Context

The AIGON Runtime v2 had 4 independent issues:
1. **Prove endpoints deadlocked** — `runtime.read().await` blocked by tick loop's `runtime.write()`
2. **DB heartbeat failed** — `password authentication failed for user "aigon"` every tick
3. **Only 3/36 components registered** — `self/components` showed 3 when 17 structs existed
4. **Docker healthcheck timed out** — `localhost` resolved to IPv6 `::1`

## What Happened

The user was presented with 4 sequential options (1. Fix DB, 2. Instrument prove, 3. Register missing components, 4. Fix localhost). Response: **"wszystko równolegle"** — do all in parallel.

## Parallel Dispatch

3 subagents dispatched via single `delegate_task(tasks=[...])` call:

| Subagent | Goal | Result |
|----------|------|--------|
| **Prove fix** | Add `component_snapshot` to ApiState, replace `runtime.read()` in prove handlers + `self/components` with cached snapshot | `cargo check` passed, handlers now return data without blocking |
| **DB fix** | Reset PostgreSQL password, update `.env` + `docker-compose.yml` + `node-local.yaml` with DATABASE_URL | 0 password errors in logs, container healthy |
| **Component registry** | Investigate why 3/36 show | Root cause: `self/components` timed out due to `runtime.read()` deadlock — all 17 actually registered in `setup_components()` |

### Parent-side work (while subagents ran)

- Fixed Docker healthcheck: `localhost` → `127.0.0.1` (IPv6 resolution timeout)
- Built release binary + Docker image
- Deployed and verified all endpoints live

## Key Technical Pattern

### Cached Snapshot for Lock-Free API Handlers

```rust
// ApiState field
pub component_snapshot: Arc<Mutex<Value>>,

// Background loop update (every 500ms, 200ms timeout for read lock)
let comp = state.runtime.clone();
let cs = state.component_snapshot.clone();
tokio::spawn(async move {
    let result = tokio::time::timeout(Duration::from_millis(200), async {
        let rt = comp.read().await;
        let reg = rt.component_registry.lock().await;
        let all = reg.all().clone();
        json!({ "components": ..., "count": all.len() })
    }).await;
    if let Ok(snapshot) = result {
        *cs.lock().await = snapshot;
    }
});

// Handler reads from cache — NEVER from runtime.read()
async fn prove_runtime(State(state): State<ApiState>) -> Json<Value> {
    let snapshot = state.component_snapshot.lock().await;
    Json(snapshot.clone())
}
```

### Docker Healthcheck IPv6 Fix

```
# BEFORE — times out on IPv6-capable systems
test: ["CMD", "curl", "-sf", "http://localhost:7000/health"]

# AFTER — forces IPv4
test: ["CMD", "curl", "-sf", "http://127.0.0.1:7000/health"]
```

### Verification (post-deploy)

All endpoints verified live from host IP:
- `/health` — healthy, 16/16 kernels
- `/api/v1/prove/runtime` — 36 components, 4 health issues (provider gaps)
- `/api/v1/self/components` — ALL 36 components with consumes/produces graph
- `/prove/pipeline` — pipeline chain with 36 entries
- DB heartbeat errors: **0**

## Files Changed

- `crates/aigon-runtime/src/api.rs` — cached component_snapshot (8 patches by subagent)
- `config/node-local.yaml` — DB password fix
- `docker-compose.yml` — DATABASE_URL env var + healthcheck localhost→127.0.0.1
- `.env` — DATABASE_URL password
