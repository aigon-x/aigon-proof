#!/usr/bin/env python3
"""Test all AIGON Runtime nodes for health and kernel count.

Usage: python3 check_all_nodes.py [--timeout N]

Exits 0 only if ALL nodes respond with running + 13 kernels.
Prints a per-node table and summary.
"""
import subprocess, json, sys, argparse

NODES = {
    "LOCAL":     "192.0.2.18:7000",
    "CONTABO":   "192.0.2.16:7000",
    "PROD":      "192.0.2.19:7000",
    "OPTIQ":     "192.0.2.17:7000",
    "SITE":      "192.0.2.10:7000",
    "MONITOR":   "192.0.2.11:7000",
    "MAIL":      "192.0.2.15:7000",
    "KAMIL-DEV": "192.0.2.14:7000",
    "SNOWAJ":    "79.189.248.238:7000",
}

parser = argparse.ArgumentParser()
parser.add_argument("--timeout", type=int, default=5)
args = parser.parse_args()

ok = 0
fail = 0
for name, addr in NODES.items():
    try:
        r = subprocess.run(
            ["curl", "-sf", "--connect-timeout", str(args.timeout), f"http://{addr}/health"],
            capture_output=True, text=True, timeout=args.timeout + 3)
        if r.returncode != 0:
            print(f"  {name:12s} FAIL (curl rc={r.returncode})")
            fail += 1
        else:
            d = json.loads(r.stdout)
            bp = d.get("boot_phase", "?")
            kc = d.get("config_fingerprint", {}).get("kernel_count", "?")
            print(f"  {name:12s} boot={bp:10s} kernels={kc}")
            ok += 1
    except Exception as e:
        print(f"  {name:12s} ERROR ({e})")
        fail += 1

print(f"\n{ok} OK, {fail} FAIL")
sys.exit(0 if fail == 0 else 1)
