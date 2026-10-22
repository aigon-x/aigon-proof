# Strażnik czyta NIEISTNIEJĄCY klucz → ciche zejście na PRÓBKĘ = fałszywy-zielony

Zmierzone 2026-10-13. Klasa: **guard, który wygląda na pilnującego progu, ale z powodu
błędu w ścieżce danych NIGDY nie może przekroczyć progu** — więc nie wykryje nawet
regresji, którą miał wykrywać.

## Przypadek: `tests/unit/decision-graph-linkage.test.sh` (guard DGLINK-004)

Guard miał pilnować „niepodpięte skille < 1200":

```python
b = d.get('braki', {})
n = b.get('skills_unlinked_total')                 # ← tego klucza NIE MA w 'braki'
if n is None:
    n = len(b.get('skills_unlinked_sample', []))    # ← cicha degradacja na PRÓBKĘ (cap 200)
print(n or 0)
```

Prawdziwy licznik SSOT to `stats.gaps.skills_unlinked_total`; w `braki` jest tylko
`skills_unlinked_sample` (pierwsze 200 wpisów). Gdy luka realnie rosła do 2693,
guard czytał `len(sample)=200` → `200 < 1200` → **ZIELONY mimo realnej luki**.
Dodatkowo `n or 0` zamieniał brak klucza (`None`) na „zero braków".

## Reguła (ogólna, dla każdego guarda czytającego licznik z JSON/YAML)

1. **Fallback na PRÓBKĘ (`*_sample`) NIGDY nie jest substytutem licznika `*_total`.**
   Próbka z natury ma sufit (tu 200) → próg guarda staje się nieosiągalny → guard jest
   dekoracją, nie strażnikiem.
2. **Czytaj klucz SSOT jawnie i łańcuchowo** (`stats.gaps` → `braki`), a przy BRAKU
   wszystkich kandydatów zwróć wartość **fail-closed** (`print(99999)`), NIE `0` i NIE
   długość próbki. Brak pomiaru ≠ „zero problemów".
3. **`n or 0` jest OK** dla licznika, który legalnie bywa 0 — ale **nie** po cichym `None`
   z powodu braku klucza: to ten sam błąd co `None`→`0` w bramkach.
4. **Zaktualizuj KOMENTARZ guarda** razem z progiem/baseline — stare „baseline: 678"
   rozjeżdża się z rzeczywistością i myli następnego agenta.
5. **Test falsyfikowalny obowiązkowy:** ustaw chwilowo licznik ≥ progu i sprawdź, że guard
   **KRZYKNIE** (FAIL, nie ciche przejście przez fallback). Guard, który nie protestuje na
   wstrzyknięty błąd, jest ślepy — choćby świecił na zielono.

## Fix (zastosowany)

```python
d = yaml.safe_load(open(GRAPH))
g = d.get('stats', {}).get('gaps', {})
b = d.get('braki', {})
n = g.get('skills_unlinked_total')
if n is None:
    n = b.get('skills_unlinked_total')
if n is None:
    n = len(b.get('skills_unlinked_sample', []))   # ostatnia deska, ale NIE jako total
print(n if n is not None else 99999)               # fail-closed
```

## Szersza rodzina (ta sama klasa)
- `None`→`0` w bramce czytającej runtime (skill `false-green-elimination`).
- Bramka porównująca DEKLARACJĘ z DEKLARACJĄ (manifest vs manifest), bez pomiaru żywego.
- Odczyt z próbki/logu o ograniczonym oknie (`tail -N`) jako dowód całości.

**Zasada nadrzędna:** strażnik, którego nie da się zmusić do czerwieni, nie jest strażnikiem.
