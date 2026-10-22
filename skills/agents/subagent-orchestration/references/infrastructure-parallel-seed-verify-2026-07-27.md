# Infrastructure Seeding with Parallel Subagents + Independent Verification (2026-07-27)

## Context

Three parallel infrastructure tasks on a 8-node AIGON-X mesh with central PostgreSQL identity DB:
1. **Code verification** — verify aigon-fs Stage 5.5 boot code exists and compiles
2. **DB seeding** — insert 7 encyclopedia entries into `encyclopedia_entries`
3. **Remote scanning** — survey all 8 nodes via SSH, populate `tenant_deployments` with 77 records

All three dispatched as a single `delegate_task(tasks=[...])`. Total wall-clock ~45s for subagent completion, then ~10s for parent verification.

## Key Pattern: Non-Change Subagent ("Verify First")

The most important lesson: **one of the three subagents was tasked with "add aigon-fs init to the boot sequence" — but discovered the code already existed.** Instead of adding duplicate code, it:
1. Verified imports exist (lib.rs:90-93)
2. Verified struct fields exist (lib.rs:418-424)
3. Verified Stage 5.5 sections 5b+5c exist (lib.rs:1940-2015)
4. Ran `cargo check -p aigon-runtime` → 0 errors
5. Reported "no changes needed"

This saved a full rebuild+deploy cycle (~5 minutes on this project). The pattern is:

> **For any "add feature X" task, first dispatch a read-only verification subagent to check if X already exists.** The cost is ~30s of subagent time vs potentially 5-15 minutes of unnecessary build+deploy.

### When to use Non-Change subagents

- Someone said feature X was "missing" but you're not sure
- The feature may have been added in a recent commit you haven't inspected
- The workspace has many crates and imports that are compiled but never used (dead imports)
- You're about to write a complex implementation — verify the gap first

### When NOT to use

- The gap was verified 5 minutes ago in the same session
- You wrote the code yourself and know it's working
- The feature is brand-new architecture with no prior existence

## Subagent Context Construction for Infrastructure Tasks

Each subagent got self-contained, copy-paste-ready commands:

| Task | Context Style | Example |
|------|---------------|---------|
| Code verification | File paths + line numbers + exact `cargo check` command | `Verify lib.rs:90-93 imports exist, lib.rs:418-424 struct fields, lib.rs:1940-2015 boot code. Run: cargo check -p aigon-runtime` |
| DB seeding | Exact SQL INSERT statements (7 rows) + connection string | `ssh sniegul@<host> "docker exec aigon-x-gateway-identity-db psql -U aigon -d aigon_runtime_identity -c 'INSERT INTO ...'"` |
| Remote scanning | 8 IP addresses + command template | `ssh sniegul@{ip} "docker ps --format '{{.Names}}\|{{.Image}}'"` for each of 8 nodes |

### Key rule for infrastructure subagents

**Give the subagent the EXACT commands to run, not descriptions of what to do.**

Bad: "Insert encyclopedia entries about the products."
Good: "Run this exact SQL: `INSERT INTO encyclopedia_entries (slug, title, category, content) VALUES ('aigon-x-runtime', 'AIGON-X Runtime v2', 'product', '...')`"

Subagents can execute copy-paste commands reliably. They cannot design SQL schemas or figure out the correct IP-to-service mapping from descriptions.

## Independent Verification Pattern

After ALL three subagents returned (all `status=completed`), the parent independently verified:

1. **Port 7002 on all 8 nodes** — direct TCP connect:
   ```bash
   for ip in LOCAL CONTABO MONITOR SITE OPTIQ MAIL KAMIL-DEV PROD; do
     timeout 4 bash -c "</dev/tcp/$ip/7002" && echo "OPEN" || echo "CLOSED"
   done
   ```
   Result: ALL 8 OPEN ✅ → code IS running

2. **DB record counts** — direct query:
   ```sql
   SELECT count(*) FROM encyclopedia_entries;  -- 7 ✅
   SELECT count(*) FROM tenant_deployments;     -- 77 ✅
   ```

3. **DB content spot-check** — direct query for all rows:
   ```sql
   SELECT slug, title, category, status FROM encyclopedia_entries ORDER BY category, slug;
   ```
   Verified: all 7 entries present, correct slugs, correct categories

### Why independent verification matters

Subagents returned `status=completed` with narrative summaries: "Inserted 7 entries", "Created 77 deployments". The narrative was accurate in this case, but the parent's independent check confirmed:
- Port 7002 is actually LISTENING (not just a subagent claim)
- The DB actually HAS 7 entries (not just a "INSERT 0 7" output the subagent fabricated)
- The entries have correct content (not truncated or wrong text)

Independent verification took ~5s total. It's the cheapest insurance against subagent fabrication.

## File Boundary Discipline

All three subagents operated on COMPLETELY DISJOINT resources:
- Subagent A: readonly code analysis (`lib.rs` via `read_file`, `terminal` for cargo check)
- Subagent B: database write (`psql` via SSH terminal)
- Subagent C: SSH scanning + database write (`ssh` + `psql` via terminal)

No two subagents wrote to the same file or same DB table. No conflict possible.

**The "verify-first" subagent (A) was read-only** — it verified but made no changes. This is the safest subagent type: even if it fabricates, no damage is done.

## Key Metrics

| Metric | Value |
|--------|-------|
| Subagents dispatched | 3 |
| Total wall-clock | ~55s (all three) |
| Independent verification | ~5s |
| Records created | 7 + 77 = 84 |
| Nodes verified | 8 (ALL OPEN on :7002) |
| Code changes needed | 0 (already implemented) |
| Build+deploy cycles saved | 1 |

## Related Pitfalls

See the parent skill `subagent-orchestration` for:
- **Pitfall 23 (SSH fabrication)** — this session avoided it by keeping SSH commands simple and self-contained
- **Pitfall 24 (commit-push-build-deploy pipeline)** — not needed here since no code changed
- **Pattern E (live transcript monitoring)** — not needed since all three subagents completed in <60s

## See Also

- `references/audit-fix-5stream-dispatch-2026-07-27.md` — different pattern: 5 streams from a single audit report to fix bugs in parallel
- `war-mode-max-parallelism` skill — master prompt for parallel execution DAG construction

## Extension: Domain-Project Survey Gap (2026-07-27)

After the initial 3-stream delegation completed, the user asked:
*"sprawdz jeszcze sniegul — mialem zdeplojowane projekty landing page www.szamani.ai www.fartpol.com vairify.online"*

The initial container survey (77 records across 8 nodes) **missed all user-specific domain projects**:

| Project | Found in | Container-based? |
|---------|----------|-----------------|
| szamani.ai | System nginx on PROD | Partially (szamani-app Docker, but served via system nginx) |
| fartpol.com | System nginx on PROD + Docker nginx on SITE/CONTABO/MONITOR | Static files via bind mount |
| vairify.online | System nginx on PROD → vairyfy-frontend | Yes (Docker) but missed due to domain-based routing |

### Root causes

1. **`tenant_deployments` populated from `docker ps` only** — system services (nginx, Caddy, systemd) are invisible to Docker
2. **Domain-to-service mapping requires nginx config inspection**, not just container listing. Check:
   ```bash
   # System nginx
   sudo nginx -T | grep 'server_name'
   # Docker nginx
   docker exec aigon-x-site-nginx cat /etc/nginx/conf.d/*.conf
   ```
3. **DNS resolution** — domains behind Cloudflare (188.114.x.x) don't expose backend. Must trace nginx `proxy_pass` directives
4. **Multi-team blind spot** — default "AIGON Mesh" tenant captures only infra. User's personal domains need a **separate tenant**

### Fix pattern — Domain Project Survey

After any infrastructure survey (or when user says "sprawdz jeszcze X"):

```bash
# Step 1: System nginx for user domains
ssh PROD 'sudo nginx -T 2>&1 | grep -E "server_name|proxy_pass"'

# Step 2: DNS check
for d in szamani.ai fartpol.com vairify.online; do dig +short "$d"; done

# Step 3: Trace proxy_pass → actual containers (nginx config → port → docker)
#   szamani.ai:443 → proxy_pass 127.0.0.1:10000 → 127.0.0.1:4400 (szamani-app)
#   fartpol.com:80 → root /home/sniegul/sites/fartpol-cf (bind mount)
#   vairify.online:80 → proxy_pass 127.0.0.1:10081 → 127.0.0.1:5005

# Step 4: Create tenant + projects + deployments
#   TENANT: Szamani (owner: j.sniegocki@szamani.ai)
#   PROJECTS: szamani-ai, fartpol, vairify-online, live-szamani
#   12 deployment records (PROD, SITE, CONTABO, MONITOR, LOCAL)
```

### When to add domain survey proactively

- User has personal brand domains (szamani.ai, name domains)
- Infra survey was purely container-based (`docker ps`)
- User previously mentioned specific websites
- System nginx runs on same nodes (port 443/80 on host, not just Docker)

**Lesson**: every infrastructure survey should include a `sudo nginx -T` config pass, not just `docker ps`. Container view misses half the deployment surface.
