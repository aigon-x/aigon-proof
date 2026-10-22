# Conflict-Free Parallel Edits to the Same File

## Problem

You need 4 subagents to modify different sections of the same file in parallel. If they use `write_file` (which overwrites the whole file) or `patch` on overlapping regions, the last one clobbers the others' work.

## Solution: Unique Section Marker Strategy

Each subagent targets a different, non-overlapping region of the file using `patch()` with a **unique section comment** as the `old_string` anchor.

### Requirement

The file must have **unique section comments** — easily recognizable markers that subagents can use as `old_string` anchors. Next.js/React files typically have these:

```tsx
{/* ─── 1. HERO ─── */}
{/* ─── 1b. TRUST BAR ─── */}
{/* ─── 2. WHY [PRODUCT] ─── */}
{/* ─── 3. HOW IT WORKS ─── */}
{/* ─── 4. ARCHITECTURE ─── */}
{/* ─── 5. DASHBOARD ─── */}
{/* ─── 6. WHAT X DOESN'T DO ─── */}
{/* ─── 7. FIVE VERDICTS ─── */}
{/* ─── 8. ANIMATED VERDICT ─── */}
{/* ─── 9. DEMO ─── */}
{/* ─── 10. PRICING ─── */}
{/* ─── 11. FAQ ─── */}
{/* ─── 12. CTA ─── */}
{/* ─── 13. FOOTER ─── */}
```

### Dispatch Pattern

| Subagent | Target | Anchor Marker | Action |
|----------|--------|--------------|--------|
| A | Hero/footer CTAs | `{/* ─── 1. HERO ─── */}` or unique link text | patch() specific link/button strings |
| B | Trust badges insertion | `{/* ─── 1b. TRUST BAR ─── */}` → `{/* ─── 2. WHY [PRODUCT] ─── */}` | Insert new section between two markers |
| C | Social proof insertion | `{/* ─── 6. WHAT X DOESN'T DO ─── */}` → `{/* ─── 7. FIVE VERDICTS ─── */}` | Insert between two markers |
| D | Performance callout | After architecture section marker | Insert after specific marker |

### Why This Works

1. Each subagent's `old_string` is unique to its target region
2. No two subagents modify the same line range
3. `patch()` always inserts at the exact anchor — order doesn't matter because anchors don't overlap
4. Build verification (`next build` or `tsc --noEmit`) at the end catches any issues

### Pitfalls

- If subagents use `write_file()` instead of `patch()`, they WILL conflict. Enforce `patch()` in task descriptions.
- Ensure the file has been read before dispatch so subagents have the current content in context.
- After all subagents complete, always rebuild the Docker image: `docker build -f frontend/Dockerfile -t [image:tag] frontend/` then restart the container.
- Verify via `browser_navigate` + `browser_console` — don't trust subagent summaries alone.
