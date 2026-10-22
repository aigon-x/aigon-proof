#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/mcp-liveness.sh — gate mcp-liveness (cyclic:6h)
#
#  Wykrywa martwe adresy MCP z CANONICAL-STRUCTURE-2026-08-21 (S8):
#    config agentów wskazuje 127.0.0.1:38080 (bramka MCP), a bramka żyje
#    na masterze 100.99.59.100:38080 — lokalny adres nie odpowiada.
#
#  Sprawdza: (1) adresy MCP w configach agentów (settings.json),
#  (2) liveness każdego adresu (TCP connect), (3) raportuje martwe.
#
#  Exit: 0 = PASS, 1 = FAIL (martwe adresy), 2 = WARN (brak configów/
#  narzędzi). Ostatnia linia stdout = komunikat.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

failures=0
found=""

report() {
  found="${found}${1}"$'\n'
  failures=$((failures + 1))
}

# ── zbiór adresów MCP z configów agentów ──────────────────────────────
# HOME_OPER — dom OPERATORA (SSOT); reaktor chodzi jako root (HOME=/root) i bez tego
# zwracał fałszywe WARN „brak adresów MCP" (configi żyją w /home/sniegul).
HOME_OPER="${AIGON_OPER_HOME:-/home/sniegul}"
mcp_addrs=""
for cfg in "$HOME_OPER/.qwen/settings.json" "$HOME_OPER/.claude/settings.json" "$HOME_OPER/.grok/config.toml" "$HOME_OPER/.config/grok/config.toml"; do
  [ -r "$cfg" ] || continue
  addrs=$(grep -oE '"(url|command|transport)":\s*"[^"]*"' "$cfg" 2>/dev/null | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+|localhost:[0-9]+' || true)
  mcp_addrs="${mcp_addrs}${addrs}"$'\n'
done

# dedup + sanityzacja
addrs=$(echo "$mcp_addrs" | grep -E '^[0-9.:]+$' | sort -u)

if [ -z "$addrs" ]; then
  echo "WARN: brak adresów MCP w configach agentów ($HOME_OPER/.qwen/settings.json itd.) — sprawdzenie niemożliwe"
  exit 2
fi

# ── liveness każdego adresu ───────────────────────────────────────────
dead=""
while IFS= read -r addr; do
  [ -n "$addr" ] || continue
  host="${addr%:*}"
  port="${addr##*:}"
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout 2 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
      dead="${dead}${addr}"$'\n'
    fi
  else
    report "WARN: brak narzędzia timeout — liveness MCP niezweryfikowany"
    break
  fi
done <<< "$addrs"

dead=$(echo "$dead" | grep -E '^[0-9.:]+$' | sort -u)
if [ -n "$dead" ]; then
  n=$(echo "$dead" | grep -c .)
  report "S8: $n martwe adresy MCP (z configów agentów): $(echo "$dead" | tr '\n' ' ')"
fi

# ── Werdykt ───────────────────────────────────────────────────────────
if [ "$failures" -gt 0 ]; then
  echo "FAIL: martwe adresy MCP (${failures}):"
  echo -n "$found" | sed 's/^/  /'
  exit 1
fi

echo "PASS: wszystkie adresy MCP z configów agentów odpowiadają"
exit 0
