---
name: governance-bypass-audit
description: Detect and fix governance bypasses in Rust HTTP routes — replace code-level bypass with policies.json governance rules (project)
source: auto-skill
extracted_at: '2026-06-29T13:03:00.438Z'
---


# Governance Bypass Audit — Code → Policies.json

## Problem

Rust HTTP router (`main_router.rs`) has hardcoded bypass lists where certain path prefixes (`/mcp/`, `/sse`, `/health`, `/api/info`) skip governance verification entirely. This creates a **dual source of truth**: governance thinks it controls all access, but code silently allows bypass.

## Audit method

### 1. Find ALL governance bypass paths

```bash
grep -n "path.starts_with\|is_public\|skip_governance\|no_governance\|without_governance" \
  <workspace>/runtime/crates/aigon-runtime/src/routes/main_router.rs | head -30
```

Read the bypass condition. Example from `main_router.rs:104`:

```rust
// Current bypass list
!path.starts_with("/mcp/")
&& !path.starts_with("/sse")
&& !path.starts_with("/health")
```

### 2. Categorize each bypass

| Category | Action | Example |
|----------|--------|---------|
| **Liveness/readiness** | Safe to keep — no state mutation | `/health`, `/live`, `/ready` |
| **Streaming** | Move to governance with allow policy | `/sse`, `/mcp/` |
| **Public API** | Must have auth + governance | `/api/models` |

### 3. Remove from code, add to policies.json

**Code change:** Remove bypassed paths from the `if` condition:

```rust
// BEFORE — bypasses governance for /mcp/, /sse
if !path.starts_with("/mcp/") 
    && !path.starts_with("/sse") 
    && !path.starts_with("/health") { ... govern... }

// AFTER — only liveness/startup bypasses
if !path.starts_with("/health") 
    && !path.starts_with("/live") 
    && !path.starts_with("/ready") { ... govern... }
```

**Policies.json** — add allow rules for streaming/MCP:

```json
{
    "ref_": { "id": "policy:mcp-sse-allow" },
    "rules": [
        {
            "AllowVerb": {
                "verb": "Execute",
                "selector_pattern": "/sse/**",
                "reason": "MCP SSE streaming — allowed for authenticated MCP clients"
            }
        },
        {
            "AllowVerb": {
                "verb": "Execute",
                "selector_pattern": "/mcp/**",
                "reason": "MCP protocol endpoints — allowed for authenticated clients"
            }
        }
    ]
}
```

### 4. Verify governance enforcement

```bash
# Should return 403 (governance denied) without proper auth
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:14500/mcp/message

# Should return 200 with proper auth + governance
curl -s -o /dev/null -w "%{http_code}" -H "X-API-Key: $KEY" \
  -X POST http://localhost:14500/mcp/message -d '{"jsonrpc":"2.0","method":"ping","id":1}'
```

## Zero bypass rule

**ZERO bypassów w kodzie. Wszystko przez governance, a governance decyduje co jest dozwolone przez policies.json.** Kod nie podejmuje decyzji o tym, co jest dozwolone. Kod tylko egzekwuje polityki.

## Key files

- `<workspace>/runtime/crates/aigon-runtime/src/routes/main_router.rs` — governance bypass list
- `<workspace>/data/policies.json` — governance policies (allow/deny rules)
