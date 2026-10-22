# secrets-management

> **STATUS: ACTIVE** — README contract (STR-001/STR-002/STR-003), certyfikacja PROD-READY.

## 1. Purpose
modułu platformy AIGON-X Cel: utrzymanie spójnej, certyfikowalnej struktury (katalog) w kanonicznym drzewie <workspace>.

## 2. Owner
`@template/platform` (single-owner Source of Truth).

## 3. Source of Truth
Git (desired state). `skills/shared/secrets-management` jest częścią kanonicznego drzewa <workspace> — stan pożądany w Git, stan faktyczny w Runtime.

## 4. Contains
Zawartość `skills/shared/secrets-management`: pliki źródłowe, konfiguracje, szablony i dokumentacja specyficzna dla katalog.

## 5. Does Not Contain
Sekrety, runtime state, wygenerowane artefakty (te żyją poza Git lub w katalogach GENERATED — np. `config/generated/`, `artifacts/`).

## 6. Dependencies
Katalogi nadrzędne i współdzielone moduły <workspace>: `config` (kanon), `core`, `tools`, `runtime`, `scripts`.

## 7. Consumers
Runtime AIGON-X, narzędzia weryfikacji (`tools/verify/`), operatory i agenty (Qwen/Claude/Hermes/aigon-code).

## 8. Synchronization
`CANONICAL` — synchronizowane z Git; propagacja przez kanoniczne skrypty sync (`scripts/sync-*.sh`). Zero ręcznych transferów plików między nodami.

## 9. Lifecycle
Powstaje z Git, zmienia się przez PR/commit, wycofywany przez usunięcie z Git. Zmiany weryfikowane gate'ami certyfikacji.

## 10. Security
Klasyfikacja danych: SYSTEM. Brak sekretów — sekrety poza Git (SECRET_REFERENCE, Vault). Nie logować kluczy ani danych wrażliwych.

## 11. Recovery
Odzysk z Git (desired state). Restart/rebuild z kanonicznego drzewa — brak stanu lokalnego do odtwarzania.

## 12. Drift Detection
Porównanie Git (desired) vs Runtime (actual) przez `tools/verify/` + `system/control-plane/state/` (StateStore, evidence).

> STATUS: ACTIVE — README contract (STR-002/STR-003), certyfikacja PROD-READY.
