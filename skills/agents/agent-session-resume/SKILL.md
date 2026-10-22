---
name: agent-session-resume
description: Find and resume an AI agent session by UUID across multiple backends (qwen-code, mesh task_execute, AIGON sessions, PTY). Covers discovery paths, filesystem layout, and CLI resume with environment pitfalls.
---


# Agent Session Resume

When the user says "przejmij taska", "resume <uuid>", "wznów sesję", or similar —
find where the session lives and resume it. Sessions can live in several backends;
check them in order of likelihood.

## Discovery ladder (check in this order)

### 1. Mesh task (task_execute)
```python
task_status(task_id=uuid)  # status: running/done/not_found
```
If found → it's a mesh-scattered task, not a local agent session.

### 2. AIGON sessions + runtime
```python
sessions_get(id=uuid)
runtime_query(endpoint="/api/v1/sessions/<uuid>")
runtime_query(endpoint="/api/v1/tasks/<uuid>")
```

### 3. PTY sessions (tui::gateway)
```python
tui__gateway_list()  # check count + session list
```

### 4. Filesystem — qwen-code session files
Qwen-code stores sessions per-project under `~/.qwen/projects/`. The workdir is
escaped: slashes → dashes. Example: `/opt/projects/pluskwa` → `-opt-projects-pluskwa`.

```
~/.qwen/projects/-<escaped-workdir>/chats/<uuid>.runtime.json   # session metadata
~/.qwen/projects/-<escaped-workdir>/subagents/<uuid>/           # subagent transcripts
```

The `runtime.json` contains: `session_id`, `work_dir`, `qwen_version`, `pid`.
Subagent `.meta.json` files show `agentType`, `status`, `model`.

Search with `search_files` for the UUID string if the project is unknown.

### 5. Live process check
```bash
ps aux | grep -i qwen | grep -v grep
```
Qwen serve runs on :4170 by default. Its HTTP server does NOT expose a session-list
endpoint — process presence only confirms the daemon is alive, not the session.

## Resuming a qwen-code session

```bash
qwen --resume <uuid> \
  --model "hf.co/mradermacher/Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated-GGUF:Q4_K_M"
```

Run from the project's workdir. Must use **`terminal(pty=true, background=true)`** —
the interactive TUI needs a pseudo-terminal.

### Pitfall: PTY PATH in tui::gateway

**Do NOT use `tui::gateway` for qwen resume.** The gateway's PTY runner lacks the
user's shell environment (nvm, PATH). The qwen launcher script fails with:
```
Error: Cannot find module '.../cli-entry.js'
MODULE_NOT_FOUND
```
Use `terminal(pty=true, background=true)` instead — it inherits the full session
environment.

### Monitoring after resume
```python
process(action="log", session_id="proc_<id>")
```
The resume takes a few seconds ("Initializing..."). Wait for the `➜ <project>` prompt
which confirms readiness.

## Related skills
- `agent-pause-resume` — SIGSTOP/SIGCONT of qwen processes during builds/deploys

## Reference traces
- `references/session-trace-6084e611.md` — full discovery + resume trace (2026-09-09, pluskwa project)