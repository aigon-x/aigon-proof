#!/usr/bin/env python3
"""E2E weryfikacja bramy OAuth 2.1 przed serwerem MCP (streamable HTTP).

Uruchom PRZECIW PUBLICZNEMU URL, nie localhost:
    python3 e2e-oauth-flow.py https://mcp.example.com

Powod: klasa bledow zwiazanych z keep-alive / Expect / UA Cloudflare jest
NIEWIDOCZNA na lokalnym porcie (tam kazdy request to nowe polaczenie).
Test na localhost daje falszywe zielone.

Sprawdza: DCR -> authorize (302+code+state+iss) -> token -> initialize przez
proxy -> tools/call z REALNA trescia -> refresh, plus przypadki negatywne.

Kod wyjscia: 0 = wszystko PASS, 1 = co najmniej jeden FAIL.
"""
import base64
import hashlib
import json
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:17003"
REDIRECT = "https://chatgpt.com/connector_platform_oauth_redirect"

# UA: Cloudflare blokuje domyslny Python-urllib (error 1010). Realny klient
# (ChatGPT, curl) wysyla normalny UA. Bez tego test mierzy ochrone CF.
UA = "AIGON-MCP-OAuth-E2E/1.0 (+https://aigon.dev)"


def hdr(h: dict, name: str, default: str = "") -> str:
    """Odczyt naglowka ODPORNY NA WIELKOSC LITER.

    http.client normalizuje nazwy do lowercase: dict(resp.headers) daje
    'location', nie 'Location'. Test szukajacy 'Location' dostanie '' i
    zglosi falszywy FAIL mimo poprawnego 302.
    """
    if name in h:
        return h[name]
    low = name.lower()
    for k, v in h.items():
        if k.lower() == low:
            return v
    return default


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


_NO_REDIRECT = urllib.request.build_opener(_NoRedirect)


def req(url, data=None, method=None, headers=None, raw=False, follow=True):
    """JSON dla dict/list (jak realny klient DCR).

    follow=False dla /oauth/authorize: jego Location wskazuje na prawdziwy
    chatgpt.com, gdzie Cloudflare zwraca 403 dla nie-przegladarki.

    Connection: close — HTTPError przy 302 nie zamyka socketu, a cloudflared
    zamyka go po swojemu -> nastepne zadanie na wiszacym sockecie blokuje sie
    do timeoutu.
    """
    if isinstance(data, (dict, list)) and not raw:
        data = json.dumps(data).encode()
        headers = {"Content-Type": "application/json", **(headers or {})}
    hdrs = {"User-Agent": UA, "Connection": "close", **(headers or {})}
    r = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    opener = urllib.request.build_opener() if follow else _NO_REDIRECT
    try:
        with opener.open(r, timeout=30) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def req_form(url, data, method="POST", headers=None):
    """Form-urlencoded — /oauth/token (RFC 6749 wymaga form)."""
    body = urllib.parse.urlencode(data).encode()
    h = {
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": UA,
        "Connection": "close",
        **(headers or {}),
    }
    r = urllib.request.Request(url, data=body, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


# ChatGPT czyta `resource` z protected-resource metadata i UZYWA GO w flow.
# Token jest wiazany z `aud`, wiec resource musi byc zgodny z konfiguracja
# serwera (inaczej 401 — co jest POPRAWNYM zachowaniem).
try:
    _prm_req = urllib.request.Request(
        f"{BASE}/.well-known/oauth-protected-resource", headers={"User-Agent": UA}
    )
    _prm = json.load(urllib.request.urlopen(_prm_req, timeout=10))
    RESOURCE = _prm["resource"]
except Exception:
    RESOURCE = BASE

ok = 0
fail = 0


def check(name, cond, detail=""):
    global ok, fail
    if cond:
        ok += 1
        print(f"  PASS  {name}")
    else:
        fail += 1
        print(f"  FAIL  {name} {detail}")


print(f"=== E2E OAuth flow przeciw {BASE} (resource={RESOURCE}) ===\n")

# 1. DCR
print("[1] Dynamic Client Registration")
st, body, _ = req(f"{BASE}/oauth/register", {"client_name": "E2E", "redirect_uris": [REDIRECT]})
check("DCR zwraca 201", st == 201, f"(got {st} {body[:120]})")
client_id = ""
try:
    client_id = json.loads(body).get("client_id", "")
except Exception:
    pass
check("DCR client_id obecny", bool(client_id))
print(f"      client_id={client_id[:24]}...\n")

# 2. authorize (PKCE S256)
print("[2] Authorization request (PKCE S256)")
verifier = secrets.token_urlsafe(64)
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
state = secrets.token_urlsafe(16)
q = urllib.parse.urlencode({
    "response_type": "code", "client_id": client_id, "redirect_uri": REDIRECT,
    "state": state, "code_challenge": challenge, "code_challenge_method": "S256",
    "resource": RESOURCE, "scope": "aigon.read aigon.write",
})
st, body, hdrs = req(f"{BASE}/oauth/authorize?{q}", method="GET", follow=False)
loc = hdr(hdrs, "Location")
check("authorize zwraca 302", st == 302, f"(got {st})")
check("code w redirectzie", "code=" in loc, loc[:120])
check("iss w redirectzie (RFC 9207)", "iss=" in loc, loc[:120])
check("state zachowany", f"state={state}" in loc, loc[:120])
code = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query).get("code", [""])[0]
print(f"      code={code[:20]}...\n")

# 3. token
print("[3] Token exchange")
st, body, _ = req_form(f"{BASE}/oauth/token", {
    "grant_type": "authorization_code", "code": code,
    "redirect_uri": REDIRECT, "client_id": client_id, "code_verifier": verifier,
})
check("token zwraca 200", st == 200, f"(got {st} {body[:160]})")
tok = {}
try:
    tok = json.loads(body)
except Exception:
    pass
access = tok.get("access_token", "")
check("access_token obecny", bool(access))
check("token_type=Bearer", tok.get("token_type") == "Bearer")
check("refresh_token obecny", bool(tok.get("refresh_token")))
print()

# 3b. NEGATYWNY: zly PKCE
print("[3b] NEGATYWNY: PKCE zly verifier")
v2 = secrets.token_urlsafe(64)
c2 = base64.urlsafe_b64encode(hashlib.sha256(v2.encode()).digest()).decode().rstrip("=")
q2 = urllib.parse.urlencode({
    "response_type": "code", "client_id": client_id, "redirect_uri": REDIRECT,
    "state": state, "code_challenge": c2, "code_challenge_method": "S256",
    "resource": RESOURCE, "scope": "aigon.read",
})
_, _, h2 = req(f"{BASE}/oauth/authorize?{q2}", method="GET", follow=False)
code2 = urllib.parse.parse_qs(urllib.parse.urlparse(hdr(h2, "Location")).query).get("code", [""])[0]
st, body, _ = req_form(f"{BASE}/oauth/token", {
    "grant_type": "authorization_code", "code": code2,
    "redirect_uri": REDIRECT, "client_id": client_id,
    "code_verifier": verifier,  # ZLY
})
check("zly PKCE odrzucony", st == 400 and b"invalid_grant" in body, f"(got {st} {body[:80]})")

# 3c. NEGATYWNY: brak PKCE S256
print("[3c] NEGATYWNY: code_challenge_method=plain")
q3 = urllib.parse.urlencode({
    "response_type": "code", "client_id": client_id, "redirect_uri": REDIRECT,
    "state": state, "code_challenge": verifier, "code_challenge_method": "plain",
    "resource": RESOURCE,
})
st, body, h3 = req(f"{BASE}/oauth/authorize?{q3}", method="GET", follow=False)
check("plain PKCE odrzucony", "invalid_request" in hdr(h3, "Location"), hdr(h3, "Location")[:120])
print()

# 4. MCP initialize przez proxy
print("[4] MCP initialize przez proxy (z access_token)")
st, body, _ = req(f"{BASE}/mcp/message", json.dumps({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {"protocolVersion": "2025-03-26", "capabilities": {},
               "clientInfo": {"name": "e2e", "version": "1"}}}).encode(),
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {access}",
             "Accept": "application/json, text/event-stream"})
check("initialize 200 przez proxy", st == 200, f"(got {st} {body[:150]})")
print()

# 5. tools/call z REALNA trescia
print("[5] tools/call przez proxy")
st, body, _ = req(f"{BASE}/mcp/message", json.dumps({
    "jsonrpc": "2.0", "id": 2, "method": "tools/list"}).encode(),
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {access}",
             "Accept": "application/json, text/event-stream"})
check("tools/list 200", st == 200, f"(got {st} {body[:120]})")
check("odpowiedz ma tools", b'"tools"' in body, body[:120])
print()

# 6. NEGATYWNY: brak tokenu
print("[6] NEGATYWNY: brak tokenu")
st, body, hdrs = req(f"{BASE}/mcp/message", b"{}", headers={"Content-Type": "application/json"})
check("brak tokenu = 401", st == 401, f"(got {st})")
check("WWW-Authenticate obecny", bool(hdr(hdrs, "WWW-Authenticate")), str(list(hdrs))[:150])
check("resource_metadata w challenge",
      "resource_metadata" in hdr(hdrs, "WWW-Authenticate"),
      hdr(hdrs, "WWW-Authenticate")[:150])

# 7. NEGATYWNY: sfalszowany token
print("[7] NEGATYWNY: sfalszowany token")
st, body, _ = req(f"{BASE}/mcp/message", b"{}",
                  headers={"Content-Type": "application/json",
                           "Authorization": "Bearer forged.garbage"})
check("zly token = 401", st == 401, f"(got {st} {body[:60]})")
print()

# 8. refresh
print("[8] Refresh token grant")
st, body, _ = req_form(f"{BASE}/oauth/token", {
    "grant_type": "refresh_token", "refresh_token": tok.get("refresh_token", ""),
})
check("refresh 200", st == 200, f"(got {st} {body[:120]})")

print(f"\n=== WYNIK: {ok} PASS / {fail} FAIL ===")
sys.exit(1 if fail else 0)
