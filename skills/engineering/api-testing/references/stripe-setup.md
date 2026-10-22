# Stripe integration missing

**Context**:
- No Stripe secrets detected in Vault.
- Endpoints for checkout (`/api/v1/checkout`), webhook (`/api/v1/stripe/webhook`) are not configured.
- Likely the application lacks a `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET`.

**Diagnostics**:
1. Verify Vault path `secret/aigon-x/stripe` contains `stripe_secret` and `webhook_secret`.
2. Ensure the application loads these values into its config before server start.
3. Check that environment variable `STRIPE_SECRET_KEY` or config file is set.
4. Confirm that `stripe` crate or SDK is initialized.

**Remediation**:
- Retrieve the Stripe test key from Vault.
- Add it to application config or environment.
- Deploy the updated configuration.
- Re-run the checkout test to ensure a session is created.
