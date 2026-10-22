---
name: mcp-tools-mass-test
description: Use when testing all MCP tools massowo — calls every tool registered in the Magic Router MCP bridge in parallel and reports pass/fail per tool.
version: 1.0.0
author: Hermes Agent
metadata:
  hermes:
    tags: [testing, mcp, magic-router, tools]
    related_skills: [rust-mcp-server, mcp-tools-fix, mcp-servers-management]
---


# MCP Tools Mass Test

## Overview

Massowy test wszystkich MCP tooli zarejestrowanych w Magic Router — wywołuje każde narzędzie przez HTTP POST na `localhost:17002/mcp/message` z minimalnymi parametrami i raportuje PASS/FAIL. Działa równolegle (20 wątków) i kończy się w ~30s dla 84 tooli.

## When to Use

- Po dodaniu nowego MCP serwera/skilla do magic-router
- Po zmianach w bridge'u MCP (`mcp-bridge-proxy.py`)
- Przed deployem, żeby upewnić się że wszystkie narzędzia są zarejestrowane i odpowiadają
- Do diagnostyki: które tool-e nie odpowiadają i z jakim błędem

Nie używaj do testowania funkcjonalności — to test "czy narzędzie istnieje i odpowiada", nie "czy robi dobrze swoją robotę".

## How to Run

Skrypt testowy do zapisania gdzieś lub uruchomienia bezpośredniego:

```python
#!/usr/bin/env python3
"""Mass MCP tool test — calls every tool in parallel and reports results."""
import json, sys, urllib.request, time, concurrent.futures

MCP_BRIDGE = "http://127.0.0.1:17002"
TIMEOUT = 15

def call_mcp(method, params=None):
    body = {
        "jsonrpc": "2.0",
        "id": "t-" + str(int(time.time() * 1000000)),
        "method": method,
        "params": params or {},
    }
    req = urllib.request.Request(
        MCP_BRIDGE + "/mcp/message",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        resp = urllib.request.urlopen(req, timeout=TIMEOUT)
        return json.loads(resp.read())
    except Exception as e:
        return {"error": str(e)}

def get_all_tools():
    resp = call_mcp("tools/list")
    return resp.get("result", {}).get("tools", [])

def default_params(name, schema):
    """Build minimal params for any tool."""
    props = schema.get("properties", {})
    if name == "echo":
        return {"message": "ping"}
    if name == "code_quality":
        return {"input": "fn main() {}"}
    if name == "runtime_query":
        return {"endpoint": "/health", "method": "GET"}
    if not props:
        return {}
    
    # Tools that take context+files
    context_files_tools = (
        "code_review", "code_analyze", "code_fix", "code_generate",
        "code_architecture", "code_plan", "code_docs", "code_quality",
        "code_security", "code_bench", "code_deps", "code_migrate",
        "code_rca", "code_refactor", "code_canon", "code_test",
        "code_bugs", "code_perf",
        "media_image", "media_audio", "media_video", "media_animation",
        "ops_deployment", "ops_monitoring", "ops_ha_continuity",
        "ops_ha_failover", "ops_ha_multiregion",
        "storage_tenant_db", "storage_vector",
        "business_report", "marketing_content", "product_copy",
        "product_ux", "web_analytics", "web_seo", "web_geo",
        "ai_learning", "ai_memory_extended", "ai_metalearning",
        "ai_reasoning", "compute_gpu", "compute_federated",
        "compute_background_jobs", "geo_maps", "geo_places",
        "knowledge_memory", "knowledge_discovery",
        "communication_email", "run_benchmarks",
        "security_audit",
    )
    # Tools that take input string
    input_tools = (
        "audio", "browser", "filesystem", "security_scan",
        "cognitive_economy", "collective_intel", "consciousness",
        "evolution", "reasoning", "research", "doc_gen",
        "network_discovery", "perf_audit", "iac_audit",
        "test_generate", "vision", "vuln_scan",
    )
    
    norm = name.replace("__", "_").replace("-", "_")
    if norm in context_files_tools or name.replace("-", "_") in context_files_tools:
        return {"context": {}, "files": []}
    if norm in input_tools or name.replace("-", "_") in input_tools:
        return {"input": ""}
    return {}


def test_tool(tool):
    name = tool["name"]
    params = default_params(name, tool.get("inputSchema", {}))
    try:
        resp = call_mcp("tools/call", {"name": name, "arguments": params})
        err = resp.get("error")
        if err:
            msg = err.get("message", str(err))
            return (name, "FAIL", msg[:100])
        return (name, "PASS", "ok")
    except Exception as e:
        return (name, "FAIL", str(e)[:100])


def main():
    tools = get_all_tools()
    print(f"Testing {len(tools)} MCP tools...")
    
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as ex:
        future_map = {ex.submit(test_tool, t): t["name"] for t in tools}
        for f in concurrent.futures.as_completed(future_map):
            name, status, detail = f.result()
            results.append((name, status, detail))
    
    results.sort(key=lambda r: r[0])
    for name, status, detail in results:
        print(f"{'PASS' if status == 'PASS' else 'FAIL'}: {name} | {detail}")
    
    passed = sum(1 for r in results if r[1] == "PASS")
    failed = sum(1 for r in results if r[1] == "FAIL")
    print(f"\nTotal: {passed + failed}, Passed: {passed}, Failed: {failed}")
    if failed:
        print("FAILURES:")
        for n, s, d in results:
            if s == "FAIL":
                print(f"  {n}: {d}")
    return failed == 0


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
```

Uruchom:

```bash
python3 /path/to/mcp_mass_test.py
```

## What It Tests

Dla każdego narzędzia MCP z magic-router:

1. Wywołuje `tools/list` → pobiera listę wszystkich tooli i ich schematy
2. Dla każdego narzędzia wywołuje `tools/call` z minimalnymi parametrami
3. Sprawdza czy odpowiedź zawiera `error` czy nie

Narzędzia dzielą się na 3 kategorie:

- **Bez backendu** (zwracają `"error sending request for url"`) — narzędzia zarejestrowane, ale ich backend (port 7000 runtime lub port 26070 subagent) nie jest aktywny. TO NIE JEST BŁĄD TESTU — narzędzia są poprawnie zarejestrowane w MCP.
- **Wymagające parametrów** (zwracają `"missing required argument"`) — narzędzia TUI gateway itp. Reagują poprawnie, brakuje im tylko kontekstu.
- **Działające** (`runtime_health`, `echo`, `runtime_kernels`, `runtime_tools`, `tui__gateway_list`) — zwracają pełne dane.

## Interpreting Results

| Sygnał | Znaczenie |
|---|---|
| `PASS: tool_name` | Narzędzie istnieje i odpowiedziało (nawet jeśli z błędem biznesowym) |
| `FAIL: tool_name: timeout` | Narzędzie nie odpowiedziało w 15s — prawdopodobnie backend nie żyje |
| `FAIL: tool_name: Connection refused` | MCP bridge nie odpowiada — magic-router nie działa |
| `error sending request for url` w PASS | Backend capability nieaktywny — to OK |

## Common Pitfalls

1. **Timeout skryptu** — 84 narzędzia × ~3s = ~250s sekwencyjnie. Używaj ThreadPoolExecutor (20 wątków) → ~30s.
2. **Różna liczba tooli** — MCP bridge zwraca ~84 narzędzia, ale lista w konwersacji może pokazywać ~88 (różne źródła). Testuj te z bridge'a.
3. **Runtime na porcie 7000 nie musi być aktywny** — to normalne w środowisku dev. Test sprawdza rejestrację, nie backend.
4. **Po przeładowaniu MCP serwerów lista tooli może się zmienić** — uruchom ponownie test.

## Verification Checklist

- [ ] Skrypt uruchamia się bez błędów składni
- [ ] Wszystkie narzędzia zwracają PASS (nawet jeśli z błędem backendu)
- [ ] Żadne narzędzie nie timeoutuje
- [ ] Liczba testowanych tooli jest rozsądna (80+)
