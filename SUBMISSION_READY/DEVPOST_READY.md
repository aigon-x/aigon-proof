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

Repository: https://github.com/aigon-x/aigon-proof
