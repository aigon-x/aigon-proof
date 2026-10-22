# Szablon: Frontend web (React/Next.js)

## 1. PRD / spec
- Cel, odbiorca, kluczowe funkcje, MVP.

## 2. Architektura
- Framework: [Next.js 14 / React] | Router: [App Router]
- Struktura: `src/app`, `src/components`, `src/lib`, `src/api`
- Stan: [Zustand/Redux/Context] | Data fetching: [SWR/React Query/SSR]
- SSR/ISR/CSR — co gdzie.

## 3. Tech stack
- Wersje (package.json), kluczowe deps, UI kit (Tailwind/Shadcn).

## 4. API / backend
- `NEXT_PUBLIC_API_URL`, proxy/rewrites, endpointy, auth (JWT/API-key).
- Jak frontend woła backend (serwer vs klient, cookie vs Bearer).

## 5. Bezpieczeństwo
- CSP, CORS, cookies (HttpOnly/SameSite), XSS (dangerouslySetInnerHTML).
- Env: co jest NEXT_PUBLIC (jawne) vs serwerowe (tajne).

## 6. Build & deploy
- `npm ci && npm test && npm run build` (standalone), Dockerfile.
- Deploy (docker compose / nginx), cache-busting, CF purge.

## 7. Testy
- Vitest/Jest (unit), Playwright (e2e), co pokryte.

## 8. Ops
- Healthcheck, logi, OTel (trace), jak debugować.

## 9. Stan budowy
- ✅/⬜/🟡 per funkcja, znane luki.
