# AIGON PROOF — Approve the action. Verify the outcome.

**Tagline:** Human-approved AI actions, signed authorization, and a receipt for the work actually done.
**Primary track:** Alexa+ — self-hosted MCP, Streamable HTTP, protocol 2025-11-25.

## Inspiration
An assistant saying “done” is not evidence of permission or execution. A human must know
exactly what is being approved, and a changed document or recipient must invalidate consent.

## What it does
PROOF governs real local document delivery. A structured command identifies a document and
recipient; the server resolves classification and trust boundary. Sensitive external delivery
is blocked. A policy-compliant action waits for authenticated human approval bound to the
reviewed actor, operation, exact content and recipient. Only then is a passport signed.
Execution writes actual bytes to the registered local inbox and returns a durable receipt
after fsync and SHA-256 read-back. Replay and altered recipients are rejected, including after restart.

## How we built it
Rust, Tokio, Axum, rmcp 3.6, MCP 2025-11-25, HMAC-SHA256 and durable file-backed state.
The browser offers typed commands and document/recipient controls. It never guesses consent,
invents approval IDs or secretly substitutes another action. Human approval is separate from
the MCP agent plane. The governance explorer exposes bundled laws, gates and curated skills.

## Challenges and accomplishments
We replaced heuristic text parsing and synthetic consent with an exact action contract and
operator authentication. We separated verification from execution, persisted replay state,
prevented one approval from authorizing multiple passports, and independently checked actual
delivered bytes. The current film records this workflow, including negative cases.

## Security as added value
PROOF enforces approval independently of the assistant's instructions. Server-owned actions,
exact human consent, signed capabilities, durable replay protection and receipt read-back make
attempted prompt injection unable to become execution authority. Reviewed corpus hashes reject
changed bundled reference assets. Our reproducible security assessment covers forged consent,
command and metadata injection, recipient substitution, replay, retrieval-file poisoning,
browser request boundaries, static analysis, dependency advisories and public-history secret scans.
The assessment is a self-review with explicit scope and evidence, not a third-party certification
or a claim that every model resists jailbreaks.

## Training and model weights
The default release is model-free and has no training pipeline. Optional neural retrieval can
load an embedding model only through an explicitly enabled feature. Training-data provenance,
poisoned-dataset evaluation, approved model/tokenizer hashes, private caches and tampered-weight
rejection are documented requirements for a future extension; these controls are not advertised
as completed model-security tests. Approval and execution boundaries remain separate from models.

## What we learned
A signed permission is not a receipt. Reliability requires exact human review, observed side
effects, and retaining reservations when a process dies between authorization and recording delivery.

## What's next
Enterprise identity providers, reviewed executor adapters, multi-host transactions and
independent security review. The current executor deliberately only delivers to local inboxes.

## Built with
Rust, Tokio, Axum, rmcp, serde, sha2, OpenTelemetry; optional fastembed governance retrieval.

## Scope
A runnable single-host prototype using fictional/public sample documents. No email, real client
accounts or native Alexa+ Preview integration. MCP agents supply typed actions; PROOF is not
its own natural-language model. Product feedback and friction log accompany this submission.

Security scope: https://github.com/aigon-x/aigon-proof/blob/main/SECURITY.md
Repository: https://github.com/aigon-x/aigon-proof

## Built during the Submission Period
This project is new: the public repository was created on 22 October 2026, inside the Submission Period,
and by the submission date it includes: an exact typed action contract replacing heuristic text parsing; operator-authenticated human approval bound to actor, operation, exact content and recipient; signed capability passports with one-approval-one-execution semantics; durable replay rejection across restarts; fsync + SHA-256 read-back receipts of delivered bytes; a Streamable HTTP MCP transport alongside stdio; and a governance explorer exposing bundled laws, gates and curated skills. The recorded demo shows the approval, the blocked case and the tampered-recipient case.

## Product feedback (tools, APIs, SDKs)

# Amazon Developer Hackathon — Product Feedback

## Which tools, APIs and SDKs did you use?
AIGON PROOF implements the Alexa+ track's self-hosted Model Context Protocol route: official Rust rmcp SDK 3.6, Streamable HTTP transport and protocol 2025-11-25. Tokio and Axum supply the HTTP server; serde represents typed requests. The browser demo is an Alexa+-style simulation, not a native preview integration. SHA-256/HMAC signs demonstration action passports and OpenTelemetry captures instrumented operations.

## What worked well?
MCP tools provide a consistent contract for a policy service, and the Rust SDK makes it possible to expose the same engine through standard MCP and a web explorer. The standalone fixture bundle makes external evaluation realistic without internal AIGON files.

## What needs work?
SDK versions and protocol revisions require careful migration. A simple official end-to-end example of Streamable HTTP with authentication, user approval, tool permissions and safe negative tests would greatly reduce developer uncertainty. Teams without Alexa+ Preview access would benefit from an official local MCP simulator.

## How was onboarding?
The original server used an older protocol and transport, so we migrated to current Streamable HTTP and tested initialization. Making an internal canonical ruleset runnable from a public clone required independent fixture packaging. Please see FRICTION-LOG.md for observed problems rather than treating speculation as measured friction.

## Would you build again with these tools?
Yes. Open MCP is a useful integration boundary for governed agent actions. For production we would add identity-bound human authorization, an audited cryptographic implementation, and persistent distributed replay handling.

## Mini challenges
No AWS production service usage or second qualifying open-source contribution is verified here. Do not submit into those mini challenges unless the relevant evidence and contribution URLs are available.

## Friction log

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

## Mini challenges

**Open Source** — contribution: https://github.com/aigon-x/postcode-sentinel · project: https://github.com/aigon-x/aigon-proof · GitHub: aigon-x

AIGON PROOF itself is MIT-licensed and public. Additionally, during the Submission Period we published a new, separate MIT-licensed open-source project, aigon-x/postcode-sentinel (repository created 2026-10-20): a post-merge risk-review agent for GitLab that parses diffs, scores risk with explained rules and opens merge-request notes or issues in dry-run by default. It is an independent project, not the primary track submission.
