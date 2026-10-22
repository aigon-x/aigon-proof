# Contributing to AIGON PROOF

Thanks for taking the time to look at this project. PROOF is a small, self-contained
service, so the rules are short and mechanical.

## Before you start

- Rust **1.89 or newer**, Linux or macOS.
- Read `README.md` for the quickstart and `docs/security/THREAT_MODEL.md` for the trust
  boundary. The default build needs no cloud account and no model weights.

## Local checks (same as CI)

```sh
cargo fmt --check
cargo clippy --release --all-targets --locked -- -D warnings
cargo test --release --locked
cargo build --release --locked
```

A change is ready when all four pass locally. CI runs the same commands plus an
end-to-end browser and prompt-injection check, so a green local run is necessary but
not sufficient.

## Pull requests

1. Keep a pull request to one concern; describe the observable behaviour that changes.
2. Add or adjust a test for every behaviour change. Security-relevant changes need a
   negative test that fails before the fix.
3. Do not weaken an invariant to make a test pass. If an invariant is wrong, say so in
   the pull request and explain the replacement.
4. Update `EVIDENCE.md` when you add a measurement, and `SECURITY.md` when you change
   the trust boundary.

## Invariants that must not regress

- Human approval is separate from the MCP agent plane; no tool can mint consent.
- A passport authorizes exactly one action, bound to actor, operation, document bytes,
  recipient and trust boundary.
- Execution consumes the approval; a retried or replayed request must fail.
- A failed write never reports success.
- Denials are recorded, not silently rewritten into a different action.

## Reporting a security issue

Do not open a public issue. Follow `SECURITY.md`.

## License

Contributions are accepted under the MIT license (see `LICENSE`).
