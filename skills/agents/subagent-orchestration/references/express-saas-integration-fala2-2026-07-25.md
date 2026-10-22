# Express SaaS Integration — FALA 2 Pattern

## Context

Magic Proxy SaaS (project 120), FALA 1 generated ~11 independent subagent modules under `src/` (tenants, store, providers, evidence, billing, api, dashboard, observability, pipeline). FALA 2 required wiring all modules into the existing Express `server.ts` entrypoint.

## Key Challenge

Subagent modules compile and test independently, but their **export shapes** (constructor params, middleware signatures, expected deps) are not standardised. The integration step must read every module's actual exports before wiring.

## Wave 0 — Read All Exports

Read these files BEFORE any edits:

| File | What to check |
|------|---------------|
| `src/api/router.ts` | What does `createAdminApiRouter()` need? What prefix does it mount at? |
| `src/dashboard/server.ts` | What deps does `DashboardDeps` require? Where is the secret injected? |
| `src/billing/webhook.ts` | Does it need `express.raw()`? What's the webhook config shape? |
| `src/tenants/resolve.ts` | What does `resolveApiKey()` return? Does it use `***` as placeholder type? |
| `src/store/rateLimiter.ts` | Is it Express middleware `(req,res,next)` or a factory? |
| `src/store/usage.ts` | Write-behind API — sync or async? What returns from `recordUsage()`? |
| `src/store/waf.ts` | Middleware order — before or after rate limiter? |
| `src/evidence/pgLedger.ts` | How to init? Constructor or factory? Does it need pool config? |

## Wave 1 — Create New Files (Parallel)

Files created in parallel, no cross-dependencies:

1. `src/http/saasMiddleware.ts` — tenant resolution middleware: `x-api-key` header → `resolveApiKey()` → inject `req.tenant`. Rate-limit via WAF/rateLimiter. Return 401 for unknown key, 429 for rate limit.

2. `src/http/health.ts` — extended /health endpoint: checks DB (pg), Redis, provider health, router connectivity, returns degradation map (not just `status: 'ok'`).

## Wave 2 — Extend Entrypoints (Sequential per File)

### handler.ts

Inject tenant context into `buildContext()`:

```ts
// Before handler runs
const tenant = (req as any).tenant; // from saasMiddleware
ctx.tenantId = tenant?.id;
ctx.tenantPlan = tenant?.plan;
```

Wire metering after response:

```ts
if (tenant && usage) {
  await recordUsage({
    tenantId: tenant.id,
    tokens: totalTokens,
    endpoint: '/v1/chat/completions',
    timestamp: new Date(),
  });
}
```

Wire evidence PG for audit trail after response.

### server.ts

Mount SaaS routes in this order:

```ts
// 1. Stripe webhook (needs raw body BEFORE json parser)
app.use((req, res, next) => {
  if (req.path === '/stripe/webhook') {
    express.raw({ type: 'application/json' })(req, res, next);
  } else {
    express.json()(req, res, next);
  }
});

// 2. Existing security middleware (helmet, cors, rate-limit, api key gate)

// 3. SaaS tenant middleware (before chat routes)
app.use(saasMiddleware);

// 4. SaaS admin API
app.use('/api', createAdminApiRouter());

// 5. Stripe webhook route
app.post('/stripe/webhook', stripeWebhookHandler);

// 6. Dashboard
app.use('/dashboard', createDashboardRouter(deps));

// 7. Existing chat routes
// POST /v1/chat/completions — handler now has req.tenant
```

### server.ts Bootstrap

Instantiate SaaS dependencies:

```ts
import { createAdminApiRouter } from './api/router.js';
import { createDashboardRouter } from './dashboard/server.js';
import { handleStripeWebhook } from './billing/webhook.js';
import { createWAF } from './store/waf.js';
import { createTenantMiddleware } from './http/saasMiddleware.js';
```

## Defects Found in Subagent Output (this session)

1. **`***` placeholders** — `src/tenants/resolve.ts` had `apiKey: ***` and `apiKey: ***` as parameter type. Neither is valid TypeScript. **Fix:** Replace with `string`.

2. **Pre-existing `config...iKey`** — `src/http/server.ts` lines 44, 51 had `config...iKey || undefined` (double dot). Pre-dated our changes but would break compilation.

3. **VerifyAuditChain hash mismatch** — `recordAudit` included `hash: ''` in JSON before computing hash; verify stripped `hash` before recomputing. Payloads differed by one key. Caught only by full test suite.

4. **Stripe raw body** — `billing/webhook.ts` needs `req.body` as raw Buffer for signature verification. If mounted after `express.json()`, `req.body` is already parsed — webhook always returns 400.

## Verification

After all changes:
```bash
npm run typecheck           # 0 errors
npm test                    # 279/279 passing
```

The test suite (13 files) catches the hash-chain payload bug that typecheck misses. Always run full tests.
