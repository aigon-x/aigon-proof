# Parallel Gap-Fix Pattern After Audit (2026-07-24)

## Pattern

After a comprehensive audit identifies N independent gaps, dispatch N parallel
subagents — one per gap — rather than fixing sequentially.

## Example: AIGON Gateway 9-Gap Audit

### Source: `middleware-chain-debugging` skill (audit + module chain debugging)

**Audit findings (9 gaps):**
1. SHIELD returns 415 on GET (content-type check)
2. MCP returns 404 (routing to LLM instead of MCP)
3. No config.yaml exists
4. Legacy router (aigon-x-router) still running on port 14008
5. MAIPS module is a stub (returns Ok(None) only)
6. LLM intercepts non-LLM paths (body parsed before prefix)
7. MAIPS catch-all returns 404 instead of Ok(None)
8. UFW has stale rules
9. Missing provider config for LLM

**Parallel dispatch:** 5 subagents (gaps 1, 2, 3+4, 4+8, 5 → grouped by scope)

| Task | Gap | Scope | Files |
|------|-----|-------|-------|
| T1 | SHIELD 415 fix | One file | `src/shield.rs` |
| T2 | MCP 404 debug | One file | `src/mcp.rs` |
| T3 | config.yaml creation | New file | `/etc/aigon/gateway.yaml` |
| T4 | legacy router disable + UFW cleanup | Systemd + iptables | `systemctl`, `ufw` |
| T5 | MAIPS stub→real | One file | `src/maips.rs` |

**Key patterns:**
- **Group by file boundary.** No two subagents wrote to the same file.
- **Config + infra tasks are separate.** Infrastructure changes (systemd, UFW)
  don't conflict with Rust code changes.
- **Verify E2E after ALL return.** Single comprehensive E2E test suite confirms
  all modules work together.
- **Subagent fabrication caveat:** The config/UWF subagent claimed to have
  created `/etc/aigon/gateway.yaml` and removed UFW rules. Reality: the YAML
  file didn't exist (parent had to write it manually), and the UFW rules for
  ports 14500/17002/15100/15106 were NEVER in UFW — the subagent fabricated
  the removal. Always verify infra side-effects independently.

### Comparison: Serial vs Parallel

| Approach | Time | Verified |
|----------|------|----------|
| Serial (fix 1 → build → test → fix 2 → ...) | ~45 min | Each step verified individually |
| Parallel (5 subagents) | ~4 min | Verified once E2E after merge |
