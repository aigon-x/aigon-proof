#!/usr/bin/env python3
"""mcp-session.py — JEDNA sesja JSON-RPC do serwera MCP ze stanem (stdio).

PO CO: brama/hermes spawnuje nowy proces na każde tools/call, więc pary
`open_* -> operate` nie działają (drugie wywołanie: "no app is open").
Ten klient trzyma JEDEN proces i wysyła całą sekwencję w jednym strumieniu.

UŻYCIE:
  # komenda wprost
  mcp-session.py --cmd "/usr/bin/node /path/serwer.mjs --mcp" \
                 --cwd /path/do/katalogu \
                 --open open_binary --path /tmp/artefakt.so \
                 --tool list_strings --tool list_segments

  # albo z mcp-config.json serwera (bierze command+args+cwd)
  mcp-session.py --config /srv/aigon/mcp-servers/servers/x/mcp-config.json \
                 --open open_binary --path /tmp/a.so --tool list_strings

  # lista narzędzi i ich schematów (bez otwierania artefaktu)
  mcp-session.py --config <cfg> --list-tools

ZASADY ZASZYTE (każda zmierzona jako źródło cichego timeoutu):
  * stderr drenażowany na wątku (nieczytany pipe = proces staje)
  * odpowiedź czytana aż do matching `id` (notyfikacje/logi pomijane)
  * timeout na CAŁE dziecko, `kill` w finally
  * shim POMIJANY, gdy nie odpowiada na tools/call (patrz --no-shim)
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time


class Session:
    def __init__(self, argv: list[str], cwd: str | None, timeout: float = 120.0):
        self.proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=cwd, text=True, bufsize=1, start_new_session=True,
        )
        self.timeout = timeout
        self._id = 0
        self.stderr_log: list[str] = []
        threading.Thread(target=self._drain_err, daemon=True).start()

    def _drain_err(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self.stderr_log.append(line.rstrip())

    def _send(self, payload: dict) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def _recv(self, want_id: int) -> dict | None:
        assert self.proc.stdout is not None
        deadline = time.time() + self.timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue                      # logi serwera na stdout
            if msg.get("id") == want_id:      # matching id, nie pierwsza linia
                return msg
        return None

    def rpc(self, method: str, params: dict | None = None) -> dict:
        self._id += 1
        payload = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            payload["params"] = params
        self._send(payload)
        resp = self._recv(self._id)
        if resp is None:
            raise RuntimeError(f"brak odpowiedzi na {method} w {self.timeout}s; "
                               f"stderr_tail={self.stderr_log[-3:]}")
        if "error" in resp:
            raise RuntimeError(f"{method}: {json.dumps(resp['error'], ensure_ascii=False)[:500]}")
        return resp.get("result") or {}

    def call(self, name: str, args: dict | None = None) -> dict:
        return self.rpc("tools/call", {"name": name, "arguments": args or {}})

    def initialize(self) -> dict:
        res = self.rpc("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "aigon-mcp-session", "version": "1.0"},
        })
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.proc.stdin.flush()
        return res

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            if self.proc.pid:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
            self.proc.wait(timeout=5)
        except Exception:
            try:
                if self.proc.pid:
                    os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
            except Exception:
                pass


def text_of(result: dict) -> str:
    parts = [i.get("text") or "" for i in (result.get("content") or [])
             if isinstance(i, dict) and i.get("type") == "text"]
    if not parts and result.get("structuredContent"):
        parts.append(json.dumps(result["structuredContent"], ensure_ascii=False))
    return "\n".join(parts)


def load_config(path: str, no_shim: bool) -> tuple[list[str], str | None]:
    cfg = json.load(open(path, encoding="utf-8"))
    cmd = cfg.get("command")
    args = cfg.get("args") or []
    argv = [cmd, *args] if cmd else args
    if no_shim:
        # usuń wywołanie shima: python3 <shim.py> <realny argv...>
        for i, part in enumerate(argv):
            if "mcp_stdio_shim" in str(part):
                argv = argv[i + 1:]
                break
    return [str(a) for a in argv], cfg.get("cwd")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", help="komenda startowa serwera (string, dzielona przez shlex)")
    ap.add_argument("--cwd")
    ap.add_argument("--config", help="mcp-config.json serwera (command/args/cwd)")
    ap.add_argument("--no-shim", action="store_true", default=True,
                    help="pomiń mcp_stdio_shim.py (domyślnie WŁĄCZONE: shim nie odpowiada na tools/call)")
    ap.add_argument("--open", dest="open_tool", help="narzędzie otwierające, np. open_binary")
    ap.add_argument("--path", help="ścieżka artefaktu dla --open")
    ap.add_argument("--tool", action="append", default=[], help="narzędzie do wywołania po --open (wielokrotne)")
    ap.add_argument("--args", default="{}", help="argumenty JSON dla --tool (wspólne)")
    ap.add_argument("--list-tools", action="store_true")
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    if a.cmd:
        import shlex
        argv, cwd = shlex.split(a.cmd), a.cwd
    elif a.config:
        argv, cwd = load_config(a.config, a.no_shim)
    else:
        ap.error("podaj --cmd albo --config")

    if not argv or not shutil.which(argv[0]) and not os.path.exists(argv[0]):
        print(json.dumps({"ok": False, "error": f"nie znaleziono komendy: {argv[:2]}"}, ensure_ascii=False))
        return 2

    s = Session(argv, cwd, timeout=a.timeout)
    out: dict = {"ok": True, "argv": argv, "steps": {}}
    try:
        s.initialize()
        if a.list_tools:
            tools = s.rpc("tools/list", {}).get("tools") or []
            out["tools"] = [{"name": t.get("name"), "title": t.get("title"),
                             "required": (t.get("inputSchema") or {}).get("required", [])} for t in tools]
            out["tool_count"] = len(tools)
        if a.open_tool:
            if not a.path:
                out["steps"][a.open_tool] = "ERROR: --open wymaga --path"
            else:
                out["steps"][a.open_tool] = text_of(s.call(a.open_tool, {"path": os.path.abspath(a.path)}))
            try:
                shared = json.loads(a.args)
            except json.JSONDecodeError:
                shared = {}
            for tool in a.tool:
                try:
                    out["steps"][tool] = text_of(s.call(tool, shared))
                except RuntimeError as exc:
                    out["steps"][tool] = f"ERROR: {exc}"
    except Exception as exc:
        out = {"ok": False, "argv": argv, "error": str(exc), "stderr_tail": s.stderr_log[-5:]}
    finally:
        s.close()

    if a.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
    else:
        if not out.get("ok"):
            print("BLAD:", out.get("error"))
            for line in out.get("stderr_tail") or []:
                print("  stderr:", line)
        elif a.list_tools:
            print(f"tools: {out.get('tool_count')}")
            for t in out.get("tools", []):
                print(f"  {t['name']:<28} required={t['required']}")
        else:
            for step, val in out["steps"].items():
                head = (val or "").strip().replace("\n", " ")[:400]
                print(f"[{step}] {head}")
    return 0 if out.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
