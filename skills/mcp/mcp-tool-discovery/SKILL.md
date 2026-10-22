---
name: mcp-tool-discovery
title: MCP Tool Discovery
description: Systematically discover all MCP tool and capability registrations in an unfamiliar codebase, including non-standard patterns (UCB adapters, capability structs, route proxies). For LIVE probing of running MCP services, see runtime-live-probing.
tags: [mcp, tool-discovery, codebase-analysis, capability-mapping, rust]
---


# MCP Tool Discovery

Find every MCP tool/capability registration across a codebase, even when the project doesn't use standard `.tool()` or `register_tool()` patterns.

## When to Use

- A user asks "find ALL MCP tool registrations" in a project
- You need to map the full surface of exposed tools/capabilities
- Standard grep for `.tool(` or `register_tool(` returns nothing (signals a non-standard architecture)

## Systematic Discovery Pipeline

### Phase 1 — Probe for architecture type

Start broad to understand the registration pattern:

```
grep -rn '\.tool(' --include='*.rs'
grep -rn 'register_tool(' --include='*.rs'
grep -rn 'mcp::Tool' --include='*.rs'
grep -rn 'McpServer\|mcp_server\|ToolServer' --include='*.rs'
```

**If empty** → the codebase likely uses a capability/registry architecture (UCB, adapter pattern, middleware).

### Phase 2 — Discover the non-standard architecture

```
grep -rn 'CapabilityInfo\|CapabilityContract\|CapabilityMapping' --include='*.rs'
grep -rn 'ProtocolKind::Mcp\|ProtocolKind::' --include='*.rs'
grep -rn 'fn discover\|impl Adapter' --include='*.rs'
grep -rn 'mcp::tool::' --include='*.rs'
grep -rn 'KNOWN_TOOLS\|api_tools\|handle_capability' --include='*.rs'
```

### Phase 3 — Map all registration layers

Non-standard codebases register tools at **multiple layers** simultaneously:

| Layer | What to look for | Example files |
|---|---|---|
| **Protocol adapters** | `impl Adapter` + `CapabilityInfo` structs | `mcp_adapter.rs`, `aig_adapter.rs` |
| **Static tool lists** | Constants of `(name, desc, category)` tuples | `api.rs` `KNOWN_TOOLS` |
| **HTTP route proxies** | Route-to-tool handlers like `{tool}` or `{domain}/{name}` path params | `api.rs` router |
| **Static routing tables** | Arrays of capability IDs routed through inference engines | `CODE_CAPABILITIES` |
| **Adapter crates** | Separate crates in `adapters/src/` each with capability registrations | `forensics_tool.rs`, `signal.rs`, `discord.rs` |

### Phase 4 — Report structure

Group by category and include file + line number for every registration:

```
## A. {Architecture Layer}
**File:** `path/to/file.rs`

| Tool/Capability ID | Description | Handler | File:Line |
|---|---|---|---|
| `mcp::list_tools` | Enumerate tools | Adapter::invoke | file.rs:79 |
```

Also include:
- Total count found
- Registration infrastructure methods (e.g., `register_capability`, `register`)
- Test-level registrations (flag as test-only)

## Key Pitfalls

- **Don't stop after Phase 1.** Empty results from standard patterns just means the architecture is non-standard — iterate.
- **Route handlers as tools.** `POST /api/v1/code/{tool}` catch-all routes ARE tool registrations, just proxied through HTTP.
- **Adapter crates live separately.** Actual `CapabilityInfo` registrations may be in `crates/<adapter-name>/src/` not a central registry.
- **Dynamic capabilities.** Some adapters accept `Vec<(String, String)>` at construction — these are code-path dependent, not static.
- **Mock/test adapters.** Test files register mock capabilities — note them but include for completeness.
- **MCP servers may be stdio-based, not HTTP.** Some MCP servers (e.g., `aigon-x-code-mcp`) are stdio binaries inside Docker containers with no exposed TCP port. They communicate via JSON-RPC over stdin/stdout, not HTTP. To discover them: check container process list (`docker exec <container> cat /proc/1/cmdline`), look for binaries named `*-mcp` or `mcp-*`, and invoke with `--help` to enumerate capabilities. These won't appear in any port scan or HTTP endpoint probe.
- **Host-network containers hide ports.** Containers using `--network host` share the host network stack — `docker ps` shows no port mapping. Use `docker exec <container> cat /proc/net/tcp` to find listening ports from inside the container.

## Live Verification (vs codebase analysis)

## Verification

Spot-check:
1. Does `/api/tools` or `/api/v1/tools` match the static tool list found?
2. Do route handler patterns cover all the capability IDs listed?
3. Are all `impl Adapter` blocks accounted for (via `fn discover` + `fn capability_mapping`)?

## Live Verification (vs codebase analysis)

This skill focuses on codebase-level discovery. For live verification of running MCP services (HTTP or stdio), see **runtime-live-probing** which covers:
- Port scanning + endpoint probing (Phase 6)
- Docker container inspection for host-network containers
- Docker registry image/tag enumeration
- Comprehensive multi-service capability discovery

## Reference

See `references/aigon-runtime-v2-discovery.md` for a real-world example applying this methodology.
