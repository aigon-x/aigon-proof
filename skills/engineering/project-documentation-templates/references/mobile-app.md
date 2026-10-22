# Szablon: Aplikacja mobilna (Android)

> Wypełnij REALNYMI danymi: `AndroidManifest.xml`, `build.gradle`, `Room`, endpointy.

## 1. PRD / spec produktu
- Cel aplikacji: [TU WPISZ]
- Odbiorca/persona: [TU WPISZ]
- Kluczowe funkcje (MVP): [TU WPISZ]
- Roadmapa: [TU WPISZ]

## 2. Architektura techniczna
- Warstwy: UI (Compose/XML) → ViewModel → repository → data source
- Wzorzec: [MVVM/MVI/Clean] | DI: [Hilt/Koin]
- Moduły: [app/core/feature-*]
- Diagram przepływu danych: UI → VM → repo → [Room/Retrofit] → [backend]

## 3. Tech stack + zależności
- Język: [Kotlin/Java] | minSdk: [N] | targetSdk: [N]
- Biblioteki: Room, Retrofit, WorkManager, Compose, [inne]
- Wersje + uzasadnienie wyboru: [TU WPISZ]

## 4. Model danych + storage
- Schemat Room/SQLite (tabele, relacje): [TU WPISZ]
- Preferencje: [DataStore / EncryptedSharedPreferences]
- Szyfrowanie: [SQLCipher / EncryptedSharedPreferences]
- Co lokalnie vs w chmurze + synchronizacja: [TU WPISZ]

## 5. API / kontrakt backendu
- Endpointy (OpenAPI): [TU WPISZ]
- Auth: [JWT / API-key] | modele, błędy, retry/timeout
- TLS/certyfikaty: [TU WPISZ]

## 6. BEZPIECZEŃSTWO + PRYWATNOŚĆ (krytyczne)
- Pełna lista uprawnień + DLACZEGO każde:
  - [ACCESSIBILITY_SERVICE] — [uzasadnienie]
  - [DEVICE_ADMIN] — [uzasadnienie]
  - [FOREGROUND_SERVICE] — [uzasadnienie]
  - [inne]
- Data flow: co appka zbiera → gdzie przechowuje → komu wysyła
- RODO/GDPR: podstawa prawna, administrator, polityka prywatności, zgody
- Google Play **Data Safety form** (musi być zgodny z realnym zbieraniem)
- Obfuskacja: [R8/ProGuard]

## 7. Build & release
- Gradle: build types (debug/release), flavors, signing (keystore + lokalizacja)
- versionCode/versionName: [schemat]
- CI/CD: [pipeline]
- Jak zbudować: [./gradlew assembleRelease / bundleRelease]

## 8. Compliance Play Store (osobno)
- Polityka uprawnień wrażliwych (monitoring/accessibility — ŚCISŁE reguły)
- Content rating, deklaracje, target audience, privacy policy URL
- Co grozi odrzuceniem + jak uzasadnić

## 9. Testy
- Unit (VM/repo): [pokrycie]
- Instrumented (Espresso/Compose Test): [pokrycie]
- Testy na realnym urządzeniu (adb), edge cases (brak uprawnień, doze)

## 10. Operacje / runbook
- Uruchomienie lokalne (emulator/urządzenie): [adb install ...]
- Debug/logi: [adb logcat]
- Środowiska (dev/staging/prod) + zmienne env

## 11. Changelog + decyzje
- ADR-y, historia wersji, znane ograniczenia
