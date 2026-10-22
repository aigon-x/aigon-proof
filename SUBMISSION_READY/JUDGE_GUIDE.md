# AIGON PROOF — judge quickstart

Track: Alexa+, self-hosted MCP over Streamable HTTP, protocol 2025-11-25.
No native Alexa+ Preview integration is claimed.

1. Clone the submitted commit; run `bash scripts/run-demo.sh` (Rust >=1.89).
2. Open http://127.0.0.1:8080/proof. Private credentials are generated on first boot.
3. In a second terminal, `cat .aigon-proof/operator.token`; enter it in Operator access.
4. Review client-contract → external-partner: BLOCK, no approval possible.
5. Review redacted-summary → external-partner: REVIEW. Read the document.
6. Approve once & sign: authenticated consent bound to the reviewed action hash.
7. Test recipient swap: REJECTED. Execute the original: real file and receipt appear.
8. Test replay: REJECTED. Restart, unlock, load history: receipt persists.
9. Try `archive public-brief to records`, denial and a fabricated approval ID.

All documents are fictional/public. Delivery is actual local inbox files, not email.
Inspect `.aigon-proof/inboxes/` and the authenticated content API. Credentials and state
are excluded from Git. Verification never executes; an agent cannot mint human consent.
The governance explorer is `/`; MCP is `POST /mcp`.

Run `cargo fmt --check`, `cargo clippy --release --all-targets -- -D warnings`,
`cargo test --release --locked`. First build may need network for dependencies;
document delivery itself needs no cloud APIs. See README and SECURITY for limits.
