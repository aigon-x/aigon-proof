# Szablon: Backend / mikrousługa (Node/FastAPI/Rust-Axum)

## 1. Cel usługi
- Co robi, port, kto ją woła.

## 2. Technologia
- [Node/TS | Python/FastAPI | Rust/Axum], wersja, kluczowe deps (pyproject/package.json/Cargo.toml).

## 3. API (pełna powierzchnia)
- Lista endpointów (metoda, ścieżka, cel), auth (JWT/API-key), błędy.
- OpenAPI/Swagger URL (jeśli jest).

## 4. Model danych
- Tabele (schema, kolumny, relacje), które są źródłem prawdy.
- Migracje/seed (gdzie, kiedy).

## 5. Logika / pipeline
- Kluczowe przepływy (np. scraper→DB, scoring, scheduler).
- Harmonogram/cron/tick (interwał, co odpala).

## 6. Konfiguracja
- Zmienne env (nazwa, rola, skąd), .env/secret manager (Vault).

## 7. Build & deploy
- Dockerfile, compose (profile, porty, healthcheck), build/deploy komendy.

## 8. Bezpieczeństwo
- Auth (JWT/API-key), co chronione, co publiczne, sekrety (z Vault, nie hardkod).

## 9. Obserwowalność
- OTel (service.name, trace), /metrics (Prometheus), logi (gdzie).

## 10. Testy
- Unit/integration, jak uruchomić, co pokryte.

## 11. Stan budowy + pułapki
- ✅/⬜/🟡, co jest KANONICZNE (nie usuwać), znane luki.
