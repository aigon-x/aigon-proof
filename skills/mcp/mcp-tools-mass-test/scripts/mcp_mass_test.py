#!/usr/bin/env python3
"""Mass MCP tool test — calls every magic-router tool in parallel and reports results."""
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
    print(f"Testing {len(tools)} MCP tools...\n")

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as ex:
        future_map = {ex.submit(test_tool, t): t["name"] for t in tools}
        for f in concurrent.futures.as_completed(future_map):
            name, status, detail = f.result()
            results.append((name, status, detail))

    results.sort(key=lambda r: r[0])
    for name, status, detail in results:
        icon = "\u2705" if status == "PASS" else "\u274c"
        print(f"{icon} {name}: {detail}")

    passed = sum(1 for r in results if r[1] == "PASS")
    failed = sum(1 for r in results if r[1] == "FAIL")
    print(f"\n{'='*50}")
    print(f"Total: {passed + failed}, Passed: {passed}, Failed: {failed}")
    if failed:
        print("\nFAILURES:")
        for n, s, d in results:
            if s == "FAIL":
                print(f"  {n}: {d}")
    return failed == 0


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
