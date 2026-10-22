---
name: false-green-elimination
description: Wykrywaj i likwiduj FAŁSZYWE SUKCESY w systemach agentowych — statusy "stored"/"green"/"ok" zwracane bez dowodu zapisu, skrypty nazwane "sync" robiące tylko GET, logi pokazujące 0/0 mimo zdrowych komponentów, identyfikatory liczone dwiema różnymi regułami. Użyj gdy coś raportuje sukces, ale efektu nie ma; gdy dane "są" w hot cache a nie ma ich w źródle prawdy; gdy user mówi "lepszy brak niż coś zielonego co nie działa".
---


# Likwidacja fałszywych sukcesów (false-green)

## Zasada nadrzędna (Suweren, 2026-09-21)

> **„lepszy brak niż coś zielonego, co nie działa"**

Fałszywy sukces jest gorszy niż brak. Brak widać i można go naprawić.
Zielony status bez efektu zatruwa wszystkie downstream decyzje i podważa
zaufanie do każdego innego ustalenia w raporcie.

## Kiedy użyć

- Endpoint/log zwraca `stored` / `green` / `ok` / `success`, ale efektu nie ma.
- Dane są w pamięci (hot cache), ale nie ma ich w kanonicznym magazynie.
- Skrypt nazwany `sync` / `deploy` / `verify`, który nic nie zapisuje.
- Log pokazuje `0/0`, `0 elements`, `empty` mimo że komponent istnieje i działa.
- Dwa źródła odpowiadają różnie na to samo pytanie.
- User mówi „nie widzę", „wygląda jakby wisiało", „twierdzisz że jest OK".

## Wzorzec naprawy — 4 elementy, wszystkie obowiązkowe

### 1. Handler potwierdza odczytem z KANONICZNEGO magazynu

Nigdy nie zwracaj statusu tylko dlatego, że funkcja zapisu się nie wywaliła.
Potwierdź **trwałym odczytem** tego, co miałeś zapisać.

```rust
// ŹLE — powołuje się na "pipeline zapisze na następnym ticku".
// Gdy pipeline stoi (tick stall / brak slotu semafora), NIGDY nie zapisze,
// a klient dostaje zielone.
Json(json!({ "status": "stored", "id": id, "key": req.key }))

// DOBRZE — status mówi PRAWDĘ o tym, gdzie rekord faktycznie jest.
let point_id = crate::knowledge_pipeline::qdrant_point_id(&req.key);
let durable = { /* GET punktu z Qdrant — kanoniczny magazyn */ };
let status = if durable { "stored" } else { "in_memory" };
Json(json!({
    "status": status, "durable": durable,
    "store": if durable { "qdrant" } else { "fabric_hot_cache" },
    "note": if durable { "Potwierdzone odczytem punktu." }
            else { "Tylko hot cache — Qdrant nie potwierdził." },
}))
```

### 2. Brak potwierdzenia → nazwany stan + kod wyjścia ≠ 0

Nie zamieniaj niepewności w sukces. `in_memory` / `unverified` + `exit 1`.

```python
if pts < MIN_EXPECTED_POINTS:
    report.update({"status": "unverified", "verified": False,
                   "note": "Nie ma czym potwierdzić — to NIE jest sukces."})
    return 1
```

### 3. Pole `verified` w JSON

Rozdziel **stan prawdziwy** od **niepotwierdzonego** jawnym polem, żeby caller
(self/agent) mógł się rozgałęzić, a nie tylko przeczytać kolor.

### 4. Test negatywny obowiązkowy

Bez testu negatywnego nie wiesz, czy naprawa działa. Wymuś próg nieosiągalny
i sprawdź, że status się zmienia:

```bash
python3 script.py                          # verified: true,  exit 0
AIGON_MIN_POINTS=999999999 python3 script.py  # verified: false, exit 1
```

## PITFALL: jedna reguła policzona w DWÓCH miejscach

Zmierzony przypadek: `KnowledgePipeline::point_id` liczył
`Uuid::new_v5(&AIGON_KNOWLEDGE_NAMESPACE, key)`, a `api.rs` przy weryfikacji
trwałości liczył `Uuid::new_v5(&Uuid::NAMESPACE_URL, key)`. **Inny identyfikator**
→ weryfikacja raportowała „punkt nie istnieje" dla rekordów, które w Qdrant są.

**Reguła:** identyfikator/klucz/hash używany do zapisu i do weryfikacji MUSI
pochodzić z JEDNEJ publicznej funkcji. Gdy widzisz tę samą logikę w dwóch
plikach — to nie duplikacja stylistyczna, to przyszły fałszywy negatyw.

```rust
#[must_use]
pub fn qdrant_point_id(key: &str) -> Uuid {
    Uuid::new_v5(&AIGON_KNOWLEDGE_NAMESPACE, key.as_bytes())
}
// api.rs: let point_id = crate::knowledge_pipeline::qdrant_point_id(&req.key);
// pipeline: crate::knowledge_pipeline::qdrant_point_id(&record.key)
```

## PITFALL: skrypt nazwany `sync`, który tylko czyta

`cmr-qdrant-sync.py` był wołany przez `POST /api/v1/knowledge/sync`, logowany
jako „sync completed successfully", a robił **wyłącznie**
`GET /collections/<name>` i zwracał `status: green`. Zero zapisu, zielony raport.

**Oznaki do sprawdzenia w każdym skrypcie „sync/deploy/verify":**
- Czy w kodzie jest jakikolwiek PUT/POST/UPDATE/COPY? (`grep -cE 'PUT|POST|UPDATE|copy'`)
- Czy `status` jest wpisywany na sztywno, czy wynika z porównania przed/po?
- Czy nazwa mówi `sync`, gdy rola to `verifier`? → zmień nazwę i `role:`.

## PITFALL: log liczy INNE źródło niż API

Ticker logował `0/0 kernels healthy`, a `aigon kernel` pokazywał
`34/34 Healthy, failed=0`. Źródło rozjazdu: ticker liczył `results.len()`
z `tick()`, a nie rejestr kernelów, z którego czyta API.

```
main.rs:1905:
  let healthy = results.iter().filter(...).count();   // pusty gdy guard zwrócił Vec::new()
  info!("[Ticker] Tick {}: {}/{} kernels healthy", tick_count, healthy, results.len());
```
Gdy guard (`CircuitBreaker`/`TokenGuard`/`ContextGuard`) kończy tick wcześnie,
`results` jest puste → „0/0" mimo 34 zdrowych kernelów.

**Reguła:** log i API muszą czytać TO SAMO źródło. Zanim uznasz komponent za
martwy — zapytaj drugie źródło. `0/0` (mianownik zero) to prawie zawsze
**pusty wektor**, nie brak komponentów.

## PITFALL: bramka porównuje DEKLARACJĘ z DEKLARACJĄ (zmierzone 2026-09-29)

`capability-drift-check.py` raportował `PASS (133 capabilities, 2497 skills, 44 kernels)`.
Liczbę 44 brał **wyłącznie z manifestu** `runtime/manifests/kernels.yaml` i porównywał
ją… z manifestem. Tymczasem żywy runtime raportował **35** (`aigon kernel`, master i local
zgodnie, wszystkie Healthy, 0 failed).

Dziewięć „kernel" istniało więc jednocześnie jako:
**(a) martwe** — nigdy nie zainicjalizowane, oraz **(b) niewykrywalne** — bo żadne źródło
nie pytało runtime o stan faktyczny.

To wprost defekt, przed którym ostrzega własny `gate-registry.yaml`:
> „kernel zadeklarowany w manifescie (enabled: true) a niezainicjalizowany to kernel,
> który udaje że działa".

**Reguła:** bramka spójności MUSI porównywać **deklarację z pomiarem**, nie deklarację
z deklaracją. Manifest (`.yaml`) to rejestr ŻYCZEŃ; dowodem jest dopiero licznik z
żywego procesu. W raporcie trzymaj OBIE liczby jawnie — inaczej jedna udaje stan:

```
verdict: PASS (133 capabilities, 2497 skills, kernels: manifest=35 runtime=35)
```

Gdy runtime nieosiągalny → **`None`, nie `0`** i `[WARN]`, nie `PASS`.
`0` znaczyłoby „kernel nie żyją" — twierdzenie bez podstaw. Brak pomiaru != stan zdrowy.

### Dwie wady tego samego detektora (obie zmierzone tego dnia)

1. **Regex po tekście zamiast parsera YAML.** Detektor czytał plik wyrażeniem
   `name:\s*"?([\w\-.]+)"?`, więc łapał nazwy **także z komentarzy**. Po zakomentowaniu
   w manifeście dziewięciu błędnych wpisów bramka NADAL widziała je jako kernele —
   czyli mierzyła dokumentację, nie rejestr. Parsuj strukturę (`yaml.safe_load`),
   nie tekst.
2. **Klucz API wpisany na sztywno.** `headers={"X-API-Key": "local-smoke"}` zwracał
   `{"error":"missing or invalid credentials"}`, więc pomiar runtime NIGDY nie działał,
   a bramka cicho raportowała „niezmierzony" i przechodziła dalej. Literał-zaślepka
   w miejscu, gdzie potrzebny jest sekret z SSOT, jest fałszywym zielonym w przebraniu.

### Test FALSYFIKOWALNY — jedyny dowód, że strażnik nie jest dekoracją

Zielony `PASS` niczego nie dowodzi; dowodzi **czerwony przy wstrzykniętym błędzie**:

```bash
# wstrzyknij fałszywy wpis i sprawdź, czy bramka krzyknie
sudo cp runtime/manifests/kernels.yaml /tmp/k.bak
sudo python3 -c "
p='<workspace>/runtime/manifests/kernels.yaml'; t=open(p,encoding='utf-8').read()
t=t.replace('  - { name: nano,', '  - { name: __fake__, enabled: true, tick_period_ms: 1000, domain: t, description: \"x\" }\n  - { name: nano,', 1)
open(p,'w',encoding='utf-8').write(t)"
python3 scripts/capability-drift-check.py   # MUSI dać FAIL: kernel_manifest_runtime_drift
sudo cp /tmp/k.bak runtime/manifests/kernels.yaml
```

**Jeśli bramka nie zaprotestuje na wstrzyknięty błąd — jest ślepa**, choćby świeciła
na zielono. Zapisz ten test w `tools/verify-*.sh`; nie kasuj po sukcesie.

## PITFALL: „provider" udający „kernel" — sprawdź, co mówi KOD

Dziewięć z tych czterdziestu czterech wpisów to nie kernele, a **kategorie providerów**.
Rozstrzyga kod, nie nazwa i nie opis: `aigon-v3-core/src/provider.rs:217+` definiuje je
jako `Provider::new("P-001", "StructuredPersistentStorage", "KnowledgeGraph")` — czyli
`name` z manifestu to DRUGA kolumna konstruktora `Provider`, a trzecia to implementacja.
Łatwo je też rozpoznać po zapisie: jedyne mają nazwy **Wielką Literą**, gdy prawdziwe
kernele to `nano`, `curie`, `planck`, `yairoslaw`.

Konsekwencja klasyfikacyjna: `providers` to **osobny backend** — nie ma i nie może mieć
dispatchu w `handle_capability_call` (który routuje po parze `(domain, tool)`), bo woła
się je przez rejestr providerów. Wymuszanie na nich `backend: kernel` kazało bramce
szukać ich w `kernels.yaml`, gdzie ich słusznie nie ma — i po każdej poprawce rodziło
9 fałszywych orphanów. Rozdzielenie backendów sprawia, że „provider bez kernela" to
stan POPRAWNY, nie alarm.

## PITFALL: `grep -q` w potoku pod `pipefail` ZJADA WŁASNY SUKCES

Zmierzone 2026-09-29 przy budowie testu falsyfikowalnego. Ten sam test ręcznie dawał
trafienie, a w skrypcie nie:

```bash
set -o pipefail
timeout 200 python3 bramka.py 2>/dev/null | grep -q "wzorzec" && echo LAPIE || echo NIE
# → NIE LAPIE, mimo że wzorzec JEST w wyniku
```

`grep -q` **zamyka potok po pierwszym trafieniu** → python dostaje SIGPIPE → pod
`pipefail` cały potok wraca jako błąd. Fałszywy FAIL na poprawnie działającym obiekcie.

**Lekarstwo:** licz wystąpienia (`grep -c`) zamiast przerywać potok, albo zbierz
wyjście do zmiennej i testuj na niej:

```bash
HIT=$(timeout 200 python3 bramka.py 2>/dev/null | grep -c "wzorzec" || true)
[ "${HIT:-0}" -ge 1 ] && echo LAPIE || echo NIE
```

**Zanim ogłosisz, że coś jest ślepe — sprawdź, czy twój DETEKTOR nie jest ślepy.**
Zawsze weryfikuj też, że sama czynność przygotowawcza się powiodła: `cp` BEZ `sudo`
na pliku `aigon:aigon` cicho nie tworzył backupu, przez co test raportował FAIL
sprawnej bramki.

## Kolejność pracy przy naprawie

1. **Zmierz sprzeczność.** Dwa źródła, ta sama chwila → pokaż różnicę z dowodem.
2. **Znajdź fałszywą gałąź** (`grep` po literale statusu; przeczytaj komentarz
   uzasadniający „to zapisze się później" — tam siedzi błąd).
3. **Napraw u źródła**, nie w wołającym. Handler ma mówić prawdę.
4. **Dołóż `verified`** i kod wyjścia.
5. **Test pozytywny + negatywny** — oba, wklej WYNIK.
6. **Build + wdrożenie** — edycja bez kompilacji to nie naprawa.
   Dowód wdrożenia = md5/sha host vs kontener + ŻYWY ENDPOINT pokazujący nowe pole.
7. **Propagacja** — skill/manifest/AGENTS.md, żeby klasa błędu nie wróciła.

## Bramka końcowa

- [ ] Handler nie zwraca sukcesu bez potwierdzenia z kanonicznego magazynu.
- [ ] `verified: true/false` obecne w odpowiedzi.
- [ ] Test negatywny przechodzi (exit 1, `verified: false`).
- [ ] Identyfikator do zapisu i weryfikacji z jednej funkcji.
- [ ] Log i API czytają to samo źródło.
- [ ] Wdrożone (build + restart) i potwierdzone żywym endpointem.
- [ ] Raport podaje WYNIK i ścieżki plików, nie opis zamiaru.
