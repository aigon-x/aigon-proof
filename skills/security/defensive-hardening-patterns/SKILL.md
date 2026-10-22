---
name: defensive-hardening-patterns
description: 'Wzorce DEFENSYWNE (hardening) przeniesione z archiwum /opt/projects/wojsko/z-archiwum-qnap-2026-06-05 (security/ + modules/ — odzysk 2026-09-04) na grunt AIGON-X. Skill APLIKOWALNY: jak wzmocnić runtime (middleware api.rs), produkty i nginx — warstwa wejściowa (SQLi/XSS/command-injection), detekcja zagrożeń (behavioral/ML/EDR), monitoring zdarzeń (CEF/SIEM), hardening bazy (prepared statements, whitelisting query), playbooki reakcji (auto-block IP). Użyj gdy: ''zabezpiecz'', ''wzmocnij'', ''hardening'', ''audyt bezpieczeństwa'', ''SQLi'', ''XSS'', ''threat detection'', ''monitoring zdarzeń'', ''middleware security'' w kontekście runtime AIGON-X lub produktów.'
source: 'wojsko-z-archiwum-qnap-2026-06-05 (odzysk 2026-09-04) — security/ + modules/; kontekst: ANALIZA-REKOMENDACJE.md R4, AUDYT-2026-09-07.md'
allowed-tools: Read, Edit, Write, Glob, Grep, Bash, Skill, Task
---


# Defensive Hardening Patterns — AIGON-X

Skill aplikowalny: wzorce obronne sprawdzone w archiwum wojsko, przeniesione na grunt
AIGON-X. Czytasz opis wzorca + lokalizację w źródle, mapujesz na konkretny element
(runtime api.rs / kernel / produkt / nginx), aplikujesz wg checklisty, audytujesz wg
procedury. CZYSTO DEFENSYWNE — komponenty ofensywne archiwum (weakness/c2/lateral itd.)
są poza zakresem (granica: ANALIZA-REKOMENDACJE.md sekcja 7).

**Jakość źródła (nie dać się zwieść):** archiwum to demo Flask 2.3 + SQLite (port 3006)
z dekoracyjnymi bannerami ("WAR MODE: ACTIVE", "SYSTEM LAW OMEGA: FULL") — deklaracje
README (FastAPI/Postgres/106 agentów) NIE pokrywają się z kodem. Wartością są WZORCE
architektoniczne i listy sygnatur, NIE kod 1:1. `modules/cyber_defense.py` to w dodatku
**stub symulacyjny** (pętla loguje `random.randint` zagrożeń) — wzorzec antywzorcowy
(fake telemetria), patrz sekcja „Czego NIE kopiować".

---

## 1. Wzorce z wojsko (opis + miejsce w kodzie źródłowym)

Źródło: `/opt/projects/wojsko/z-archiwum-qnap-2026-06-05/security/` (9 plików) i
`.../modules/` (defensywne). Kontekst całości: `/opt/projects/wojsko/ANALIZA-REKOMENDACJE.md`
(R4: port SQLi/XSS do `aigon-kernel-yudai`) i `AUDYT-2026-09-07.md` (skany czyste).

### 1.1 Detekcja SQLi — pattern database + scoring ważony
`security/sql_injection_detector.py` (908 l.)
- **Sygnatury klasyfikowane wg typu ataku** — enum `InjectionType`: CLASSIC, BLIND,
  TIME_BASED, UNION, ERROR, STACKED, COMMENT, ENCODED, POLYMORPHIC, ML_ANOMALY.
- **Pattern database** `SQLInjectionPatterns` — listy regex per typ z przypisaną wagą
  (Severity) i opisem: `CLASSIC_PATTERNS` (`'\s*OR\s*'1'\s*=\s*'1`, `admin'\s*--`, tautologie),
  `UNION_PATTERNS` (`UNION SELECT`, `ORDER BY N` enumeracja), `STACKED_PATTERNS`
  (`;\s*DROP TABLE`, `;\s*EXEC`), `COMMENT_PATTERNS` (`--`, `/\*`, `#`), `TIME_BASED_PATTERNS`
  (`SLEEP()`, `WAITFOR DELAY`, `PG_SLEEP`, `DBMS_LOCK.SLEEP`), `ERROR_PATTERNS`
  (`CONVERT(`, `CAST(`, `EXTRACTVALUE`, `UPDATEXML`, `EXP(~`).
- **Scoring ważony:** `PATTERN_MATCH_WEIGHT = 0.8` + `ML_DETECTION_WEIGHT = 0.2` →
  `DetectionResult` (detected, severity, injection_type, confidence, blocked).
- **Progi:** `MAX_REQUESTS_PER_MINUTE = 100`, `BLOCK_THRESHOLD = 3` (detekcje przed
  blokadą), `BLOCK_DURATION_MINUTES = 30`, `ANOMALY_SCORE_THRESHOLD = 0.7`,
  `ALERT_COOLDOWN_SECONDS = 60` (anty-spam alertów dla tej samej encji).
- Singleton `get_detector()` + `get_stats()` (statystyki do /metrics i raportów).

### 1.2 Prewencja SQLi — tryby, walidator, prepared statements
`security/sql_injection_prevention.py` (1218 l.)
- **Tryby prewencji:** `PREVENTION_MODE_STRICT` (default) / `MODERATE` (warn+sanitize) /
  `AUDIT` (tylko log). Akcje `PreventionAction`: ALLOW / BLOCK / SANITIZE / WARN / AUDIT.
- **`QueryValidator`** przed wykonaniem: blokada niebezpiecznych słów
  (`DROP/DELETE/TRUNCATE/ALTER/CREATE/EXEC/XP_/SP_/LOAD_FILE/INTO OUTFILE/BENCHMARK/
  SLEEP/WAITFOR/INFORMATION_SCHEMA/SYS./DBA_`), wykrywanie `_has_stacked_queries()`
  i `_has_suspicious_comments()` z odróżnieniem komentarza legalnego (`_is_legitimate_comment`).
- **Limity:** `MAX_QUERY_LENGTH = 10000`, `MAX_PARAMETERS = 100`, dozwolone typy zapytań
  `{SELECT, INSERT, UPDATE, DELETE}`.
- **Audyt:** `AuditEntry` (hash zapytania, akcja, source_ip, user_id, execution_time_ms,
  blocked) — ring `MAX_AUDIT_ENTRIES = 50000`.
- **API:** `validate_query(query, params)`, `execute_safe(...)`,
  `register_prepared_statement(name, sql, params, query_type)`, `execute_prepared(...)`.

### 1.3 Whitelisting zapytań — deny-by-default na poziomie SQL
`security/query_whitelisting.py` (489 l.)
- `ColumnWhitelist` — dozwolone kolumny per tabela (`is_column_allowed`, `validate_column`).
- `QueryWhitelist` — rejestr **szablonów** zapytań (`register_query(name, template,
  allowed_tables)`); `build_query(name, columns, params)` buduje SQL WYŁĄCZNIE z kolumn
  z whitelisty; `validate_dynamic_query()` parsuje gotowy SQL (SELECT/INSERT/UPDATE/DELETE:
  tabele, kolumny, klauzule) i odrzuca wszystko spoza whitelisty.
- Dekorator `@whitelisted_query(query_name=..., query_type=...)`.
- Singleton `get_whitelist()` + `get_whitelist_summary()`.

### 1.4 Secure database — przezroczysty wrapper na połączeniu
`security/secure_database.py` (464 l.)
- `SecureDatabase` — proxy na oryginalne połączenie (`__getattr__` deleguje resztę):
  `_secure_execute()` / `_secure_executemany()` przepuszczają każde SQL przez detektor
  + walidację whitelisty + logowanie (`_log_query`, `get_query_log`, `get_security_stats`).
- Fabryka `secure_database_connection(db_connection)` — podmienia połączenie w jednym
  miejscu (wzorzec „wrap, nie przepisuj").
- `@prepared_statement(template, query_type)` — deklaratywne rejestrowanie szablonów;
  `PreparedStatementExecutor` + `get_prepared_statement(name)`.

### 1.5 Security middleware HTTP — skan wejścia przed handlerem
`security/security_middleware.py` (291 l.)
- `SecurityMiddleware.init_app(app)` — `before_request` skanuje **wszystkie wejścia**:
  query params, form data, JSON (rekurencyjnie, `_check_json_for_sql_injection` z
  ścieżką `a.b[0].c`), wybrane nagłówki (User-Agent/Referer/Origin). Wynik w `g`
  (`security_detections`, `security_blocked`); blokada → 403 JSON.
- `after_request` — log każdego requestu (ring 1000) + `get_security_stats()` (total/
  blocked/with_detections/block_rate + statystyki detektora).
- Dekoratory: `@secure_endpoint` (odrzuca gdy już zablokowano, loguje wyjątki
  security), `@validate_input(pattern, field)` — walidacja regex na parametrach ścieżki.
- **Słownik walidacji** `VALIDATION_PATTERNS`: username, email, password, id, uuid,
  alphanumeric, safe_string — gotowe wzorce input validation.
- `SecurityError` → errorhandler 403.

### 1.6 Security events middleware — logowanie zdarzeń + ML fail-open
`security/security_events_middleware.py` (729 l.)
- `before_request`: (1) **check IP-blocked** (z SecurityMonitoring) → 403; (2) skan
  wszystkich inputów pod kątem **command injection + SQLi** (regex `ThreatPatterns`);
  (3) **analiza ML asynchronicznie i NIE-blokująco** — wyjątek w ML nie zabija requestu
  (fail-open; alert tylko przy severity high/critical).
- `after_request`: zdarzenie security logowane GDY `status >= 400` LUB endpoint
  `/api/auth*` / `/api/admin*` LUB był alert ML; mierzy `response_time_ms`.
- `SecurityEventsDatabase` — tabela `security_events` (SQLite) z indeksami
  (timestamp/source_ip/type/severity), metody `log_event`, `get_recent_events`,
  `get_statistics` (by_severity, by_type, blocked_count, top_source_ips).
- `_categorize_event`, `_log_ml_alert`, liczniki (event/blocked/alert).

### 1.7 Monitoring zdarzeń — playbooki, auto-block, SIEM/CEF
`security/security_monitoring.py` (769 l.)
- Model: `Severity`, `ThreatType`, `AlertStatus`, `SecurityEvent`, `SecurityAlert`
  (z `to_cef_extension()`).
- `ThreatPatterns` — **trzy listy regex**: `SQL_INJECTION_PATTERNS`, `XSS_PATTERNS`
  (`<script`, `javascript:`, `onerror=`, `document.cookie`, `eval(`, ...),
  `COMMAND_INJECTION_PATTERNS` (`;cat`, `|whoami`, `$()`, backtick, `/etc/passwd`,
  `../`, `%00`, ścieżki `/bin/sh`).
- `SecurityMonitoring` (singleton, double-checked locking): `detect_threat(event)` →
  `_check_sql_injection/_check_xss/_check_command_injection/_check_brute_force/
  _check_port_scan` → `_generate_alert` (deterministyczny `alert_id`) →
  **playbook reakcji** `ResponsePlaybook` (akcje: `block_ip`, `disable_user`,
  `apply_rate_limit`, `escalate_alert`, `isolate_endpoint`) z auto-blockiem po N
  alertach (`_track_alert_for_autoblock`); `block_ip(ip, duration)`, `is_ip_blocked(ip)`.
- `SIEMIntegration` — eksport alertów w formacie **CEF** (syslog UDP, TCP lub TLS;
  **fail-local** — gdy brak połączenia, loguje lokalnie i nie traci eventu).

### 1.8 Threat detector — behavioral/ML z fail-open
`security/threat_detector.py` (994 l.)
- `RequestFeatures` → wektor (cechy requestu per IP/endpoint); `AnomalyScore`.
- `StatisticalEngine`: z-score, **modified z-score**, **IQR outlier** per metryka —
  proste detekcje anomalii bez ML.
- `IsolationForest` (własna implementacja) + `FeatureExtractor.calculate_entropy(text)`
  (entropia — wykrywanie obfuskacji/eksfiltracji).
- `BehavioralBaseliner` — per-entity (IP/user) baseline normalnego zachowania;
  odchylenie od baseline = sygnał.
- `MLThreatDetector`: `record_request`, analiza, **retrain w tle**, alert callback.
  `ThreatDetectorIntegration.set_alert_callback(...)` — punkt podpięcia do alertów.

### 1.9 Integrator — „wzmocnij cały serwer jednym wywołaniem"
`security/integration.py` (403 l.)
- `SecurityIntegrator.apply_all_security()`: monkey-patch warstwy DB (bezpieczne
  funkcje), podpięcie middleware Flask, dodanie `secure_endpoint`/`validate_input`/
  `VALIDATION_PATTERNS` do modułu API, errorhandler SecurityError.
- `create_security_report()` — raport: statystyki detektora, podsumowanie whitelisty,
  liczba secure connections, `middleware_active`, **generowane rekomendacje**
  (`_generate_recommendations`).
- Funkcje: `init_security(app=None)`, `apply_security()`, `test_security()`,
  `get_security_report()`, `get_integrator()`.
- Pokrycie testami: `security/test_sql_injection_security.py` (998 l.).

### 1.10 EDR/XDR — detekcja extortion na endpointach
`modules/edr_xdr_module.py` (1066 l.)
- Model: `Endpoint`, `Process` (drzewo procesów, operacje plikowe/rejestr/sieć),
  `EndpointAlert` (status: new/investigating/confirmed/false_positive/resolved),
  `DetectionRule` (typ: signature/behavioral/heuristic/ml + `response_actions`),
  `ThreatIndicator` (IOC: hash/ip/domain/url/file_path/registry_key).
- **Heurystyki extortion:** `_calculate_file_entropy()` (wysoka entropia masowych
  zapisów = szyfrowanie), `_detect_extortion_note()`, `_detect_backup_disruption()`,
  `_calculate_encryption_rate()` w oknie czasowym.
- Metryki MTD/MTR (mean time to detect/respond), licznik false_positives.

### 1.11 Deception — honeypoty i honeytokeny (defensywne, wczesne ostrzeganie)
`modules/deception_module.py` (579 l.)
- `Honeypot` (interakcja LOW/MEDIUM/HIGH, usługi SSH/RDP/HTTP/SMB), `Honeytoken`
  (typy: CREDENTIAL/FILE/DATABASE/API_KEY/COOKIE/DNS/WEB_BUG — canary), `DeceptionAlert`,
  `AttackerProfile` (profilowanie IP: techniki, credentiale, fingerprint narzędzi).
- Logika: pętle monitorujące honeypoty/honeytokeny, profilowanie atakujących,
  korelacja alertów; cel = **wczesne wykrycie** (dotknięcie wabika ≠ ruch legalny).
- Uwaga: w archiwum deklaracja „full OS interaction" (HIGH) — realnie symulacja;
  na AIGON-X stosować tylko tanie wabiki (honeytokeny w bazie, canary endpointy,
  fałszywe API keys) — patrz mapa.

### 1.12 Czego NIE kopiować (antywzorce z archiwum)
- `modules/cyber_defense.py` — „24/7 protection" logująca **losowe liczby** zagrożeń
  (`random.randint`) = fake telemetria. Na AIGON-X to byłby false-green w /health
  (łamie zasadę „SELF-REPORT IS NOT PROOF"). Realny odpowiednik: liczniki z realnych
  zdarzeń (evidence-store / OTLP).
- Dekoracyjne nagłówki „WAR MODE: ACTIVE" w logach — szum, nie sygnał.
- `PREVENTION_MODE_STRICT` jako jedyny tryb na produkcji od pierwszego dnia — startuj
  w `AUDIT`, potem `MODERATE`/`STRICT` (patrz procedura).

---

## 2. Mapa na elementy AIGON-X (gdzie zastosować)

Mapowanie wzorca → konkretny cel. Zawsze najpierw sprawdź bieżący stan celu (read),
potem aplikuj. Kod produkcyjny AIGON-X zmieniaj przez subagentów wg zasad repo.

### 2.1 Runtime (Rust/axum) — `runtime/crates/aigon-runtime/src/api.rs`
Istniejące punkty zaczepienia (sprawdzone):
- **Auth:** `.layer(middleware::from_fn(crate::auth_guard::require_api_auth))` (api.rs
  ~1215) + parsowanie `x-api-key`/`authorization: Bearer` (~1404, ~2239).
- **Trace:** `api_trace_middleware` (api.rs ~2595) — tu, obok trace, dokładać skan
  wejścia (wzorce 1.5/1.6).
- **Rate limit (DoS):** tylko na kosztownym czacie (api.rs ~1135 „DoS guard").

Wzorce do wdrożenia (od najtańszego):
1. **Input-scan middleware** (1.5/1.6) — na warstwie `from_fn` przed handlerami:
   regex `ThreatPatterns` (SQLi/XSS/command-injection) po `query`, JSON body
   (rekurencyjnie), wybranych nagłówkach → detekcja logowana, blokada 403 po
   progu (1.1: 3 detekcje / cooldown 60 s / blokada 30 min).
2. **Zdarzenia security do `aigon-evidence-store`** (1.6/1.7) — event tylko gdy
   status>=400 / endpoint auth / alert; deterministyczny alert_id.
3. **Playbooki + auto-block IP** (1.7) — wpiąć w istniejący governance/kernle
   (aigon-governance, deny-default). Alert → akcja (block/rate-limit/escalate),
   każda akcja zostawia ślad w evidence (nie omijać Enforcement Gate).
4. **Rekomendacja R4 z ANALIZA-REKOMENDACJE.md:** rozszerzyć `aigon-kernel-yudai`
   (ma już CognitiveFirewall prompt-injection) o `ApiSecurityMiddleware` — natywne
   SQLi/XSS sygnatury z `security/sql_injection_detector.py` +
   `security_monitoring.ThreatPatterns`, jako DAST-lite na własnych `/api/v1/*`.
5. **Behavioral/ML** (1.8) — start od `StatisticalEngine` (z-score/IQR) na metrykach
   requestów per IP; IsolationForest/ML dopiero gdy są dane historyczne. **Fail-open**:
   wyjątek detektora nigdy nie zabija requestu (1.6).
6. **Honeytokeny** (1.11) — tanie canary: nieistniejące endpointy `/api/v1/honeypot-*`
   i fałszywe API keys w bazie; dotknięcie = alert (koszt ~0, wykrywalność wysoka).

### 2.2 Produkty (`<workspace>/products/`)
**Najpierw ustal SoT produktu** — katalog w `products/` bywa knowledge-shellem bez kodu
(np. vairyfy — realny SoT: `/opt/worek/products-sorted/prod/vairyfy-saas`, backend Rust
`veritas`; sigil — lokalny obraz `sigil:1.0.0`, patrz jego docker-compose; pzl-rejestr —
Node/TS w `src/`). Wzorce aplikuj do REALNEJ warstwy wejścia/DB danego SoT, nie do
knowledge-shellu.
- **Backendy z DB:** pzl-rejestr, drony, akceleratory (grantos, grantmaster, EIC_ACC),
  monai, wykrywacz, diffiusion + SoT vairyfy/sigil. Aplikuj:
  - parametryzacja/prepared statements WSZĘDZIE (1.4 — wrapper na połączeniu zamiast
    przepisywania warstwy DB; dekorator `@prepared_statement`);
  - whitelisting szablonów dla dynamicznego SQL (1.3) — w produktach generujących
    raporty/filtry (grantos — dynamiczne filtry dotacji, pzl-rejestr);
  - walidacja input regex na brzegu (1.5 `VALIDATION_PATTERNS`) — uuid/id/alphanumeric;
  - tryb AUDIT na start (1.2), promocja do STRICT po okresie obserwacji.
- **Produkty compliance (vairyfy/sigil)** — same muszą być przykładem: dowody
  hardeningu do `aigon-evidence-store` (audyt SOC2/GDPR — powiązany skill:
  governance-rubric-audit).

### 2.3 Frontend / nginx
- Konfy: `products/frontend/nginx.docker.conf`, `core/mesh-nginx.conf`.
- Nagłówki security (CSP, HSTS, X-Content-Type-Options, X-Frame-Options) + rate
  limit na `/api/`, deny dla `/admin`/`/.git` z zewnątrz (wzorzec: ograniczenia na
  brzegu zamiast w aplikacji).
- XSS: escaping na wyjściu + testy wejścia wzorcami `XSS_PATTERNS` (1.7) w E2E
  (skill verification-test-design).

### 2.4 Dostosowanie języka
- Rust (aigon-runtime `api.rs`, backend vairyfy `veritas`, pozostałe backendy Rust):
  ten sam *design* przez `axum::middleware::from_fn` + `tower` (rate limit), enumy
  Severity/ThreatType/PreventionAction → Rust enums, regex → `regex` crate, SQLi
  sygnatury → const &[&str] + `RegexSet`.
- Python/FastAPI|Flask (pliki narzędziowe, skrypty): wzorce 1.5/1.6/1.7 przenośne prawie
  1:1 (before_request → odpowiednik middleware frameworku).
- Node/TS (pzl-rejestr, frontendy): parametryzacja przez warstwę ORM/drivera (nigdy
  string-concat), walidacja wejścia (zod/express-validator odpowiednik `VALIDATION_PATTERNS`),
  nagłówki security na nginx.

---

## 3. Checklista hardeningu

Dla każdej pozycji wymagany DOWÓD (plik:linia / licznik / wpis evidence) — nie
self-report. Kategorie: AUTH, SQLI, WEJŚCIE/THREAT, EVENT/MONITORING, ODPOWIEDŹ,
DECEPTION.

### AUTH
- [ ] A-1 Żadnych sekretów w kodzie/configu — Vault (config/secrets.yaml → sync), rotacja JWT (skill: credential-security-sweep / vault-*)
- [ ] A-2 Auth na KAŻDYM endpointzie (runtime: `auth_guard::require_api_auth` na routerze, nie per-handler)
- [ ] A-3 Rate limit na logowanie/brute-force (per-IP, próg ~5/min) + blokada po N failed logins (1.7 `_check_brute_force`)
- [ ] A-4 Walidacja formatu identyfikatorów (uuid/id — 1.5 `VALIDATION_PATTERNS`) na wejściu
- [ ] A-5 CSRF na formularzach/cookie (produkty webowe); tokeny jednorazowe

### SQLI (warstwa DB)
- [ ] S-1 Zero string-concatenation SQL — parametryzacja/prepared statements (1.2/1.4)
- [ ] S-2 Dynamic SQL tylko przez whitelistę szablonów (1.3 `QueryWhitelist`) — kolumny i tabele z whitelisty
- [ ] S-3 Wrapper bezpiecznego połączenia z logowaniem zapytań (1.4) tam, gdzie wrapper da się podpiąć bez przepisywania
- [ ] S-4 Walidacja typu zapytania i limitów (tylko SELECT/INSERT/UPDATE/DELETE; MAX_QUERY_LENGTH; zakaz stacked/komentarzy — 1.2)
- [ ] S-5 Sygnatury SQLi aktywne na wejściu HTTP (1.1/1.7 `SQL_INJECTION_PATTERNS`) — od trybu AUDIT

### WEJŚCIE / THREAT DETECTION
- [ ] T-1 Skan wszystkich wejść: query/form/JSON(rekursywnie)/nagłówki (1.5/1.6)
- [ ] T-2 Sygnatury XSS + command injection (1.7 `XSS_PATTERNS`, `COMMAND_INJECTION_PATTERNS`)
- [ ] T-3 Detektor fail-open (wyjątek detektora nie blokuje requestu — 1.6/1.8)
- [ ] T-4 Behavioral baseline per IP/user (1.8) + statystyki z-score/IQR na metrykach requestów
- [ ] T-5 EDR-heurystyki tam, gdzie są pliki/backupy: entropia, extortion-note, backup-disruption, encryption rate (1.10)
- [ ] T-6 Cooldown alertów (anty-spam, ~60 s na encję — 1.1)

### EVENT / MONITORING
- [ ] E-1 Zdarzenia security logowane gdy status>=400 / endpoint auth/admin / alert (1.6) — z response_time_ms
- [ ] E-2 Persystencja zdarzeń z indeksami (timestamp/IP/typ/severity — 1.6 `security_events`)
- [ ] E-3 Eksport CEF/SIEM z fail-local (1.7 `SIEMIntegration` — brak połączenia ≠ utrata eventu)
- [ ] E-4 Statystyki: total/blocked/block_rate, by_severity, by_type, top_source_ips (1.5/1.6) — wystawione do /metrics
- [ ] E-5 Alerty i zdarzenia → `aigon-evidence-store` (runtime) / OTLP — rekonstruowalność

### ODPOWIEDŹ (playbooki)
- [ ] R-1 Blokada IP z czasem trwania (1.7 `block_ip`, `is_ip_blocked` sprawdzane w before_request)
- [ ] R-2 Rate-limit / escalate / isolate endpoint jako akcje playbooka (1.7)
- [ ] R-3 Deterministyczny alert_id (1.7) — bez UUID-losowego w logach
- [ ] R-4 Każda akcja reakcji zostawia wpis evidence (nie omijać Enforcement Gate)

### DECEPTION (opcjonalnie, tanie wabiki)
- [ ] D-1 Honeytokeny: fałszywe API keys / wpisy DB / canary endpointy (1.11)
- [ ] D-2 Dotknięcie wabika = alert z profilowaniem IP (1.11 `AttackerProfile`)
- [ ] D-3 Wabiki NIE są osiągalne z legalnego ruchu (inaczej false positive)

---

## 4. Procedura audytu wg checklisty

Dwa tryby (jak w skillach audytowych repo): **raport** (audyt, zero edycji) i
**fix** (audyt → edycja → weryfikacja). Gdy niepewny — zapytaj, nie defaultuj do fix.

### Tryb raport
1. **Scope.** Cel: runtime (api.rs/kernele), konkretny produkt, czy nginx/frontend.
   Podaj scope jawnie w raporcie.
2. **Mapa powierzchni.** Dla runtime: router w api.rs (warstwy middleware ~1215/2595),
   kernele (yudai, governance), evidence-store. Dla produktu: warstwa wejścia
   (framework middleware), warstwa DB (execute/cursor), configi nginx.
3. **Przejdź checklistę** (sekcja 3) — dla każdej pozycji zbierz dowód przez
   read/grep/pomiar. Nie zgaduj: brak dowodu = „brak" (pozycja niespełniona).
   Uważaj na false-green: licznik/deklaracja „security" w nazwie ≠ realna kontrola.
4. **Raport:**
   ```
   # Hardening audit — <scope>
   ## Podsumowanie — N/M spełnione; kategorie najsłabsze: ...
   ## Kategoria (AUTH/SQLI/...)
   - [ ] S-1 — BRAK: <plik:linia, dowód że jest concat>
   - [x] S-5 — JEST: <plik:linia> sygnatury aktywne w trybie AUDIT
   ## Rekomendacje (kolejność: tanie i pewne pierwsze: input-scan + audit-mode,
     potem whitelisting, na końcu ML/behavioral)
   ## Pozytywne (co już jest — wzorce do utrzymania)
   ```
5. Priorytetyzacja wg ryzyka: endpointy publiczne/auth/DB-wpisy > wewnętrzne.

### Tryb fix
1. **Baseline** — raport wg checklisty = lista „przed".
2. **Plan + aplikacja** — zacznij od trybu AUDIT dla detekcji (obserwacja, zero
   blokad), promuj do STRICT po zweryfikowaniu braku false positive. Grupuj edycje
   per plik. Zmiany kodu runtime/produktów: przez subagentów (zasada repo),
   każda zmiana = commit.
3. **Weryfikacja** — powtórz audyt, porównaj z baseline: każda pozycja zamknięta
   ma dowód; żadna nowa luka nie powstała. Nie iteruj w ciszy — nazwij niezamknięte.
4. **Zgłoś** — per kategoria: co wdrożono (plik + wzorzec 1.x), co odroczono i
   dlaczego, wynik przed/po.

### Pułapki audytu (z archiwum i doświadczeń AIGON-X)
- Moduł „security" który loguje losowe liczby (cyber_defense.py) — sprawdzaj czy
  licznik ma realne źródło zdarzeń, nie tylko tick.
- Sygnatury SQLi na wejściu generują false positive na legalnych danych
  (np. `1=1`, `--` w treści) — tryb AUDIT najpierw, whitelist wyjątków jawnie.
- Detektor, który BLOKUJE request przy własnym błędzie (fail-closed) — na AIGON-X
  to wektor DoS; ML/detektor = fail-open, blokada tylko na pewnych sygnaturach.
- Rate limit tylko na jednym endpointcie (czat) zostawia resztę API bez osłony —
  limity per-grupa tras, nie per-najdroższy handler.

