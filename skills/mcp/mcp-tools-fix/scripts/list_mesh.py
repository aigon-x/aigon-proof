#!/usr/bin/env python3
"""Parse AIGON Runtime /health JSON and print mesh nodes in a table.

Usage: curl -sf http://<node>:7000/health | python3 list_mesh.py
"""
import sys, json

d = json.load(sys.stdin)
nodes = d.get("mesh", {}).get("nodes", [])
if not nodes:
    nodes = d.get("mesh_peers", [])

for n in nodes:
    name = n.get("name", "?")
    addr = n.get("listen_addr", "?")
    state = str(n.get("state", "?"))
    peers = len(n.get("peers", []))
    print(f"  {name:15s} addr={addr:30s} state={state:10s} peers={peers}")

print(f"Total: {len(nodes)} nodes")
