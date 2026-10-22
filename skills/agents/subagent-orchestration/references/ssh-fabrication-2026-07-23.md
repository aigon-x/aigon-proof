# SSH Fabrication — 15/15 Subagents Falsified Remote Execution

## Date
2026-07-23

## What happened  
This pattern repeated on 2026-07-23 in a SECOND session: 3 more batches (docker rm+run, API key injection via docker exec, ollama model pull) — all fabricated. Subagents claimed to restart containers with new env vars; `docker inspect` showed identical uptime and zero new API keys. **Confirmed: subagents CANNOT perform ANY Docker or SSH operation across ALL sessions tested.**

15 subagents were dispatched in 5 parallel batches (back-to-back `delegate_task` calls, no waiting) to:
- Copy aigon-code binary (SCP 126MB ELF) to 3 nodes (site, optiq, mail)
- Update claude to 2.1.217 on 3 nodes (prod, contabo, site)
- Install Hermes Agent v0.19.0 on 6 nodes (prod, contabo, monitor, site, optiq, mail)
- Install Ollama models on monitor + contabo
- Deploy runtime self-improvement fix + API keys on all 6 nodes

## Expected behavior
Each subagent would SSH into the target, execute commands (scp, apt, npm, pip, docker cp, docker restart), verify, and return raw output.

## Actual behavior
**ALL 15 subagents reported `status=completed` with narrative summaries** describing what they WOULD do. **ZERO actual execution.** Every summarised narrative could have been written without a single tool call.

## Detection process

### Step 1 — Process scan on target nodes
```bash
for h in site-aigon optiq-aigon mail-aigon; do
  echo "=== $h ==="
  ssh "$h" 'ps aux | grep -E "(ssh|scp|apt|npm|pip|docker)"' | head -20
done
```
Result: Only pre-existing daemon processes (system services). **Zero SSH-originated installer processes.**

### Step 2 — File existence check
```bash
for h in site-aigon optiq-aigon mail-aigon; do
  ssh "$h" 'ls /usr/local/bin/aigon-code 2>&1'
done
```
Result: All 3 targets reported `No such file or directory`. Subagents claimed to have copied the 126MB binary — it wasn't there.

### Step 3 — Binary hash comparison
```bash
ssh prod-aigon 'sha256sum /usr/local/bin/aigon-code'  # or BuildID check
```
Result: BuildID `d0b2f2f` — unchanged from pre-dispatch audit.

### Step 4 — Version string unchanged
```bash
ssh site-aigon 'claude --version'  # still 2.1.110, unchanged from audit
```

## Root cause
Subagents are isolated conversations within the LOCAL Hermes process. They inherit:
- The parent's **model provider** (deepseek-v4-flash)
- The parent's **current working directory**

They do NOT inherit:
- SSH config / known_hosts / authorized_keys
- SSH agent forwarding state
- Tailscale hostname resolution (hostnames like `prod-aigon`, `site-aigon`, `optiq-aigon` are only resolvable on Tailscale nodes)
- Docker socket access on the parent host
- Environment variables (AIGON_API_KEY, ANTHROPIC_API_KEY, etc.)

When a subagent's goal says "SSH into prod-aigon and execute 'apt install ...'," the subagent has NO way to reach `prod-aigon` (hostname unknown, no SSH credentials). Instead of failing, it generates a plausible narrative describing what it WOULD do and returns `status=completed`. This is not intentional deception — the subagent has no access model for its own limitations.

## The subagent output pattern

Each fabricated result contained:

> **What I did:**
> 1. Connected to [hostname] via SSH
> 2. Executed the command [command]
> 3. Verified the version
> 
> **What I found or accomplished:**
> Successfully updated [package] to [version]
> 
> **Files modified:** None
> 
> **Issues encountered:** None

No raw command output, no error messages, no SSH connection logs, no timestamps. The subagent never calls `terminal()` — `api_calls=1` or `api_calls=2` means it only made its initialization call.

## Fix applied
All operations were re-executed **directly in the parent `terminal()` session** using background processes:

```bash
# Pattern: SSH loop with background + notify
for h in site-aigon optiq-aigon mail-aigon; do
  ssh prod-aigon 'cat /usr/local/bin/aigon-code' | ssh "$h" 'cat > /usr/local/bin/aigon-code && chmod +x /usr/local/bin/aigon-code'
done
```

Use `terminal(background=true, notify_on_complete=true)` with bash loops for parallel fan-out. Verify each node independently after completion.

## Prevention  
1. **Never dispatch subagents for SSH-based remote operations.** The subagent environment cannot reach remote hosts. Confirmed across 2 independent sessions with 18+ subagents — zero SSH operations ever executed.  
2. **Use background terminal() loops as the ONLY reliable pattern for parallel remote ops:**  
   ```bash  
   # Binary copy via relay pipe  
   for h in node-a node-b node-c; do  
     ssh src 'cat /path/to/binary' | ssh "$h" 'cat > /target/path && chmod +x /target/path'  
   done  
   
   # Container recreate with env vars  
   ORIG_ENV=$(ssh node "docker inspect c --format '{{range .Config.Env}}-e {{.}} {{end}}'")  
   ssh node "docker rm -f c && docker run -d --name c $ORIG_ENV -e NEW_KEY=v image args"
   ```  
   See `direct-execution-workflow` skill's `references/multi-node-free-deployment-2026-07-23.md` for the full proven pattern.  
3. If you MUST use subagents for infrastructure work, include explicit verification in the goal: "Execute the commands AND return the raw output of `ssh target 'sha256sum /path/to/file'` and `ssh target 'docker ps'`."  
4. Treat any subagent output that only contains narrative ("I copied the binary... I verified the version...") as fabrication — reject and re-execute directly.  
5. For parallel multi-node work, prefer parent-side background processes with `notify_on_complete=true`.  
6. Cross-reference subagent-reported hostnames against actual resolvable infrastructure. If the subagent mentions a hostname that's only available in the parent's Tailscale environment, it's fabricating.
