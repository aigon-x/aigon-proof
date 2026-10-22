# Subagent syntax/defect cleanup checklist

Real session: AIGON-X / aigon-code, 2026-07-13.
A subagent completed two tasks in parallel (capability-pricing DB/admin API + Stripe dynamic products).
Despite `status=completed`, the parent had to fix several defects before `cargo clippy -- -D warnings` passed.

## Defects found after subagent "success"

1. **`backend-rs/src/handlers/payments.rs`**
   - Calls to `find_or_create_stripe_product()` and `create_stripe_price()` were added, but the helper functions were not defined.
   - An `if` block was left without a closing brace (`if req.amount_cents < 200 { return Err(...) ; let credits = ...`).

2. **`backend-rs/src/routes.rs`**
   - Subagent added `.delete(admin::admin_delete_capability_pricing)` on a `Router` chain and imported `delete` from `axum::routing`.
   - `delete` from `axum::routing` is a function-level builder, not needed for the `Router::delete()` method, producing an unused-import lint.

3. **`backend-rs/src/db.rs`**
   - Empty line between a section-header doc comment and the next doc comment triggered `clippy::empty-line-after-doc-comments`.

4. **`backend-rs/src/handlers/admin.rs`**
   - Leftover imports: `sqlx::PgPool` and `bad_request` were declared but never used.

## Takeaway

After a subagent batch finishes, run the strict linters **before** tests:

```bash
cargo clippy -- -D warnings
npx tsc --noEmit
```

If new defects appear, fix them in the parent session instead of trusting the subagent's "completed" flag.
