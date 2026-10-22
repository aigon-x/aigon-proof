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

## Significant updates during the Submission Period
Between 31 Aug and 23 Oct 2026 this project gained: an exact typed action contract replacing heuristic text parsing; operator-authenticated human approval bound to actor, operation, exact content and recipient; signed capability passports with one-approval-one-execution semantics; durable replay rejection across restarts; fsync + SHA-256 read-back receipts of delivered bytes; a Streamable HTTP MCP transport alongside stdio; and a governance explorer exposing bundled laws, gates and curated skills. The recorded demo shows the approval, the blocked case and the tampered-recipient case.
