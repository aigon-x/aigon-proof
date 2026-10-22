# Pillar/Wave Orchestration Pattern — AIGON-X (2026-07-16)

Real transcript from a session where 37 tasks across 6 pillars were completed in ~30 minutes using 3-wave parallel subagent dispatching. 146h estimated → ~30min on mesh (28 workers, 3 concurrent subagents).

## Pattern Overview

```
Phase 1: Create Pillar-Based Task Plan
  → Analyze CANON + live DB + source audit
  → Organize by 6 Pillars (Engineering, AI&I, Infrastructure, Ops, Security, Delivery)
  → Group into Waves by dependency: Wave 0 (prereqs) → Wave 1 (independent) → Wave 2 (depends) → Wave 3 (integration)

Phase 2: Dispatch Waves in Max-Parallelism Batches
  → Each batch: 3 subagents (max_concurrent_children)
  → All tasks in same Wave are independent — dispatch simultaneously
  → Continue dispatching subsequent batches while previous run
  → Do NOT wait for batch N to finish before dispatching batch N+1

Phase 3: Verify Each Batch Independently
  → Don't trust subagent status=completed — verify with cargo check / tsc / DB queries
  → Report per-task status to user

Phase 4: Repeat for Next Wave
  → Wave 1 depends on Wave 0, Wave 2 depends on Wave 1
  → Integration wave (Wave 3) at end
```

## Task Plan Format

```
# <PILLAR NAME> (<domains>)
| Task ID | Task | Dependencies | Effort | Wave | Parallel Group |
|---------|------|-------------|--------|------|---------------|
```

## Key Numbers
- 37 tasks, 6 pillars, 3 waves
- 146h estimated → ~30min wall-clock
- 12 kernels (was 8), learning pipeline wired
- CPU: 14+12=26 cores, RAM: 49+47=96GB across mesh
- 15 files, 769 insertions final commit

## Mesh Deployment (Docker-only, per CANON)

```bash
cargo build --release && cp target/release/aigon-runtime-v2 prebuilt/
docker build -t aigon-runtime-v2:latest -f Dockerfile .
docker save aigon-runtime-v2:latest -o /tmp/aigon-runtime-v2.tar
scp /tmp/aigon-runtime-v2.tar root@<node>:/tmp/
ssh root@<node> 'docker load -i /tmp/aigon-runtime-v2.tar'
ssh root@<node> 'docker stop <container> && docker rm <container>'
ssh root@<node> 'docker run -d --name <container> --network host <image> <args>'
```

Run on prod-aigon (mesh-master) and gateway (mesh-worker). Gateway needs `--mode mesh-worker` and optional `--config /etc/aigon/config.yaml` with `mesh_peers`.

## Learning Pipeline Verification (post-deploy)

| Kernel | Check | Expected |
|--------|-------|----------|
| freud | session_count > 0 | Learning happening |
| galileo | total_reviews > 0 | Auto-review per tick |
| hawking | facts > 0 | Facts extracted |
| knowledge | fact_count > 0 | Verified facts |
| planck | planned/completed > 0 | Planning active |
| nash | decisions_made > 0 | Strategic decisions |
| sensor | cpu_load, memory_mb | Real /proc/stat |
| yudai | 8/8 compliance rules | All passing |

## Encyclopedia Pillar Audit

1. Read ENCYCLOPEDIA.md sections by grep `^##`
2. Cross-reference: 6 pillars + 12 kernels
3. Identify gaps: missing sections, stale counts
4. Add new sections before Glossary, renumber
5. Each: 100-200 words, factual descriptions

## GTM Landing Page Workflow

1. Read GTM plan: `runtime-v2/reports/003-GTM-CAMPAIGN.md`
2. Target personas: CTO, VP Platform, Enterprise Architect, CISO
3. Value props: single-binary, air-gap, infinite scale, zero external API
4. Build single HTML page: Hero, Comparison, 6 Pillars, Architecture, Pricing, docs subpages, CTA
5. No emoji — inline SVG icons
6. Deploy: scp → nginx on prod-aigon → Cloudflare tunnel DNS

## Key Lessons

1. **Check what the API actually returns** before building filters — DB IDs may differ from API response fields
2. **Pre-flight task plan** with subagent that has CANON audit context
3. **Commit between waves** to avoid accumulating uncommitted changes
4. **Never dispatch two subagents to same file** — structural corruption
5. **User expects: "nie pytaj, maksymalnie rownolegle do ukonczenia zadania"** — dispatch, don't ask
6. **When local backend fails**: check `ps aux | grep aigon-code-server`, `docker ps`, `.aigon/wallet.json`, `.aigon/settings.json`
7. **When login fails**: check password hash in DB, generate proper bcrypt hash via `cargo run --example`, verify with backend's own auth module
8. **Cloudflare tunnel DNS** adds to wrong zone if tunnel account has different zone — use CF API directly with zone ID and DNS token
