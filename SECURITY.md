# Security boundaries — AIGON PROOF v2

Single-host workflow with real local delivery of registered fictional/public documents.
No email or client-account access is claimed.

## Enforced

- Strict command grammar/JSON; classification, document content and trust boundary are server-owned.
- Personal external delivery is blocked, including when an operator tries to approve it.
- Every execution needs authenticated consent bound to actor, operation, exact content and recipient.
- Operator authority is a privately generated random credential, not a username or `apr-42`.
  No MCP agent tool grants human consent. Approvals expire after five minutes; denial revokes
  previous approval for the same action.
- HMAC-SHA256 passports bind approval, action, identity, recipient, times and random nonce.
- Verify is read-only. Execute durably reserves nonce AND approval before side effects.
  Multiple passports under one approval cannot execute twice; replay history survives restart.
- A receipt follows file write, fsync, SHA-256 read-back and durable state persistence.
- Private state, atomic rename/fsync, symlink rejection, one-process state lock.
- Delivered-content/history APIs require operator authentication. Credentials are not in passports.
- Host allowlist; optional additional X-API-Key; HTTP body limit 64 KiB.
- Gate script execution remains separately allowlisted and disabled by default.

## Failures

Interrupted I/O leaves authorization consumed even without a completed receipt. Inspect inboxes
and obtain new consent; never blindly retry uncertain side effects. Corrupt state fails startup
rather than resetting history. Losing/changing the signing key invalidates old passports.

## Limits

Single-operator local credential, not SSO/MFA. Host administrators who can read private state
can obtain keys. File locking requires a local filesystem; no distributed consensus is claimed.
Synchronous fsync/JSON state target low-throughput demonstration, not a high-load production SLO.
Classification is a curated catalog, not automated DLP. No keyword filter is presented as universal
prompt-injection immunity. HMAC has an RFC4231 test vector; independent review/fuzzing remain future work.
Public hosting requires HTTPS, allowed-host configuration and private credentials. The browser
retains its credential in tab memory; Lock removes it. A passport is a capability until consumed.

Historical scans are not fresh certification. Current regression/browser results live in EVIDENCE.md.

```sh
cargo fmt --check
cargo clippy --release --all-targets -- -D warnings
cargo test --release --locked
```
