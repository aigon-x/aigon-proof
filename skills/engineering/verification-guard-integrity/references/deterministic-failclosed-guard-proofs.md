# Dowodzenie deterministycznego strażnika (fail-closed) — gotowe przepisy

Uzupełnienie do sekcji „autorstwo strażnika". Gdy strażnik ma być
**deterministyczny i fail-closed** (nie „sprawdź i przepuść", tylko „odrzuć, gdy
nie da się udowodnić poprawności"), sam zielony test nie wystarcza. Poniżej
kształty dowodu, które realnie odróżniają strażnika z zębami od teatru.

## 1. Trzy kształty testu (wszystkie trzy, nie jeden)

1. **Przed = FAIL, po = PASS.** Weź REALNY zły input (np. próbkę z produkcji),
   `assert validate(zly)` niepuste, potem `assert validate(naprawiony) == []`.
   Test, który sprawdza tylko oczyszczony tekst, nie dowodzi że w ogóle coś łapie.
2. **Test negatywny przez input NIENAPRAWIALNY.** Karm strażnika czymś, czego
   warstwa naprawcza (sanitize/rewrite) NIE umie naprawić, i oczekuj ODRZUCENIA
   (wyjątek / SKIP / rc!=0). Bez tego nie dowiedziesz, że bramka nie jest cichym
   passem. Zmierzone: „Hi there, I've worked with several clients…" → sanitize
   zdejmuje opener, ale claim zostaje → strażnik MUSI rzucić.
3. **Strażnik nie zależy od niedeterministycznego mózgu.** Jeśli bramka decyduje
   deterministycznie (walidator/lista reguł), dodaj test `bridge.chat.assert_not_called()`
   — dowód, że werdykt nie zależy od LLM. Jeśli celowo woła LLM, dodaj test
   fail-closed na błędzie mostu („błąd = odrzuć, nie przepuść").

## 2. Dowód „przed/po" BEZ wydawania tokenów

Zamockuj zależność niedeterministyczną (LLM/HTTP), ale wykonaj PRAWDZIWĄ ścieżkę
kodu produktu — nie kopiuj logiki do testu:

```python
bridge = AIGONBridge(cfg)
bridge.chat = AsyncMock(return_value=REALNY_ZLY_TEKST)
out = await bridge.generate_proposal(...)      # prawdziwy prompt + post-processing
assert validate(out) == []
out2 = await engine._ensure_human_proposal(job, None, NIENAPRAWIALNY)  # oczekuj wyjątku
```

To dowód, że podmiana promptu + post-processing faktycznie czyści — bez kosztu
i bez zależności od dostępności modelu.

## 3. Dowód czystości DANYCH bez mutacji produkcji

Chcesz pokazać „nowe rekordy są czyste", nie dotykając prod bazy. Wstaw wiersz
w transakcji i ZROTuj:

```sql
BEGIN;
INSERT INTO ... VALUES ('__selftest__', ...);
SELECT count(*) FROM ... WHERE id LIKE '%selftest%' AND col ~ '[’“”–—…]';  -- cel: 0
SELECT /* baseline */ count(*) FROM ... WHERE id NOT LIKE '%selftest%' AND col ~ '[...]';
ROLLBACK;
```

Weryfikacja po: `SELECT count(*) FILTER (WHERE id LIKE '%selftest%')` = 0.
Pamiętaj o FK — często musisz wstawić też wiersz-rodzica (`job.jobs`). Jednorazowa
naprawa ZALEGŁYCH danych to osobny, OWNER-gated krok (backup + jawna zgoda), NIE
część wdrożenia strażnika.

## 4. Idempotencja warstwy naprawczej

`sanitize(x)` / normalizacja muszą być **idempotentne** (`sanitize(sanitize(x)) == sanitize(x)`)
— bo wołasz je i przy generacji, i po kroku „improve", i przed zapisem. Test:
`assert sanitize(once) == once`. Nieidempotentna naprawa = dryf przy każdym przebiegu.

## 5. Pułapka: strażnik naprawiony w źródle ≠ działa w runtime

Zanim ogłosisz „problem rozwiązany", sprawdź, czy DZIAŁAJĄCY artefakt (kontener/
binarka/proces) jest świeższy niż zmiana. Porównaj `docker inspect <c> .Created`
(binarki: mtime/suma) z mtime pliku i — jeśli starszy — zgłoś wprost, że wymagany
jest rebuild/redeploy. Został zmierzony przypadek: źródło naprawione, a świeżo
zapisane rekordy nadal miały stary defekt, bo kontener działał na starym image.
