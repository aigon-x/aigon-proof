# AIGON PROOF

**Approve the action. Verify the outcome.**

Built for the Alexa+ track of Build, Ship, Shape: Amazon Developer Hackathon.
Self-hosted MCP, Streamable HTTP, protocol **2025-11-25**. No native Alexa+ Preview integration is claimed.

PROOF turns a structured document action into a human-reviewed authorization,
a signed passport and an independently inspectable delivery receipt.

## Fresh clone quickstart

Rust **1.89 or newer**, Linux/macOS. First build needs network for Rust dependencies
and the ONNX dependency of optional governance search. No cloud subscription or AIGON runtime is required.

```sh
git clone https://github.com/aigon-x/aigon-proof
cd aigon-governance-mcp
bash scripts/run-demo.sh
```

Open **http://127.0.0.1:8080/proof**. In a second terminal:

```sh
cat .aigon-proof/operator.token
```

Enter this private credential in **Operator access → Unlock approval**. The server generates
unique signing and operator keys on first boot, stores them privately in `.aigon-proof/`,
and excludes them from Git. No fixed demo key exists. Never record the credential visibly.

## Complete workflow

1. Review `deliver client-contract to external-partner`: personal external data is **BLOCKED**.
2. Select **Anonymised contract summary**, review: **REVIEW**, no implicit consent.
3. Read the exact content and recipient. Unlock operator access; explicitly **Approve once & sign**.
4. Inspect the passport. **Test recipient swap** must reject changed action parameters.
5. Explicitly **Execute approved action**. Actual document bytes are written to a local recipient inbox.
6. Inspect the receipt and delivered content. SHA-256 read-back verifies what was written.
7. **Test replay rejection**. Restart the server, unlock and load history: records persist.

**Deny action** records a real authenticated denial and revokes earlier approval for the same action.
No blocked request is secretly replaced with a different one. Signing does not execute.

## Commands and server-owned metadata

```text
deliver <document-id> to <recipient-id>
archive <document-id> to records
```

Documents: `client-contract` (fictional personal data), `public-brief`, `redacted-summary`.
Recipients: `legal-team` (internal), `external-partner` (external), `records` (internal).
All are registered **local inboxes**. No email or internet document transmission occurs.

The grammar is explicit, not heuristic natural-language inference. Ambiguous/unknown commands fail.
Server catalog content determines classification and trust scope. Words such as “team” or “summary”
cannot relabel a document or manufacture approval. An MCP agent supplies a typed action; PROOF is
a governance/execution service, not its own natural-language model.

## MCP and HTTP

```sh
AIGON_STANDALONE=1 AIGON_EMBEDDINGS=0 ./target/release/aigon-governance-mcp --http 8080
```

POST `/mcp` with `Accept: application/json, text/event-stream`.
Tools: `proof_catalog`, `proof_parse`, `proof_evaluate`, `proof_issue`, `proof_verify`,
`proof_execute`, `proof_crash_tests`, plus the governance explorer tools.
Human approvals are separate: there is no agent tool for minting operator consent.

Action JSON:
```json
{"actor":"mcp:assistant","operation":"deliver","document_id":"public-brief","recipient_id":"external-partner","approval_id":null}
```

| Route | Purpose |
|---|---|
| GET `/api/proof/catalog` | Documents and recipients |
| POST `/api/proof/parse` | `{command}` → explicit action |
| POST `/api/proof/evaluate` | Action → policy decision and exact hash |
| POST `/api/proof/operator` | Authenticate `X-Operator-Token` |
| POST `/api/proof/approve` | `{action, reviewed_hash, approved}`, operator required |
| POST `/api/proof/issue` | Sign an exactly approved action |
| POST `/api/proof/verify` | `{passport, action}`, read-only |
| POST `/api/proof/execute` | `{passport, action}`, one actual delivery |
| GET `/api/proof/receipts` | Durable history, operator required |
| GET `/api/proof/deliveries/{id}` | Content and integrity check, operator required |
| GET `/api/proof/crash-tests` | Six read-only policy probes |

Approvals expire after five minutes and bind actor, operation, document bytes/classification,
recipient and trust boundary. Verification never consumes. Execution consumes both approval
and nonce; multiple passports under one consent cannot produce multiple deliveries.

## Persistence and failure semantics

State updates use private files, fsync and atomic rename. A process lock prevents sharing one
state directory between servers. Execution durably reserves authorization, writes and reads
back the inbox file, then persists its receipt. A failed write never reports success.
After interrupted I/O a reserved action remains consumed: inspect the inbox and request a new
approval instead of blindly retrying a possibly completed side effect.

## Configuration

| Variable | Default / purpose |
|---|---|
| `AIGON_PROOF_STATE` | `.aigon-proof`, private persistent directory |
| `AIGON_PROOF_KEY` | Optional signing override, >=32 chars; otherwise generated/persisted |
| `AIGON_OPERATOR_TOKEN` | Optional operator override, >=32 chars; otherwise generated/persisted |
| `AIGON_OPERATOR_NAME` | `local-operator`, approver identity in audit records |
| `AIGON_API_KEY` | Optional additional X-API-Key on HTTP writes |
| `AIGON_ALLOWED_HOSTS` | Additional HTTP/MCP hostname allowlist |
| `AIGON_STANDALONE=1` | Bundled canon, no internal AIGON files |
| `AIGON_EMBEDDINGS=0` | Disable optional neural model download |
| `AIGON_ALLOW_RUN=0` | Disable gate script execution, default |

Keep state on a local disk; one server per state directory. Public deployment requires HTTPS,
private operator credentials and a reviewed identity policy. The executor is a single-host,
registered-document prototype, not email, enterprise SSO, automated DLP or distributed consensus.

## Governance explorer and verification

`/` retains searchable laws/gates, context packs, skill metadata and graph.
Standalone bundle: 111 laws, 355 gate definitions, 53 curated skills. Catalog counts do not mean
all bundled gates passed on the evaluator's host.

```sh
cargo fmt --check
cargo clippy --release --all-targets -- -D warnings
cargo test --release --locked
```

Tests cover real consent, forged IDs, metadata spoofing, binding, revocation, expiry,
restart-safe replay, concurrent execution, actual file receipts, corruption and symlinks.
See EVIDENCE.md and SECURITY.md for versioned measurements and limits.

Submission: SUBMISSION_READY/DEVPOST_READY.md, JUDGE_GUIDE.md, PRODUCT_FEEDBACK_AMAZON.md,
FRICTION-LOG.md and video/proof-v2/. A local film is not a Devpost submission receipt.

## License

MIT for original code; LICENSE-NOTICE.md covers bundled notices.

Public demonstration (ElevenLabs Cornelius — Wise Sage): https://www.youtube.com/watch?v=JGI6EiLZ76g
