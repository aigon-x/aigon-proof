## What changes

<!-- One paragraph: the observable behaviour that changes, not the file list. -->

## Why

<!-- The problem, incident or requirement this addresses. -->

## Invariants

- [ ] Human approval still cannot be minted by an agent tool
- [ ] A passport still authorizes exactly one action, bound to the reviewed bytes and recipient
- [ ] Replay and retry still fail after execution
- [ ] A failed write still never reports success

## Verification

<!-- Paste the commands you ran and their result. "CI will tell" is not verification. -->

```sh
cargo fmt --check
cargo clippy --release --all-targets --locked -- -D warnings
cargo test --release --locked
```

## Risk

<!-- What could break in production, and how a reviewer can falsify your claim. -->
