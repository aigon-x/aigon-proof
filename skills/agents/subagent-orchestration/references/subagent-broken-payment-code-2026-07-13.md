# Subagent produces structurally broken payment code

**Date:** 2026-07-13  
**Repo:** <workspace>/products/aigon-code  
**Lesson class:** `delegate_task` leaf subagent returned `status=completed` but the generated Stripe checkout code would not compile and relied on non-existent helper functions.

## What happened

Two leaf subagents were dispatched in parallel:
1. Move AIGON Code capability pricing from hardcoded Rust into a DB table.
2. Make Stripe checkout create dynamic `Product` + `Price` objects when `product_name` is provided.

The second subagent modified `backend-rs/src/handlers/payments.rs` and:
- Called `find_or_create_stripe_product(...)` and `create_stripe_price(...)` without defining them.
- Left an unclosed delimiter around the `amount_cents < 200` check.
- Returned `status=completed`.

Parent verification immediately failed:
- `cargo clippy`: "cannot find function `find_or_create_stripe_product` in this scope" + unclosed delimiter.

## Recovery

1. Run canonical verification before trusting completion:
   ```bash
   cd <workspace>/products/aigon-code/backend-rs
   cargo clippy -- -D warnings && cargo test --lib
   ```
2. Read the error transcript and the changed file.
3. Implement the missing helpers directly in `payments.rs`:
   - `find_or_create_stripe_product(http, secret_key, name, description)`
   - `create_stripe_price(http, secret_key, product_id, amount_cents, currency)`
4. Fix syntax (closed delimiter, quoting in Stripe search query).
5. Re-run verification.
6. Clean untrusted subagent artifacts (e.g., an integration test that imported a now-private function) before committing.

## Key takeaways

- A subagent can report `completed` while producing non-compiling code.
- Payment/billing subsystems are high-risk for this because dynamic Stripe IDs, product lookup, and metadata must align exactly.
- Always pair subagent delegation with a parent-side build/test gate.
- When the fix is faster to write than to re-delegate, do it manually and do not re-dispatch a broken prompt.

## Verification commands used

```bash
cargo clippy -- -D warnings
cargo test --lib
```
