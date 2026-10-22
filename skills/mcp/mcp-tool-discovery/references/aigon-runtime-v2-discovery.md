# Real-World Example: AIGON-X Runtime v2

Applied the MCP Tool Discovery methodology to `<workspace>/runtime/`.

## Architecture

The runtime uses a **Universal Capability Bus (UCB)** — tools are `CapabilityInfo` structs registered via `impl Adapter` implementations, not `.tool()` calls.

## Phase 1 Results (standard patterns)

All four standard patterns returned **zero results** — confirming non-standard architecture.

## Phase 2+3 Results

### A. MCP Protocol Adapter
**File:** `crates/aigon-ucb/src/mcp_adapter.rs`

| Capability | Name | Line |
|---|---|---|
| `mcp::list_tools` | List MCP Tools | 79-92 (new), 165-178 (with_tools) |
| `mcp::call_tool` | Call MCP Tool | 94-107 (new), 230-243 (with_tools) |
| `mcp::get_tool_info` | Get MCP Tool Info | 109-122 (new), 185-198 (with_tools) |
| `mcp::tool::{name}` | MCP Tool: {name} (dynamic) | 206-227 (with_tools) |

### B. HTTP Static Tool Registry
**File:** `crates/aigon-runtime/src/api.rs` lines 86-99

`code_analyze`, `code_generate`, `code_review`, `code_fix`, `test_run`, `project_info`, `knowledge_search`, `deploy_docker`

### C. Galileo-Kernel-Routed Capabilities
**File:** `crates/aigon-runtime/src/api.rs` lines 3063-3079

15 `code__*` capabilities: review, architecture, security, refactor, bugs, perf, test, docs, bench, deps, migrate, plan, rca, quality, canon

### D. HTTP Route Tool Proxies
**File:** `crates/aigon-runtime/src/api.rs`

| Route | Handler |
|---|---|
| POST `/api/v1/code/{tool}` | handle_capability_call |
| POST `/api/v1/capabilities/{domain}/{name}` | handle_capability_call |
| GET/POST `/api/v1/project` | handle_generic_tool / handle_generic_tool_get |
| POST `/api/v1/gtm/{capability}` | handle_gtm_call |

### E. UCB Adapter Capabilities

| File | Adapter | Capabilities |
|---|---|---|
| `crates/aigon-ucb/src/aig_adapter.rs` | AigAdapter | aig::observe, aig::decide, aig::act, aig::learn, aig::remember |
| `crates/aigon-ucb/src/rest_adapter.rs` | RestAdapter | rest::get_api_items, post_api_items, get_api_items_id, delete_api_items_id |
| `crates/aigon-adapters/src/cfi/forensics_tool.rs` | ForensicsToolProvider | forensics::file_info, strings_analysis, carve_files |
| `crates/aigon-adapters/src/messaging/signal.rs` | SignalProvider | signal::send, signal::receive, signal::health |
| `crates/aigon-adapters/src/messaging/discord.rs` | DiscordProvider | discord::send_message, get_messages, get_gateway |
| `crates/aigon-adapters/src/mesh/tailscale.rs` | TailscaleProvider | tailscale::list_devices, connect, auth_keys |
| `crates/aigon-adapters/src/mesh/maips.rs` | MaipsProvider | maips::send, maips::receive, maips::route, maips::health |

### F. Registration Infrastructure

| Method | File | Purpose |
|---|---|---|
| `GtmEngine::register_capability()` | `crates/aigon-engines/src/gtm.rs:183` | GTM capability registration |
| `MaipsBridge::register_capability()` | `crates/aigon-mesh/src/maips_bridge.rs:192` | MAIPS route registration |
| `UniversalCapabilityBus::register()` | `crates/aigon-ucb/src/bus.rs` | Full adapter registration |

## Total: ~56+ capability/tool registrations found
