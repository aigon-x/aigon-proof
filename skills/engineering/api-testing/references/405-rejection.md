# 405 Method Not Allowed on /api/v1/auth/register

**Context**:
- A POST request to `/api/v1/auth/register` returned HTTP 405.
- The server expected a different HTTP method or routing was missing.
- Likely the API route wasn’t registered for POST or required auth.

**Diagnostic steps**:
1. Verify route definition in the codebase (`src/routes/mod.rs`).
2. Check if the server receives a GET/PUT to that endpoint.
3. Confirm API documentation or swagger output reflects the POST method.
4. Review logs for route registration errors.
5. Ensure the request contains required headers (`Content-Type: application/json`).

**Remediation**:
- Add the missing `POST` route or adjust the handler to support POST.
- If auth is required, provide valid credentials or disable auth for public registration.
- Deploy updated API and re-test with curl.

**Testing**:
```bash
curl -X POST http://<host>/api/v1/auth/register -H 'Content-Type:application/json' -d '{"email":"a@b.c","password":"<PASSWORD>"}"
```