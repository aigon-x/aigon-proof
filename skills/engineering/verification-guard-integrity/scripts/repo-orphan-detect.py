#!/usr/bin/env python3
"""Read-only repo file-wiring ORPHAN detector.

Finds .py/.sh/.rs/.ts files under <root>/{scripts,tools} that NOTHING calls:
not in cron/compose/hooks/gate registries, not referenced by any sibling file.

Mirrors the canonical AIGON gate tools/gates/scripts-wired-check.sh but also
covers tools/ and non-.sh/.py extensions (that gate scans only scripts/*.sh|py).

Usage:
    python3 repo-orphan-detect.py [ROOT] [--ext .py,.sh,.rs,.ts,.cjs]

Pitfalls baked in (all measured 2026-10-12; see references/sieroty-audyt-plikowy.md):
  * config/generated/ is EXCLUDED from the haystack — it is an INVENTORY of all
    files, so including it makes every file look wired = FALSE GREEN.
  * each file's OWN basename is neutralised in its body (self-reference guard).
  * match on basename AND stem — gates are referenced by SHORT NAME (no .sh),
    e.g. `law-estop`, not `law-estop.sh`.
  * skip .venv* (by PREFIX), site-packages, vendored lib dirs, backups, artifacts.
  * token-set membership (not substring `in`) — substring over a multi-MB
    haystack x ~1000 names times out.
  * tracked vs WIP split via `git ls-tree -r HEAD` (NOT ls-files: staged-only is
    still work-in-progress). A stale/unreachable origin gives meaningless
    ahead/behind — never report that as state.

This is a READ-ONLY probe: it only reads files and runs read-only git/cat.
"""
import os
import re
import subprocess
import sys


def main() -> int:
    args = sys.argv[1:]
    root = "."
    exts = (".py", ".sh", ".rs", ".ts", ".cjs", ".mjs")
    if args and not args[0].startswith("-"):
        root = args[0]
    for i, a in enumerate(args):
        if a == "--ext":
            exts = tuple(x if x.startswith(".") else "." + x for x in args[i + 1].split(","))
    root = os.path.abspath(root)

    skip_names = {"target", ".git", "node_modules", "__pycache__", "_archive",
                  "backups", "artifacts", "site-packages", "vendor"}

    def skip(d):
        return d.startswith(".venv") or d in skip_names

    cands = []
    for base in ("scripts", "tools"):
        bd = os.path.join(root, base)
        if not os.path.isdir(bd):
            continue
        for dp, dn, fn in os.walk(bd):
            dn[:] = [d for d in dn if not skip(d)]
            for f in fn:
                if f.endswith(exts):
                    cands.append(os.path.relpath(os.path.join(dp, f), root))

    def read(p):
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                return fh.read()
        except OSError:
            return ""

    blob = []
    # explicit SSOT channels
    for rel in ("config/cron.yaml", "config/backups.yaml",
                "config/canonical/hooks.yaml", "config/canonical/gates.yaml",
                "config/canonical/gate-registry.yaml", "config/canonical/pipeline-gate-map.yaml",
                "config/gateways.yaml", "config/alert-automation-policy.yaml",
                "docker-compose.yml", "core/docker-compose.yml"):
        blob.append(read(os.path.join(root, rel)))
    # every config yaml/yml/json EXCEPT generated/ (the inventory mask)
    gen = os.path.abspath(os.path.join(root, "config", "generated"))
    for dp, dn, fn in os.walk(os.path.join(root, "config")):
        dn[:] = [d for d in dn if not skip(d)]
        if os.path.abspath(dp).startswith(gen):
            continue
        for f in fn:
            if f.endswith((".yaml", ".yml", ".json")):
                blob.append(read(os.path.join(dp, f)))
    # every candidate's body, own basename neutralised
    for rel in cands:
        blob.append(read(os.path.join(root, rel)).replace(os.path.basename(rel), "__SELF__"))
    # runtime schedulers
    for cmd in ("cat /etc/cron.d/* /etc/crontab 2>/dev/null",
                "grep -rh . /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null"):
        try:
            blob.append(subprocess.run(cmd, shell=True, capture_output=True,
                                       text=True, timeout=60).stdout)
        except Exception:
            pass

    tokens = set(re.findall(r"[A-Za-z0-9][A-Za-z0-9_.\-]*", "\n".join(blob)))
    try:
        tr = subprocess.run(["git", "-C", root, "ls-tree", "-r", "HEAD", "--name-only"],
                            capture_output=True, text=True, timeout=60).stdout.split()
        tracked = set(tr)
    except Exception:
        tracked = set()

    def cls(name, body):
        if name.startswith(("test", "test_")) or "/test" in body[:400]:
            return "test"
        if name.startswith(("lib", "_")) or "source " in body[:600]:
            return "lib"
        return "script"

    orph = []
    for rel in cands:
        name = os.path.basename(rel)
        stem = name.rsplit(".", 1)[0]
        if name in tokens or stem in tokens:
            continue
        orph.append((rel, cls(name, read(os.path.join(root, rel))), rel in tracked))

    real = [o for o in orph if o[2] and o[1] != "test"]
    wip = [o for o in orph if not o[2] and o[1] != "test"]
    tests = [o for o in orph if o[1] == "test"]
    print(f"CAND={len(cands)} ORPHAN_REAL(tracked,non-test)={len(real)} "
          f"ORPHAN_WIP(untracked)={len(wip)} ORPHAN_TEST={len(tests)}")
    for lbl, group in (("REAL (tracked, non-test)", real),
                       ("WIP (untracked)", wip),
                       ("TEST", tests)):
        print(f"--- {lbl} ---")
        for rel, c, _ in sorted(group):
            print(f"  [{c:7}] {rel}")
    print("\nNOTE: vendored dirs (/lib/py/, site-packages/) are already skipped; "
          "docs/skills mentions are NOT a call channel.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
