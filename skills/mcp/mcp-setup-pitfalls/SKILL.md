---
name: mcp-setup-pitfalls
description: Common pitfalls when configuring the MCPRegistry path and case sensitivity in multi‑server projects.
version: 0.1.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [mcp, registry, setup, pitfalls]
    homepage: https://github.com/NousResearch/hermes-agent
    related_skills: []
---


# MCPRegistry Path & Case‑Sensitivity Pitfall

The original MCPRegistry implementation looked for a directory called
`MCP` next to `src/registry`.  When the project structure changed to a
flat `.../mcp-servers/servers/<category>/<server>/` layout, the registry
could not find any servers.  This caused the **MCP layer to report all
servers as DOWN**.

## What to Check

1. **`MCPRegistry.mcpBasePath`**
   ```js
   this.mcpBasePath = path.resolve(__dirname, '../../../MCP');
   ```
   * If the path ends up empty, the registry has nothing to discover.

2. **Case sensitivity** – the filesystem on Linux/WSL is case‑sensitive.
   The registry expects an *uppercase* folder, but the real folder is
   usually `mcp-servers` or a lower‑case `mcp`.  On Windows this won’t crash, but
   the registry will still discover 0 servers.

3. **Relative depth** – ensure the `..` chain points to the correct root.
   In the example project the registry lived under
   `<workspace>/mcp-servers/servers/ai/software-house-prime/src/registry`,
   so the correct traversal is `../../../../servers`.

## Fix

```js
this.mcpBasePath = path.resolve(__dirname, '../../../../servers');
```
Then adapt the discovery routine to walk the tree recursively:
```js
async discoverExistingMCPServers() {
  const dirs = [];
  const walk = async (p) => {
    const entries = await fs.readdir(p);
    for (const e of entries) {
      const child = path.join(p, e);
      const stat = await fs.stat(child);
      if (stat.isDirectory()) {
        await walk(child);
        // if a package.json exists, treat this as a server
        const pkg = path.join(child, 'package.json');
        try { await fs.access(pkg); dirs.push(child); } catch { }
      }
    }
  };
  await walk(this.mcpBasePath);

  for (const serverPath of dirs) {
    const serverName = path.relative(this.mcpBasePath, serverPath);
    const cfg = await this.analyzeExistingServer(serverName, serverPath);
    if (cfg) this.registeredServers.push(cfg);
  }
}
```

## Result

After applying this change, the registry discovers the 128+ servers that
were previously reported as DOWN.  A quick sanity check:

```bash
hermes mcp list
# should list all known servers with status = healthy/unhealthy
```

## When to Apply

- You just saw the **MCP** surface reporting all servers as *DOWN*.
- The MCPRegistry logs errors about `ENOENT` on `scandir`.
- You are migrating a repo from an old layout where an `MCP` folder
  existed.

---