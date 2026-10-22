# Friction log — building an MCP server for the Amazon Developer Hackathon

Real issues met while implementing and validating AIGON PROOF, with workarounds and suggestions.
Kept short and specific so the platform team can act on each entry.

## 1. MCP Streamable HTTP rejects non-loopback Host headers
`rmcp` 3.6 defaults `allowed_hosts` to loopback. Behind a tunnel the server answered
`Forbidden: Host header is not allowed` until we populated the allowlist.
**Workaround:** `AIGON_ALLOWED_HOSTS` env with the public hostname.
**Suggestion:** document the default and the env in the Streamable HTTP quickstart; the error text is
good but appears only after deployment.

## 2. Protocol revision drift
Our first build negotiated `2025-03-26`; the hackathon requires `2025-11-25`. The older SDK silently
picked the older revision.
**Workaround:** upgraded to `rmcp` 3.6 and asserted the negotiated version in a test.
**Suggestion:** expose the negotiated version on a health endpoint so CI can fail fast.

## 3. Write auth is not part of the transport contract
The spec leaves authorization to the application; a public demo with a POST endpoint is an
unauthenticated execution surface.
**Workaround:** all non-GET requests require `X-API-Key` when configured; execution (`gates_run`) is
disabled unless `AIGON_ALLOW_RUN=1`, and it runs only allowlisted scripts with a 20 s kill.

## 4. Tool schemas can hide required context
`create_project` returns `hackathon_subdomain is required — set the hackathon in the context first`,
but no listed tool sets that context (`show_hackathon_stepper` accepts only `active_step`/`build_step`).
**Suggestion:** either accept `hackathon_subdomain` on `create_project` or add an explicit
`select_hackathon` tool.

## 5. Devpost `register_for_hackathon` rejects a valid form
For `amazonappdev2026` every combination of documented arguments returns
`Registration field values value can't be blank` — including the four required dropdowns with exact
option strings, eligibility and rules consent.
**Suggestion:** return the offending `registration_field_id` in the error, and include the field ids
in `get_registration_form` under the same key the registration call expects.

## 6. Publishing prompt corpora trips push protection
Bundling 53 curated `SKILL.md` files surfaced Vault, Cloudflare and default device credentials inside
documentation. GitHub push protection blocked three times.
**Workaround:** gitleaks scan, redaction to `[REDACTED_*]` / `admin:<PASSWORD>`, index rehash, history
rewrite, then a fresh-clone scan.
**Suggestion:** a documented recipe for redacting and rehashing prompt corpora before publishing.

## 7. Gated Alexa+ tooling is unreachable for individual entrants
The FAQ states the Category SDK, MCP Toolkit, CLI and Web Simulator are "available to select
partners only" and that there is "no way for hackathon participants to apply". The Alexа+ track
therefore has to be built and demonstrated as a self-hosted MCP server or a simulation.
**Workaround:** implemented the track as a self-hosted MCP server over Streamable HTTP (rmcp 3.6,
protocol 2025-11-25) and documented a browser simulation; no gated SDK used.
**Suggestion:** publish a public, rate-limited MCP simulator endpoint, or an explicit "self-hosted
is the supported path" note at the top of the track page instead of inside the FAQ.
