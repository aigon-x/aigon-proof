# MONAI Job False-Green Autopsy — 2026-09-07 (local-aigon)

## Symptom / Claim
User asked: "jak wyglada stan akceleratorow? wykorzystujemy juz gpu?
wyslalismy kolejne? jak status projektu monai? zarabiamy juz pieniadze?"

DB suggested heavy activity: 149 submissions, 62 bids, jobs table full.
Surface reading of `autonomous-agent-loop-diagnostics` checklist would say
"agent working". Truth: ZERO external confirmations, ZERO revenue, agent
SIGKILLed 21h earlier, auto-submit disabled in the RUNNING container.

## Evidence chain

### 1. Containers
```
monai-autonomous   Exited (137) 21 hours ago
monai-api          Up 27 hours (healthy)
monai-dashboard    Exited (3) 43 hours ago     # "address already in use" :3009
monai-db           Up 27 hours (healthy)       127.0.0.1:5434->5432/tcp
```

### 2. Submission "success" was a gate record, not a platform id
```sql
SELECT submission_id FROM submissions WHERE submission_id LIKE 'QS=%' LIMIT 3;
-- QS=95.0 (FG-ALLOW)
-- QS=95.0 (FG-ALLOW)
-- QS=57.0 (FG-ALLOW)
-- 141 of 149 submissions match QS=% pattern; ALL 149 had success=0
```

### 3. Bids recorded optimistic, never confirmed
```sql
SELECT count(*) FROM bids WHERE bid_id IS NULL OR bid_id='';        -- 62
SELECT count(*) FROM bids WHERE bid_id IS NOT NULL AND bid_id<>'';  -- 0
```
Code path (bidder/engine.py ~line 342): `BidModel(success=True, ...)` is
inserted BEFORE the platform API call; `bid_id` backfilled only after
`FreelancerSubmitter.submit_proposal()` returns a confirmation id. Log grep
for `bid confirmed|bid_id=.*saved` → empty.

### 4. Env drift — compose said live, container said dry-run
docker-compose.prod.yml line 44: `MONAI_AUTO_SUBMIT=true`
Running container (`docker inspect ... .Config.Env`):
```
MONAI_ENABLED_PLATFORMS=["github_bounty","freelancer"]
MONAI_AUTO_SUBMIT=false          # <-- actual behavior
MONAI_DAILY_API_BUDGET=10.0
MONAI_AIGON_MODEL=hf.co/mradermacher/Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated-GGUF:Q4_K_M
```
Also .env on disk had `MONAI_ENABLED_PLATFORMS=[]` (empty) while container had
`["github_bounty","freelancer"]` — THREE different config sources disagreed
(compose, .env, live env). Live env wins for behavior.

### 5. Financial ledger — pure burn
```sql
SELECT type, round(sum(abs(amount))::numeric,4), min(timestamp), max(timestamp), count(*)
FROM transactions GROUP BY type;
-- expense | 2.63 | 2026-09-06 01:04:20 | 2026-09-06 23:13:46 | 263   (all -0.01)
-- no revenue rows at all
```

### 6. Exit forensics
```
ExitCode=137 OOMKilled=false RestartPolicy=unless-stopped RestartCount=0
StartedAt=2026-09-06T23:33:32Z FinishedAt=2026-09-06T23:45:07Z   # lived 11.5 min
```
- 137 + no OOM (dmesg clean, journalctl -u docker clean around window) +
  RestartCount=0 → conscious `docker kill/stop`, not crash loop.
- Watchers checked: `crontab -l` (only pluskwa), `systemctl list-timers`
  (only vault-unseal), `ps aux | grep monai-watch` → none. Nothing would
  resurrect it.

### 7. Last work before death (logs, 23:44-23:45Z)
- Building deliverables for job_freelancer_40694388: video_script.md,
  storyboard.txt, shot_list.md, audio_directions.md, subtitles.srt
- Hunt-gate loop: "REAL BOUNTY detected ... already in queue" for
  wormhole-foundation, Trauma-Station, armory-fleet, anthropics/claude-code
- Runtime calls: `POST http://localhost:38080/v1/chat/completions 200 OK`,
  model Huihui-Qwen3-Coder-30B, response 3922 chars → GPU WAS serving the loop
  until the container died.

### 8. GPU / accelerator truth
- Mesh-wide (runtime gossip / mesh_node_audit): 7 nodes, total 94 cores /
  270 GB, gpu_count total = **1** (local-aigon <host>, RTX 5090 23.9 GB).
- Local nvidia-smi: 0% util, 21W/95W, 74C, 23647/24463 MiB used:
  - ollama llama-server: 22146 MiB — Huihui-Qwen3-Coder-30B Q4_K_M (stale
    pre-migration model) + nomic-embed ~98 MiB, keep-alive pinned to
    2318-12-18 (i.e. forever)
  - thunderbird: 110 MiB
- Free VRAM ~800 MiB → a second large model cannot fit until the stale qwen3
  is unloaded. `MONAI_AIGON_MODEL` still pointed at the retired model after
  the migration to deepseek-v4-flash.

## Lessons encoded in SKILL.md
1. success=1 in agent's own DB ≠ delivered. Find the confirmation-handle
   column (bid_id / submission_id / external id) and count non-empty values.
2. Internal gate records pollute delivery tables (QS=.. (FG-ALLOW)).
3. Compose file ≠ live env. `docker inspect .Config.Env` is ground truth.
4. Exit 137 + RestartCount=0 + no OOM = killed on purpose; verify a watcher
   exists before expecting self-heal.
5. Mesh-wide "GPU usage" claims need the node audit (often exactly 1 GPU in
   the entire mesh).
