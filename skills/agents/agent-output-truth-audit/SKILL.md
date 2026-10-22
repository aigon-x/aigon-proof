---
name: agent-output-truth-audit
description: Verify that an autonomous agent's self-reported output (DB success flags, submission/bid IDs, revenue rows) corresponds to REAL external confirmations — catches the "149 submissions, 62 bids, all success=1, yet zero platform confirmations and zero revenue" class of false green. Includes container exit-code forensics and compose-vs-running env drift checks.
---


# Agent Output Truth Audit

**Applies to:** Any autonomous monetization/production agent (MONAI Job, bounty
hunters, bid/submit bots) whose DB rows claim success. The agent's OWN database
is a SELF-REPORT — never treat its `success=1` flags as proof of delivery.

## The Core Question

> Are the numbers in the DB *attempts* (recorded locally, optimistic) or
> *confirmations* (acknowledged by an external platform / API / wallet)?

A row written "success=True" BEFORE the external call, with the confirmation
handle backfilled only AFTER the platform responds, is optimistic bookkeeping.
If the backfill never happened, nothing was delivered — no matter what the flag says.

## First-Rule Queries (the truth handles)

```bash
DB="docker exec <db-container> psql -U <user> -d <db> -t -c"

# Bids: real confirmations carry a platform-issued id
$DB "SELECT count(*) FROM <bids> WHERE bid_id IS NULL OR bid_id='';"
$DB "SELECT count(*) FROM <bids> WHERE bid_id IS NOT NULL AND bid_id<>'';"

# Submissions: filter out internal gate records (e.g. submission_id LIKE 'QS=%'
# are final-gate passes, NOT platform ids)
$DB "SELECT count(*) FROM <submissions> WHERE success=1 AND submission_id NOT LIKE 'QS=%';"
```

Interpretation: rows > 0 but confirmation-handle counts = 0 → the loop builds /
passes internal gates but delivers NOTHING. Do not debug the build pipeline —
debug the submission path (env flags, API creds, submitter errors).

Corroborate with logs; real confirmations leave traces:

```bash
docker logs <agent-container> 2>&1 | grep -E "confirmed|bid_id=.*saved|submission_id"
# empty + all handles NULL in DB = zero external round-trips ever succeeded
```

Check the financial ledger the same way: group transactions by type — only
`expense` rows (no `revenue`) means burning money, not earning, regardless of
how many "submissions" the DB shows.

## Env Drift: compose/repo files are NOT proof of running config

Classic trap: `docker-compose.prod.yml` declares `AUTO_SUBMIT=true` while the
RUNNING container has `AUTO_SUBMIT=false` (started from a different env source)
→ agent in permanent dry-run while the repo screams "live". Always trust the
container, not the file:

```bash
docker inspect <agent-container> --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E "AUTO_SUBMIT|ENABLED_PLATFORMS|ENABLED|DRY_RUN|_MODEL|API_KEY"   # keys only; never print secrets
grep -E "AUTO_SUBMIT|ENABLED_PLATFORMS" docker/docker-compose*.yml            # compare!
```

`false` on the live container explains gated "submissions" that never left.
Also check which model the agent is configured to call — after a model
migration the agent's env often still points at the retired model.

## Container Stopped: exit-code forensics

```bash
docker inspect <agent-container> --format \
'ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}} Error={{.State.Error}} RestartPolicy={{.HostConfig.RestartPolicy.Name}} RestartCount={{.RestartCount}} StartedAt={{.State.StartedAt}} FinishedAt={{.State.FinishedAt}}'
```

- `Exit 137` + `OOMKilled=false` + `RestartCount=0` + policy `unless-stopped` →
  **consciously killed** (`docker kill`/`stop`), not crash-looping. It will not
  self-heal.
- `FinishedAt − StartedAt` short and last log line ≈ `FinishedAt` → died mid-work.
- No `dmesg -T | grep -i oom` hits + no `journalctl -u docker` around FinishedAt
  → external kill, not resource death.

Check whether ANY watcher exists before assuming self-heal:

```bash
crontab -l 2>/dev/null | grep -i <agent>
sudo -n crontab -l 2>/dev/null | grep -i <agent>
systemctl list-timers 2>/dev/null | grep -iE "<agent>|watch"
ps aux | grep -iE "<agent>-watch|operational-loop" | grep -v grep
```

Dashboard/sidecar containers dying with `Exited (3)` + "address already in use"
are usually port conflicts with a previous instance — check `ss -tlnp` for the
port before assuming the app is broken.

## Verify the hardware story (did it use the GPU?)

```bash
nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total --format=csv
curl -s http://127.0.0.1:11434/api/ps | python3 -m json.tool   # loaded models + keep-alive
docker logs <agent-container> 2>&1 | grep -E "chat/completions.*200"
# + line like: Runtime (...) response: NNNN chars → GPU inference really served the loop
```

- `expires_at` far future (e.g. 2318-12-18) in `/api/ps` = keep-alive pinned
  forever → VRAM stays reserved when idle; a second large model won't fit.
- `utilization.gpu 0%` + VRAM full → model resident but nothing computing
  (agent dead or idle).
- Mesh-wide accelerator truth: `mcp__aigon_code__mesh_node_audit` (or equivalent
  gossip API) shows per-node `gpu_count`/`gpu_vram_gb` — often exactly ONE GPU
  exists in the whole mesh; "GPU cluster" claims need that audit, not vibes.

## Worked Example

2026-09-07, MONAI Job on local-aigon: DB showed 149 submissions + 62 bids, all
successful. Truth audit: 0 bids had `bid_id`, submissions were `QS=.. (FG-ALLOW)`
gate records, transactions were 263× expense (-2.63 USD) with 0 revenue. Root
causes: running container had `MONAI_AUTO_SUBMIT=false` (compose said true), and
monai-autonomous had been SIGKILLed 21h earlier (Exit 137, RestartCount=0, no
watchdog). Full numbers + queries: `references/platform-confirmation-audit.md`.

## Full Recipe

See `references/platform-confirmation-audit.md` for the complete field-by-field
breakdown and the exact case transcript.
