#!/usr/bin/env python3
"""SZABLON: brama OAuth 2.1 (Authorization Server + Resource Server) przed
istniejacym serwerem MCP. Python stdlib, zero zaleznosci.

Model: jeden proces, dwie role, proxy do upstreamu z podmiana tokenu.
  Klient ──HTTPS──> TEN SERWER ──> UPSTREAM (istniejacy gateway MCP)

  RS: /.well-known/oauth-protected-resource, /mcp/message, /sse
  AS: /.well-known/oauth-authorization-server, /oauth/{register,authorize,token}

Tokeny bezstanowe podpisane HMAC (iss, aud, sub, scope, exp, jti) — bez bazy.
`resource` z flow jest wiazany w `aud`: token wydany dla tego zasobu nie
zadziala gdzie indziej.

DOPASUJ: ISSUER, RESOURCE, UPSTREAM, porty, suffix tooli, scopes.

Zawiera naprawy trzech klas bledow HTTP (opis w SKILL.md):
  A. _drain_body() przed odpowiedzia nieczytajaca ciala (keep-alive desync)
  B. _body_read guard w _drain_body (podwojny odczyt = hang)
  C. _handle_expect_100() na starcie POST/DELETE
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

# ── KONFIGURACJA — dopasuj do swojego wdrozenia ──────────────────────────────
ISSUER = os.environ.get("OAUTH_ISSUER", "https://mcp.example.com").rstrip("/")
RESOURCE = os.environ.get("OAUTH_RESOURCE", ISSUER).rstrip("/")
LISTEN_HOST = os.environ.get("OAUTH_LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("OAUTH_LISTEN_PORT", "17003"))
UPSTREAM = os.environ.get("OAUTH_UPSTREAM", "http://127.0.0.1:17002").rstrip("/")
UPSTREAM_TOKEN_FILE = os.environ.get("OAUTH_UPSTREAM_TOKEN_FILE", "/etc/aigon/agent-mcp.token")
ACCESS_TTL = int(os.environ.get("OAUTH_ACCESS_TTL", "3600"))
CODE_TTL = int(os.environ.get("OAUTH_CODE_TTL", "300"))
SCOPES = ["aigon.read", "aigon.write"]
CHATGPT_REDIRECT = "https://chatgpt.com/connector_platform_oauth_redirect"

# Sekret podpisu: env (test) > plik 600 (produkcja) > generowany (tokeny padaja
# po restarcie — klient dostanie 401 i zrobi re-auth).
_ENV = os.environ.get("OAUTH_SIGNING_SECRET", "")
_FILE = os.environ.get("OAUTH_SIGNING_SECRET_FILE", "")
if _ENV:
    SECRET = _ENV.encode()
elif _FILE:
    try:
        SECRET = open(_FILE, "rb").read().strip()
    except OSError:
        SECRET = hashlib.sha256(secrets.token_bytes(32)).digest()
else:
    SECRET = hashlib.sha256(secrets.token_bytes(32)).digest()


class Store:
    def __init__(self):
        self._lock = threading.Lock()
        self.clients, self.codes, self.refresh = {}, {}, {}

    def put_client(self, meta):
        cid = "mcp-" + secrets.token_urlsafe(24)
        with self._lock:
            self.clients[cid] = meta
        return cid

    def get_client(self, cid):
        with self._lock:
            return self.clients.get(cid)

    def put_code(self, code, data):
        with self._lock:
            self.codes[code] = data

    def pop_code(self, code):
        with self._lock:
            return self.codes.pop(code, None)

    def put_refresh(self, tok, data):
        with self._lock:
            self.refresh[tok] = data

    def get_refresh(self, tok):
        with self._lock:
            return self.refresh.get(tok)


STORE = Store()


def upstream_token() -> str:
    try:
        return open(UPSTREAM_TOKEN_FILE).read().strip()
    except OSError:
        return ""


def _b64e(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _b64d(txt: str) -> bytes:
    return base64.urlsafe_b64decode(txt + "=" * (-len(txt) % 4))


def make_token(aud, scope, sub, ttl, typ="access"):
    body = {"iss": ISSUER, "aud": aud, "sub": sub, "scope": scope, "typ": typ,
            "iat": int(time.time()), "exp": int(time.time()) + ttl,
            "jti": secrets.token_urlsafe(12)}
    payload = _b64e(json.dumps(body, separators=(",", ":")).encode())
    sig = _b64e(hmac.new(SECRET, payload.encode(), hashlib.sha256).digest())
    return f"{payload}.{sig}"


def verify_token(tok, expected_aud=None):
    try:
        payload, sig = tok.split(".", 1)
    except ValueError:
        return None
    want = _b64e(hmac.new(SECRET, payload.encode(), hashlib.sha256).digest())
    if not hmac.compare_digest(want, sig):
        return None
    try:
        claims = json.loads(_b64d(payload))
    except Exception:
        return None
    if claims.get("exp", 0) < int(time.time()) or claims.get("iss") != ISSUER:
        return None
    if expected_aud is not None and claims.get("aud") != expected_aud:
        return None
    return claims


def pkce_ok(verifier, challenge, method):
    if method != "S256":
        return False
    return hmac.compare_digest(_b64e(hashlib.sha256(verifier.encode()).digest()), challenge)


class Handler(BaseHTTPRequestHandler):
    server_version = "mcp-oauth-gate/1.0"
    protocol_version = "HTTP/1.1"

    def _cors(self):
        origin = self.headers.get("Origin", "")
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Headers",
                         "authorization,content-type,mcp-protocol-version,mcp-session-id")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS,DELETE")

    def _json(self, code, obj, extra=None):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self._cors()
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def _err(self, code, error, desc=""):
        self._drain_body()                    # NAPRAWA A
        body = {"error": error}
        if desc:
            body["error_description"] = desc
        self._json(code, body)

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return b""
        data = self.rfile.read(n)
        self._body_read = True                # NAPRAWA B — guard
        return data

    def _form_or_json(self):
        raw = self._read_body()
        if "application/json" in (self.headers.get("Content-Type") or "").lower():
            try:
                return json.loads(raw or b"{}")
            except json.JSONDecodeError:
                return {}
        return {k: v[0] for k, v in parse_qs(raw.decode()).items()}

    def _drain_body(self):
        """PATRZ SKILL.md: blad A (desync keep-alive) + blad B (podwojny odczyt)."""
        if getattr(self, "_body_read", False):   # GUARD — inaczej HANG
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n > 0:
            try:
                self.rfile.read(n)
                self._body_read = True
            except OSError:
                pass

    def _handle_expect_100(self):
        """PATRZ SKILL.md: blad C. BaseHTTPRequestHandler tego nie obsluguje."""
        if self.headers.get("Expect", "").lower() == "100-continue":
            self.wfile.write(b"HTTP/1.1 100 Continue\r\n\r\n")
            self.wfile.flush()

    def log_message(self, format, *args):  # noqa: A002
        return

    # ── discovery ────────────────────────────────────────────────────────────
    def _protected_resource(self):
        self._json(200, {"resource": RESOURCE, "authorization_servers": [ISSUER],
                         "scopes_supported": SCOPES,
                         "bearer_methods_supported": ["header"]})

    def _auth_meta(self):
        self._json(200, {
            "issuer": ISSUER,
            "authorization_endpoint": f"{ISSUER}/oauth/authorize",
            "token_endpoint": f"{ISSUER}/oauth/token",
            "registration_endpoint": f"{ISSUER}/oauth/register",
            "client_id_metadata_document_supported": True,
            "token_endpoint_auth_methods_supported": ["none", "client_secret_post"],
            "code_challenge_methods_supported": ["S256"],   # WYMAGANE
            "scopes_supported": SCOPES,
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "authorization_response_iss_parameter_supported": True,
        })

    # ── DCR ──────────────────────────────────────────────────────────────────
    def _dcr(self):
        meta = self._form_or_json()
        redirects = meta.get("redirect_uris") or []
        if not isinstance(redirects, list) or not redirects:
            self._err(400, "invalid_client_metadata", "redirect_uris required")
            return
        for r in redirects:
            if not (r == CHATGPT_REDIRECT or r.startswith("https://chatgpt.com/connector/oauth/")
                    or r.startswith(("http://localhost", "http://127.0.0.1"))):
                self._err(400, "invalid_redirect_uri", f"not allowed: {r}")
                return
        cid = STORE.put_client({"redirect_uris": redirects,
                                "client_name": meta.get("client_name", "client")})
        self._json(201, {"client_id": cid, "client_id_issued_at": int(time.time()),
                         "redirect_uris": redirects,
                         "token_endpoint_auth_method": "none",
                         "grant_types": ["authorization_code", "refresh_token"],
                         "response_types": ["code"]})

    # ── authorize ────────────────────────────────────────────────────────────
    def _authorize(self, q):
        client_id = q.get("client_id", "")
        redirect = q.get("redirect_uri", "")
        state = q.get("state", "")
        challenge = q.get("code_challenge", "")
        method = q.get("code_challenge_method", "")
        resource = q.get("resource", RESOURCE)
        scope = q.get("scope", " ".join(SCOPES))

        cmeta = STORE.get_client(client_id)
        if cmeta is None:
            if client_id.startswith("https://"):     # CIMD
                cmeta = {"redirect_uris": [redirect]}
            else:
                self._err(400, "invalid_client", "unknown client_id")
                return
        if redirect not in cmeta.get("redirect_uris", []):
            self._err(400, "invalid_request", "redirect_uri not registered")
            return
        if method != "S256" or not challenge:
            self._redirect_err(redirect, state, "invalid_request", "PKCE S256 required")
            return

        code = secrets.token_urlsafe(32)
        STORE.put_code(code, {"client_id": client_id, "redirect_uri": redirect,
                              "challenge": challenge, "resource": resource,
                              "scope": scope, "exp": time.time() + CODE_TTL})
        params = {"code": code, "state": state, "iss": ISSUER}   # iss = RFC 9207
        # AUTO-APPROVE: klient automatyczny followuje redirecty — 200 HTML =
        # flow pada. Tylko zarejestrowany redirect przechodzi tu.
        if q.get("prompt") != "consent":
            self._redirect(redirect + "?" + urlencode(params))
            return
        self._consent_page(q)

    def _consent_page(self, q):
        raw = (b"<!doctype html><html><body><h1>Autoryzacja</h1>"
               b"<form method=POST action=/oauth/authorize>"
               b"<button name=decision value=allow>Zezwol</button>"
               b"<button name=decision value=deny>Odmow</button></form></body></html>")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self._cors()
        self.end_headers()
        self.wfile.write(raw)

    def _redirect(self, url):
        self.send_response(302)
        self.send_header("Location", url)
        self.send_header("Content-Length", "0")
        self._cors()
        self.end_headers()

    def _redirect_err(self, redirect, state, err, desc):
        self._redirect(redirect + "?" + urlencode(
            {"error": err, "error_description": desc, "state": state, "iss": ISSUER}))

    # ── token ────────────────────────────────────────────────────────────────
    def _token(self):
        form = self._form_or_json()
        grant = form.get("grant_type", "")
        if grant == "authorization_code":
            data = STORE.pop_code(form.get("code", ""))
            if not data or data["exp"] < time.time():
                self._err(400, "invalid_grant", "code unknown or expired")
                return
            if form.get("client_id") and form["client_id"] != data["client_id"]:
                self._err(400, "invalid_grant", "client mismatch")
                return
            if data["redirect_uri"] != form.get("redirect_uri"):
                self._err(400, "invalid_grant", "redirect_uri mismatch")
                return
            if not pkce_ok(form.get("code_verifier", ""), data["challenge"], "S256"):
                self._err(400, "invalid_grant", "PKCE verification failed")
                return
            aud = data["resource"] or RESOURCE
            access = make_token(aud, data["scope"], "user", ACCESS_TTL)
            refresh = secrets.token_urlsafe(40)
            STORE.put_refresh(refresh, {"aud": aud, "scope": data["scope"],
                                        "sub": "user", "client_id": data["client_id"]})
            self._json(200, {"access_token": access, "token_type": "Bearer",
                             "expires_in": ACCESS_TTL, "refresh_token": refresh,
                             "scope": data["scope"]},
                       extra={"Cache-Control": "no-store"})
            return
        if grant == "refresh_token":
            rec = STORE.get_refresh(form.get("refresh_token", ""))
            if not rec:
                self._err(400, "invalid_grant", "refresh token unknown")
                return
            self._json(200, {"access_token": make_token(rec["aud"], rec["scope"],
                                                        rec["sub"], ACCESS_TTL),
                             "token_type": "Bearer", "expires_in": ACCESS_TTL,
                             "scope": rec["scope"]},
                       extra={"Cache-Control": "no-store"})
            return
        self._err(400, "unsupported_grant_type", grant)

    # ── RS: proxy ────────────────────────────────────────────────────────────
    def _unauthorized(self, why="invalid_token"):
        self._drain_body()                    # NAPRAWA A — inaczej 501 naprzemiennie
        self._json(401, {"error": why}, extra={
            "WWW-Authenticate": (
                f'Bearer resource_metadata="{RESOURCE}/.well-known/oauth-protected-resource", '
                f'scope="{" ".join(SCOPES)}"')})

    def _proxy_mcp(self, method):
        auth = self.headers.get("Authorization", "")
        tok = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
        if verify_token(tok, expected_aud=RESOURCE) is None:
            if not (tok and tok == upstream_token()):
                self._unauthorized()
                return
        raw = self._read_body()
        req = urllib.request.Request(UPSTREAM + self.path,
                                     data=raw if raw else None, method=method)
        req.add_header("Authorization", f"Bearer {upstream_token()}")
        req.add_header("Content-Type", self.headers.get("Content-Type", "application/json"))
        req.add_header("Accept", self.headers.get("Accept", "application/json, text/event-stream"))
        for h in ("mcp-protocol-version", "mcp-session-id"):
            if self.headers.get(h):
                req.add_header(h, self.headers[h])
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = resp.read()
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() not in ("content-length", "transfer-encoding", "connection"):
                        self.send_header(k, v)
                self.send_header("Content-Length", str(len(body)))
                self._cors()
                self.end_headers()
                self.wfile.write(body)
        except urllib.error.HTTPError as e:
            body = e.read()
            self.send_response(e.code)
            self.send_header("Content-Length", str(len(body)))
            self._cors()
            self.end_headers()
            self.wfile.write(body)
        except Exception:
            self._err(502, "upstream_error", "MCP upstream unavailable")

    def _health(self):
        self._json(200, {"status": "ok", "issuer": ISSUER, "resource": RESOURCE,
                         "upstream": UPSTREAM,
                         "upstream_token": bool(upstream_token())})

    def _metrics(self):
        raw = (b"# TYPE mcp_oauth_up gauge\nmcp_oauth_up 1\n"
               b"# TYPE mcp_oauth_upstream_ok gauge\n"
               + f"mcp_oauth_upstream_ok {1 if upstream_token() else 0}\n".encode())
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    # ── routing ──────────────────────────────────────────────────────────────
    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/.well-known/oauth-protected-resource",
                    "/.well-known/oauth-protected-resource/mcp/message"):
            self._protected_resource()
        elif path in ("/.well-known/oauth-authorization-server",
                      "/.well-known/openid-configuration"):
            self._auth_meta()
        elif path == "/oauth/authorize":
            q = {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}
            # NIE wolaj wprost _consent_page — inaczej GET nigdy nie wyda kodu.
            self._authorize(q)
        elif path in ("/health", "/healthz"):
            self._health()
        elif path == "/metrics":
            self._metrics()
        elif path.startswith(("/mcp/message", "/sse")):
            self._proxy_mcp("GET")
        else:
            self._err(404, "not_found", path)

    def do_POST(self):
        self._body_read = False                    # reset per-zadanie
        self._handle_expect_100()                  # NAPRAWA C
        path = urlparse(self.path).path
        if path == "/oauth/register":
            self._dcr()
        elif path == "/oauth/authorize":
            form = self._form_or_json()
            if form.get("decision") != "allow":
                self._err(403, "access_denied")
                return
            self._authorize(form)
        elif path == "/oauth/token":
            self._token()
        elif path.startswith("/mcp"):
            self._proxy_mcp("POST")
        else:
            self._err(404, "not_found", path)

    def do_DELETE(self):
        self._body_read = False
        self._handle_expect_100()
        self._proxy_mcp("DELETE")


def main():
    srv = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    srv.daemon_threads = True
    print(f"[mcp-oauth-gate] :{LISTEN_PORT} issuer={ISSUER} upstream={UPSTREAM} "
          f"token={'yes' if upstream_token() else 'MISSING'}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
