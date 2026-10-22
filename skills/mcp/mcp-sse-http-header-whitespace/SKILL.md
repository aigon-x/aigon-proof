---
name: mcp-sse-http-header-whitespace
description: Fix HTTP response format strings with leading whitespace in headers causing RFC 7230 folding — breaks Content-Length and header/body separator
source: auto-skill
extracted_at: '2026-06-19T02:00:33.764Z'
---


# MCP SSE HTTP Header Whitespace — RFC 7230 Folding Bug

## Problem
HTTP POST requests to MCP message endpoints (or any custom HTTP handler) hang/timeout with 0 bytes received. The SSE GET endpoint works fine, but POST requests hang indefinitely.

Symptoms:
- `curl -X POST http://localhost:14500/mcp/message` → connects, sends data, but receives 0 bytes, eventually times out
- MCP gateway logs: `Failed to initialize server=... error=error sending request for url`
- Browser/curl waits for response until timeout
- Server log shows no errors or panics

## Root Cause
In HTTP/1.1 (RFC 7230 Section 3.2.4), header lines starting with **whitespace** (spaces or tabs) are treated as **folding continuation** of the previous header line. This causes two critical failures:

1. **No valid `\r\n\r\n` header/body separator** — a line with only whitespace followed by `\r\n` is treated as an empty continuation line, not a blank line. The response parser cannot find the header/body boundary.

2. **Content-Length mismatch** — `Content-Length` counts only the JSON body, but the server writes both the JSON body plus the mispositioned CORS/rate-limit headers after it. Clients expecting `Content-Length` bytes receive extra data, then the connection closes before the promised byte count is satisfied.

The typical broken format string looks like:
```rust
format!(
    "HTTP/1.1 200 OK\r\n\
     Content-Type: text/event-stream\r\n\
     ...\r\n\
     Content-Length: {}\r\n\
     \x20\x20\x20\x20\x20\x20\x20\x20\x20Access-Control-Allow-Origin: {origin}\r\n\
     \x20\x20\x20\x20\x20\x20\x20\x20\x20\r\n\
     {}",
     body.len(), body
)
```

The `\x20\x20\x20...` (spaces) before `Access-Control-Allow-Origin` and before the blank `\r\n` cause RFC 7230 folding.

## Detection
Check HTTP response format strings for leading whitespace on continuation lines:

```bash
grep -n '\\\\r\\\\n         [A-Z]' crates/*/src/**/*.rs 2>/dev/null
```

Or more broadly:
```bash
grep -n '\\\\r\\\\n  *[A-Z]' src/**/*.rs 2>/dev/null
```

This finds `\r\n` followed by spaces then a letter — the folding pattern.

## Fix
Remove ALL leading whitespace from header lines inside HTTP response format strings:

**Before (broken):**
```rust
"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n         Access-Control-Allow-Origin: {origin}\r\n         Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n         Access-Control-Allow-Headers: ...\r\n         \r\n{}"
```

**After (fixed):**
```rust
"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: {origin}\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: ...\r\n\r\n{}"
```

Key changes:
- `\r\n         Access` → `\r\nAccess` (no leading spaces)
- `\r\n         \r\n` → `\r\n\r\n` (proper header/body separator)

## Testing
After fix, verify with:
```bash
# POST should return immediately with proper response
curl -s -X POST http://localhost:14500/mcp/message \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"initialize","id":1}'

# Should return JSON with server capabilities
```

## Prevention
When building HTTP response format strings in Rust:
- Never indent header lines with spaces/tabs after `\r\n`
- The `\r\n` must be immediately followed by a header name or another `\r\n`
- Use a raw string with proper alignment:
  ```rust
  "HTTP/1.1 200 OK\r\n\
   Header-Name: value\r\n\
   \r\n\
   body"
  ```
  Each continuation line starts with zero indentation.
