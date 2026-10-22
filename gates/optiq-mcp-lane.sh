#!/usr/bin/env bash
# GATE-259 — lane ChatGPT→OPTIQ MCP żyje i jest IZOLOWANY.
#
# Co mierzy (na ŻYWYM systemie, nie w plikach):
#   1. kontenery lane'u istnieją i są zdrowe (aigon-optiq-mcp, aigon-optiq-mcp-oauth)
#   2. lokalne /health obu usług: optiq-mcp (10 narzędzi) i brama (identity_mode=optiq)
#   3. publiczne discovery zwraca scope optiq.* i resource == hostname
#   4. /mcp bez tokenu = 401 z WWW-Authenticate (fail-closed, nie otwarte drzwi)
#   5. IZOLACJA: katalog narzędzi bramy OPTIQ nie zawiera narzędzi mesha
#   6. sekrety/stan lane'u nie są czytelne dla świata (0600/0640)
#
# Semantyka hosta: brama stoi tylko na local-aigon. Na innym węźle (brak
# kontenerów) bramka zwraca SKIP 0 — inaczej blokowałaby pracę wszystkim
# agentom na węzłach, które tej usługi nie mają.
#
# --selftest: dowód NEGATYWNY — bramka MUSI paść, gdy cel jest martwy.
set -uo pipefail

BASE="${OPTIQ_MCP_BASE:-https://optiq-mcp.aigon.dev}"
LOCAL="${OPTIQ_MCP_LOCAL:-http://127.0.0.1:18090}"
GATE="${OPTIQ_MCP_GATE:-http://127.0.0.1:18093}"
FORCE="${OPTIQ_MCP_GATE_FORCE:-0}"
FAIL=0
SKIP=0

say() { printf '%s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=1; }
ok()  { printf 'PASS  %s\n' "$*"; }

skipcheck() {
  if [[ "$FORCE" == "1" ]]; then
    bad "$1 (wymuszone, brak zasobu)"
  else
    printf 'SKIP  %s\n' "$1"
    SKIP=1
  fi
}

curlq() { curl -s -m 8 -H 'User-Agent: aigon-gate-259/1.0' "$@" 2>/dev/null; }

run_checks() {
  # 1. kontenery
  for c in aigon-optiq-mcp aigon-optiq-mcp-oauth; do
    state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || true)"
    if [[ -z "$state" ]]; then
      skipcheck "kontener $c nie istnieje na tym hoście"
    elif [[ "$state" != "running" ]]; then
      bad "kontener $c stan=$state"
    elif [[ "$health" != "healthy" && "$health" != "none" ]]; then
      bad "kontener $c zdrowie=$health"
    else
      ok "kontener $c running/$health"
    fi
  done

  # 2. lokalne health
  h1="$(curlq "$LOCAL/health")"
  n="$(printf '%s' "$h1" | python3 -c 'import json,sys;
try: print(json.load(sys.stdin).get("tools",0))
except Exception: print(0)' 2>/dev/null)"
  if [[ "${n:-0}" == "10" ]]; then ok "optiq-mcp: 10 narzędzi"; else bad "optiq-mcp tools=${n:-?}"; fi

  h2="$(curlq "$GATE/health")"
  mode="$(printf '%s' "$h2" | python3 -c 'import json,sys;
try: print(json.load(sys.stdin).get("identity_mode",""))
except Exception: print("")' 2>/dev/null)"
  if [[ "$mode" == "optiq" ]]; then ok "brama: identity_mode=optiq"; else bad "brama: identity_mode='$mode'"; fi

  # 3. publiczne discovery
  meta="$(curlq "$BASE/.well-known/oauth-protected-resource")"
  scopes="$(printf '%s' "$meta" | python3 -c 'import json,sys;
try: print(",".join(json.load(sys.stdin).get("scopes_supported") or []))
except Exception: print("")' 2>/dev/null)"
  res="$(printf '%s' "$meta" | python3 -c 'import json,sys;
try: print(json.load(sys.stdin).get("resource",""))
except Exception: print("")' 2>/dev/null)"
  if [[ "$scopes" == *optiq.read* ]]; then ok "public discovery: scope optiq.read"; else bad "public discovery: scopes='$scopes'"; fi
  if [[ "$res" == "$BASE" ]]; then ok "public discovery: resource zgodny"; else bad "public discovery: resource='$res'"; fi

  # 4. fail-closed na /mcp
  code="$(curlq -o /dev/null -w '%{http_code}' -X POST "$BASE/mcp" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' || true)"
  if [[ "$code" == "401" ]]; then ok "/mcp bez tokenu = 401"; else bad "/mcp bez tokenu = ${code:-?} (oczekiwane 401)"; fi

  # 5. izolacja katalogu — statyczna polityka bramy
  iso="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/mcp-oauth/tool_policy.py"
  if [[ -f "$iso" ]]; then
    python3 - "$iso" <<'PY'
import sys
ns = {}
src = open(sys.argv[1], encoding="utf-8").read()
exec(compile(src, sys.argv[1], "exec"), ns)  # plik danych, nie logika
optiq = ns.get("OPTIQ_TOOLS") or frozenset()
mesh = ns.get("ALL_TOOLS") or frozenset()
leak = sorted(optiq & mesh)
if leak:
    print("FAIL  izolacja: narzędzia OPTIQ obecne też w katalogu mesha: " + ",".join(leak))
    raise SystemExit(1)
if not optiq:
    print("FAIL  izolacja: OPTIQ_TOOLS puste")
    raise SystemExit(1)
print(f"PASS  izolacja: {len(optiq)} narzędzi optiq_*, 0 w katalogu mesha")
PY
    [[ $? -ne 0 ]] && FAIL=1
  else
    bad "brak $iso"
  fi

  # 6. drift ingress/DNS wobec kanonu — ten sam skrypt, który provisioning robi
  #    w trybie --apply; tu wołany w trybie pomiaru (zero zmian).
  if [[ -r /srv/aigon/infra/vault/vault-init.json ]]; then
    drift="$(python3 /srv/aigon/scripts/optiq-mcp-tunnel-dns.py --check 2>&1 | grep -c 'DRIFT' || true)"
    if [[ "${drift:-0}" != "0" ]]; then
      bad "drift tunelu/DNS — wpisy brakujące wobec kanonu"
    else
      ok "tunel/DNS zgodne z kanonem"
    fi
  else
    printf 'SKIP  drift tunelu/DNS (brak dostępu do Vaulta na tym hoście)\n'
  fi

  # 7. uprawnienia sekretu (świat NIE może czytać)
  for f in /srv/aigon/config/secrets/optiq-mcp-oauth-secret; do
    [[ -f "$f" ]] || { bad "brak pliku $f"; continue; }
    perm="$(stat -c '%a' "$f")"
    if (( (perm % 10) & 4 )); then
      bad "$f czytelny dla świata (perm=$perm)"
    else
      ok "uprawnienia $(basename "$f") = $perm"
    fi
  done
}

case "${1:-}" in
  --selftest)
    say "== selftest: dowód negatywny (martwy cel => FAIL) =="
    OPTIQ_MCP_LOCAL="http://127.0.0.1:9" OPTIQ_MCP_GATE="http://127.0.0.1:9" \
      OPTIQ_MCP_BASE="http://127.0.0.1:9" OPTIQ_MCP_GATE_FORCE=0 \
      bash "${BASH_SOURCE[0]}" >/tmp/gate-259-neg.$$ 2>&1
    rc_neg=$?
    OPTIQ_MCP_GATE_FORCE=1 \
      OPTIQ_MCP_LOCAL="http://127.0.0.1:9" OPTIQ_MCP_GATE="http://127.0.0.1:9" \
      OPTIQ_MCP_BASE="http://127.0.0.1:9" \
      bash "${BASH_SOURCE[0]}" >/dev/null 2>&1
    rc_force=$?
    rm -f "/tmp/gate-259-neg.$$"
    if [[ $rc_force -ne 0 ]]; then
      say "PASS  selftest: wymuszony martwy cel => FAIL (rc=$rc_force)"
      say "SELFTEST PASS (bramka nie jest slepa)"
      exit 0
    fi
    say "FAIL  selftest: bramka przepuscila martwy cel mimo FORCE (rc=$rc_force)"
    exit 1
    ;;
  ""|--check) ;;
  *)
    say "użycie: $0 [--check|--selftest]" >&2
    exit 2
    ;;
esac

say "== GATE-259 lane ChatGPT→OPTIQ MCP ($BASE) =="
run_checks

if [[ $FAIL -ne 0 ]]; then
  say "WYNIK: FAIL"
  exit 1
fi
if [[ $SKIP -ne 0 ]]; then
  say "WYNIK: SKIP (brak zasobów na tym hoście)"
  exit 0
fi
say "WYNIK: PASS"
exit 0
