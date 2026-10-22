# HyperFrames `init` creates nested subdirectory

## Cross-skill pitfall (subagent-orchestration + hyperframes-cli)

When dispatching a subagent to build a HyperFrames composition, the subagent typically:

1. Creates an output directory: `mkdir -p output/03-my-project/`
2. CDs into it: `cd output/03-my-project/`
3. Runs: `npx hyperframes init my-video --non-interactive --example blank`

**Step 3 creates a NESTED subdirectory:**

```
output/03-my-project/
  └── my-video/           ← created by init
       ├── index.html
       ├── package.json
       └── assets/
```

Instead of the expected flat structure:

```
output/03-my-project/
  ├── index.html
  ├── package.json
  └── assets/
```

### Why this happens

`npx hyperframes init <name>` always creates a new subdirectory named `<name>` in the current working directory. This is correct when you run from a parent projects directory, but wrong when your intent is to initialize directly inside a pre-created output directory.

### Effect on verification

After the subagent reports complete, the parent sees files inside a sub-subdirectory:
```
output/03-aiwideo-promo/aiwideo-promo/index.html   ← wrong level
output/03-aiwideo-promo/aiwideo-promo/package.json  ← wrong level
```

HTTP serving from `output/03-aiwideo-promo/` serves the directory listing, not the composition. `npx hyperframes lint` fails because it can't find the composition root.

### Fix (parent-side, after subagent returns)

```bash
cd /path/to/output/03-my-project
# Move all files and dirs from nested dir up
find my-video -maxdepth 1 -type f -exec cp {} . \;
mkdir -p assets
cp -r my-video/assets/* assets/   2>/dev/null || true
cp -r my-video/compositions/* compositions/   2>/dev/null || true
rm -rf my-video
# Restore documentation files that may have been backed up
cp /tmp/STORYBOARD.md /tmp/SCRIPT.md .   2>/dev/null || true
```

> **CRITICAL: `cp -r my-video/assets/* assets/` silently does nothing if `assets/` doesn't exist yet.** `mkdir -p assets` MUST run BEFORE the copy. Without it, the assets directory never gets created and the HTML 404s on every image reference. Always verify after restructuring: `curl -s -o /dev/null -w "%{http_code}" http://localhost:<port>/output/<project>/assets/logo.svg` — must return 200.

### Real example — assets missing after copy (2026-07-27)

The parent restructured the nested `output/03-aiwideo-promo/aiwideo-promo/` dir but forgot `mkdir -p assets` before `cp`. Result: `assets/logo.svg`, `assets/opinia1.webp`, `assets/opinia2.webp` all returned 404. The HTML rendered without logo or testimonial images. Fix: `mkdir -p assets && curl -sL -o assets/logo.svg https://aiwideo.pl/logo-color-aiwideo.svg` (re-download from the actual website).

### Prevention in subagent context

When dispatching a subagent whose goal includes `npx hyperframes init`, add this to the context:

> **IMPORTANT:** `npx hyperframes init <name>` creates `<name>/` as a subdirectory of the current directory. If you `cd` into `output/03-my-project/` and run `init my-video`, the project lands in `output/03-my-project/my-video/`. To avoid this, either:
> - Run `init` from the parent directory, then `mv my-video/* output/03-my-project/`
> - Or accept the nesting and note the exact path in your summary

### Real example — OPERATION OLYMPUS (2026-07-27)

The HyperFrames subagent created `output/03-aiwideo-promo/aiwideo-promo/` containing index.html (17KB), 7 assets, CLAUDE.md, AGENTS.md, package.json, hyperframes.json, and meta.json. The parent restructured by moving all files up, resulting in a clean flat `output/03-aiwideo-promo/` directory serving HTTP 200 on every asset.
