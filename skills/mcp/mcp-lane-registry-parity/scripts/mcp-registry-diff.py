#!/usr/bin/env python3
"""Diff katalogów MCP między lane'ami (backend vs brama Magic Router).

Domyślnie:
  backend = http://127.0.0.1:38080/mcp        (aigon-code-server, Bearer JWT z ~/.hermes/config.yaml)
  gateway = http://127.0.0.1:17002/mcp/message (aigon-x-magic-router, Bearer z config/secrets/agent-mcp.token)

Użycie:
  python3 mcp-registry-diff.py
  python3 mcp-registry-diff.py --backend URL --gateway URL --runs 3

Wypluwa: liczbę narzędzi per lane, czasy, diff w OBIE strony.
Kod wyjścia: 0 = oba lane'y odpowiedziały (diff może być niezerowy — to wynik, nie błąd),
             2 = któryś lane nie odpowiedział (transport/auth).
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

CONFIG = os.path.expanduser("~/.hermes/config.yaml")
TOKEN_FILE = "/opt/PROD/config/secrets/agent-mcp.token"


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def backend_token():
    """Authorization z ~/.hermes/config.yaml (sekcja mcp_servers.aigon-code.headers)."""
    raw = read_file(CONFIG)
    m = re.search(r"Authorization:\s*(Bearer\s+[A-Za-z0-9._\-]+)", raw)
    return m.group(1) if m else None


def gateway_token():
    tok = os.environ.get("AGENT_MCP_TOKEN") or read_file(TOKEN_FILE).strip()
    return ("Bearer " + tok) if tok else None


def join_sse(raw):
    """Odpowiedź MCP to SSE: linie 'data: {...}'. Sklej WSZYSTKIE — ostatnia to ułamek JSON-a.

    Błąd klasy 'Extra data' / 'Expecting value' przy 26 KB odpowiedzi = wzięto
    tylko ostatnią linię data:.
    """
    parts = [ln[5:].strip() for ln in raw.splitlines() if ln.startswith("data:")]
    if parts:
        return "".join(parts)
    return raw.strip()


def tools_list(url, token, runs=3, timeout=60):
    """Zwraca (names_dict, times) albo (None, []) gdy lane nie odpowiada."""
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if token:
        headers["Authorization"] = token
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}).encode()
    times, names = [], None
    for _ in range(max(1, runs)):
        t0 = time.time()
        try:
            req = urllib.request.Request(url, data=body, headers=headers)
            raw = urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", "replace")
        except (urllib.error.URLError, OSError) as exc:
            print(f"  ! {url} -> {type(exc).__name__}: {exc}")
            return None, times
        times.append(time.time() - t0)
        try:
            payload = json.loads(join_sse(raw))
        except json.JSONDecodeError as exc:
            print(f"  ! {url} -> JSONDecodeError: {exc} (surowa dł. {len(raw)} B, sprawdź join_sse)")
            return None, times
        names = {t["name"]: t.get("description", "") for t in payload.get("result", {}).get("tools", [])}
    return names, times


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default="http://127.0.0.1:38080/mcp")
    ap.add_argument("--gateway", default="http://127.0.0.1:17002/mcp/message")
    ap.add_argument("--runs", type=int, default=3)
    args = ap.parse_args()

    print(f"backend: {args.backend}")
    be, be_t = tools_list(args.backend, backend_token(), args.runs)
    print(f"  narzędzi: {len(be) if be is not None else 'BRAK ODPOWIEDZI'}"
          + (f" | czasy: {', '.join(f'{x:.2f}s' for x in be_t)}" if be_t else ""))

    print(f"brama:   {args.gateway}")
    gw, gw_t = tools_list(args.gateway, gateway_token(), args.runs)
    print(f"  narzędzi: {len(gw) if gw is not None else 'BRAK ODPOWIEDZI'}"
          + (f" | czasy: {', '.join(f'{x:.2f}s' for x in gw_t)}" if gw_t else ""))

    if be is None or gw is None:
        print("\nWERDYKT: któryś lane nie odpowiedział — to transport/auth, nie diff rejestru.")
        return 2

    only_be = sorted(set(be) - set(gw))
    only_gw = sorted(set(gw) - set(be))
    print(f"\n=== TYLKO w backendzie ({len(only_be)}) ===")
    for n in only_be:
        print(f"  {n:34s} | {be[n][:70]}")
    print(f"\n=== TYLKO w bramie ({len(only_gw)}) ===")
    for n in only_gw:
        print(f"  {n:34s} | {gw[n][:70]}")

    print("\nWERDYKT:", "parytet OK" if not only_be and not only_gw
          else f"rejestry ROZJECHANE — {len(only_be)} tylko backend / {len(only_gw)} tylko brama")
    return 0


if __name__ == "__main__":
    sys.exit(main())
