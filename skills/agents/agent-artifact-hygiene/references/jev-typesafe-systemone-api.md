# Jev / TypeSafe System One — kontrakt API (źródło pierwotne, 2026-09-28)

Wyekstrahowane z pierwotnej dokumentacji `docs.typesafe.ai` (serwowanej jako markdown).
**Zero parafraz** — cytaty dosłowne. Miejsca niepotwierdzone to `[LUKA]`, nie domysł.
Surowe 14 plików (192 KB) zachowane w `<workspace>/docs/design/jev-raw-docs/`.

## Czym to jest
Model **decyzyjny**, nie generatywny. Nie pisze tekstu — odpowiada na TYPOWANE pytania
o zamkniętej przestrzeni odpowiedzi. Kategoria producenta: „System One".
Nie mylić z routerem `typesafe/jev-router` (osobny byt, dobiera model).

## Endpoint
```http
POST https://api.typesafe.ai/v1/systemone
Authorization: Bearer <TYPESAFE_API_KEY>
Content-Type: application/json
```
Jeden wspólny endpoint dla wszystkich modeli — `model` w body wybiera, który obsłuży.
Dodatkowo `GET https://api.typesafe.ai/v1/models` (Bearer) → `models[]` z
`name`/`description`/`release_date`.

## Żądanie
| Pole | Typ | Wym. | Uwaga |
|---|---|---|---|
| `state` | `string \| object \| array` | TAK | treść do oceny |
| `model` | `string` | TAK | `jev-latest` = alias flagship (patrz „Wersjonowanie") |
| `questions` | `map<string, Question>` | TAK | **klucze wybierasz sam** |

> „The key is not sent to the underlying model and is not used in inference."

**Konsekwencja:** klucze pytań są DARMOWE (nie wchodzą do kontekstu) — można ich używać
jako identyfikatorów routingu po naszej stronie bez płacenia tokenami.

## Trzy typy pytań

| Typ | `criteria` | Limit |
|---|---|---|
| `noul` | `object` z `true`/`false` — **OPCJONALNE** | — |
| `choice` | `map<string, string\|object\|array\|null>` — **WYMAGANE** | **max 255 opcji** |
| `score` | `array<string\|object\|array>` — **WYMAGANE** | **min 2, max 10 poziomów** |

`instructions` (wymagane we wszystkich): `string | object | array`. Obiekt pozwala
rozdzielić pytanie od danych, do których się odwołuje:

```json
"instructions": {
  "potential_duplicate": { "name": "John Smith", "location": "Oakland, California" },
  "question": "Is the resume for the same person as `potential_duplicate`?"
}
```
Dane pod nazwanym kluczem, referencja backtickami — jak odwołanie do zagnieżdżonego `state`.

## Odpowiedź

```json
{
  "model": "jev-1.13.0",
  "answers": { "<question id>": { "type": "noul", "noul": 0.95 } },
  "usage": { "input_tokens": 296, "output_tokens": 20 }
}
```

`usage` ma **dokładnie dwa pola**: `input_tokens`, `output_tokens`.
`model` w odpowiedzi = **wersja rzeczywista** (nie alias).

### Kształty odpowiedzi per typ

**Noul** — `{ "type": "noul", "noul": 0.95 }`, skala 0 (nie) … 1 (tak).
**BRAK pola `confidence`** — tylko Choice i Score je mają.

**Choice**:
```json
{ "type": "choice", "choice": "billing",
  "probabilities": { "billing": 0.88, "technical": 0.12, "sales": 0.0 },
  "confidence": 0.81 }
```

**Score**:
```json
{ "type": "score", "score": 1.05,
  "legend": { "0": "Calm", "1": "Frustrated", "2": "Very angry" },
  "probabilities": { "0": 0.0, "1": 0.95, "2": 0.05 },
  "confidence": 0.92 }
```

**DWIE PUŁAPKI PARSOWANIA (krytyczne):**
1. `score` **NIE JEST INDEKSEM** tablicy `criteria`. To wartość ważona
   prawdopodobieństwami — „can land between levels", docs mają przykład `1.05` przy
   3 poziomach. Porównywanie wprost z indeksem = błąd klasy „mierzę nie tę rzecz".
2. `probabilities` to **mapa string→float**, nie tablica. Klucze MUSZĄ się zgadzać
   z `legend` (Score) albo z kluczami `criteria` (Choice). Niezgodność = odpowiedź
   nieprzypisywalna → odrzucić, NIE „dopasowywać po kolei".

## `confidence` — czym NAPRAWDĘ jest

> „Choice and Score answers also carry a confidence between 0 to 1, **derived from the
> answer's probability distribution**."

To statystyka ROZKŁADU, nie zadeklarowana poprawność. `0.95` ≠ „95% szans że prawda" —
znaczy „rozkład był ostry". Progi akceptacji kalibruj na WŁASNYCH danych, per rodzaj
decyzji i per skutek błędu.

## Wersjonowanie — przypnij, nie ufaj aliasowi

`model` w żądaniu może być `jev-latest`; odpowiedź zwraca `jev-1.13.0`.
Alias zmienia wskazywany model **bez zmiany konfiguracji** → unieważnia skalibrowane
progi bez śladu w repo. W produkcji **przypnij wersję**. Alias dopuszczalny wyłącznie
w trybie obserwacyjnym (porównanie wersji przed przypięciem).
Logowanie `model` z odpowiedzi do rekordu dowodu jest OBOWIĄZKOWE.

## Kody błędów — DWIE KLASY, nie jedna

| Status | Czy retry ma sens |
|---|---|
| `401` (zły/brak klucza) | **NIE** — trwałe |
| `422` (walidacja, wskazuje pole) | **NIE** — trwałe |
| `429` (rate limit) | TAK — exponential backoff |
| `529` (overload) | TAK — exponential backoff |

> „When you receive a 429 or 529 response, retry with exponential backoff instead of
> retrying immediately."

Circuit breaker MUSI rozróżniać klasy: 401/422 = wyłącz obwód (ponawianie marnuje budżet
i zaśmieca logi), 429/529 = backoff potem półotwarcie.

## Limity

| Limit | Wartość |
|---|---|
| Łączny budżet żądania | 64 000 tokenów |
| `state` + najdłuższe pytanie | ≤ 32 000 tokenów |
| Rate limit | 1200 req/min, 250 000 tok/s |
| Max opcji w Choice | 255 |
| Poziomy w Score | 2..10 |

**Rozjazd tras:** producent podaje 64k total, ale **OpenRouter opisuje swoją trasę jako
32k kontekstu**. Adapter respektuje ograniczenia KONKRETNEJ trasy — nie zakłada
identyczności ofert. Limity przepustowości mogą się zmieniać → **nie hardkodować**.

## BRAK MOŻLIWOŚCI URUCHOMIENIA LOKALNEGO — dowód negatywny

W ~30 plikach pierwotnej dokumentacji **zero trafień** na: `self-host`, `local run/deploy`,
`download`, `Ollama`, `GGUF`, `vLLM`, `open-weight`, `closed-weight`, `open source`.

> „the same weights serve every account" — brak fine-tune/LoRA per klient.

**Rozstrzygające:** Jev jest zamknięty, wyłącznie hosted API. Nie wchodzi na lokalne GPU,
nie wchodzi do Ollamy, nie wchodzi do mesha jako model lokalny. Integracja wyłącznie jako
**zewnętrzny provider decyzyjny**. Dane wychodzą na zewnątrz → kontrola eksportu
(sekrety, klucze SSH, konfiguracje z hasłami — NIGDY).

## Słabości wskazane PRZEZ PRODUCENTA

Osobna strona `model-jaggedness/jev-1.13.md`: „Jev isn't perfect. Here are some jagged
edges we are aware of". Wymienione: **context rot**, treści adversarialne **nie**
traktowane jako wrogie, słabość w zadaniach liczbowych.

**Najważniejszy wniosek:** producent SAM potwierdza, że typowany format odpowiedzi
**nie tworzy granicy bezpieczeństwa**. Ograniczenie odpowiedzi do schematu nie czyni
wybranej odpowiedzi prawdziwą. Jest też niezależny raport (Check Point) o manipulacji
fragmentem dokumentu zmieniającej decyzje modelu.

Zasada wynikowa: Jev to **dodatkowy sygnał ryzyka** — nie może samodzielnie nadawać
uprawnień ani unieważniać twardej odmowy Policy Engine.

## Architektura integracji (zasada z dokumentacji + decyzja projektowa)

```
Jev rekomenduje.  Master planuje.  Policy Engine autoryzuje.
Scheduler przydziela wykonanie.  Narzędzia wykonują.  Testy i dowody potwierdzają.
```

- Jeden adapter w istniejącej warstwie providerów — żadnego mikroserwisu ani gatewaya.
- Agenci/klony kerneli NIE dostają bezpośredniego połączenia do zewnętrznego API.
- **Wywołanie providera decyzyjnego jest wyborem DETERMINISTYCZNYM** — zakaz rekurencji
  („Jev decyduje czy wołać Jev").
- `none`/`insufficient_information` jako legalna odpowiedź — model NIE MOŻE być zmuszony
  do wskazania „najmniej złego".
- **Brak odpowiedzi NIGDY ≠ „zezwól".**
- Rekomendacja związana z wersją stanu/rejestru/polityki — zmiana planu wymaga
  PONOWNEJ weryfikacji.

## LUKI (nie uzupełniać domysłem)
- Dokładny schemat bloku `questions` przy wielu pytaniach w jednym wywołaniu.
- Realne zachowanie przy złym kluczu (401) — wymaga pierwszego wywołania z kluczem.
- Kalibracja `confidence` na naszych danych — wymaga pomiaru.
- Pełna lista dozwolonych wartości `model`.

## Trasy dostępu
- **Natywne:** `api.typesafe.ai/v1/systemone` (ten dokument).
- **OpenRouter:** `typesafe/jev-router` widoczny w publicznym katalogu; `jev-1.13`
  route-only (nie w katalogu). Endpointy `openrouter.ai/api/alpha/decisions` oraz
  `openrouter.ai/api/v1/systemone` — **[LUKA]** nie zweryfikowane pomiarem.

## Powiązania
- `<workspace>/docs/design/jev-systemone-api-contract.md` — pełny kanon (12 sekcji + ślad weryfikacji)
- `<workspace>/docs/design/jev-raw-docs/` — 14 surowych plików źródłowych
- `<workspace>/docs/design/aigon-decision-provider-contract.md` — kontrakt Rust + polityka akceptacji
- `<workspace>/docs/design-jev-observability.md` — trójpodział dowodu, metryki, spany
- `<workspace>/runtime/docs/001-ADR/ADR-022-jev-provider-resilience.md` — odporność, mapa reużycia
