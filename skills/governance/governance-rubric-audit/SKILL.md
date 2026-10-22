---
name: governance-rubric-audit
description: >-
  Audyt CAŁEJ warstwy governance (prawa + bramki + skille + role) rubryką wyprowadzoną
  z realnych ról odpowiedzialności, a potem DOMKNIĘCIE wyniku w grafie decyzyjnym.
  Użyj, gdy zlecenie brzmi „przejrzyj wszystkie prawa / bramki / skille i napraw, co nie
  jest perfekcyjne", „powołaj panel ekspertów i niech oceni", „zlinkuj to wszystko",
  „doprowadź do doskonałości", albo gdy liczba artefaktów jest zbyt duża, by oceniać je
  ręcznie (setki praw, setki bramek, tysiące skilli). Skill daje: rubrykę per typ artefaktu,
  walidację SAMEJ rubryki (kontrola dodatnia i ujemna), deklarowanie długu zamiast
  udawanej perfekcji, oraz wzorzec SSOT → idempotentny linker → bramka pokrycia.
category: quality-assurance
triggers:
  - "przejrzyj wszystkie prawa i bramki"
  - "panel ekspertów — jakie role byś powołał"
  - "audyt doskonałości / doprowadź do perfekcji"
  - "zlinkuj prawa bramki skille w jeden graf"
  - "czy wszystko można ustawić z configu"
  - "oceń całą bibliotekę skilli / bramek rubryką"
  - "rola bez artefaktu/miernika"
---


# Audyt governance rubryką ról (prawa · bramki · skille · role)

## Po co to istnieje

Zlecenie „przejrzyj wszystko i napraw, co nie jest perfekcyjne" na skali 200+ praw,
240+ bramek i 2900+ skilli nie da się wykonać ręcznie, a „przegląd opinią" daje raport,
którego nikt nie zweryfikuje. Ten skill zamienia takie zlecenie w **pomiar z rubryką**,
w którym każdy brak jest policzalny, każdy dług ma właściciela, a wynik jest wpięty
w graf decyzyjny (rola → prawo → bramka → skill), więc nie ginie w pliku.

Zasada nadrzędna: **perfekcja jest deklarowana, nie udawana.** Artefakt, który nie ma
egzekucji, dostaje `enforced_by: NONE` i wpis długu — nie dostaje punktu za samo
posiadanie pola.

## Kiedy używać

- „powołaj panel ekspertów i niech oceni wszystkie prawa/bramki/skille";
- „co nie jest perfekcyjne — napraw";
- „zlinkuj to wszystko w jeden graf / na strzał";
- po incydencie, w którym coś „było zielone, a nie działało" (rubryka pokaże, które
  artefakty nie mają egzekucji);
- gdy chcesz odpowiedzieć na pytanie „czy wszystko da się zmienić z configu".

NIE używaj do audytu jednej bramki (`gate-layer-audit`), jednej ośki runtime
(`runtime-health-graph-audit`) ani pojedynczego skilla (`hermes-agent-skill-authoring`).

## Rubryka (startowa; rozszerzaj, ale nie osłabiaj)

| typ | punkty (każdy 0/1) |
|---|---|
| PRAWO | `owner` · `enforced_by` (bramka albo `NONE` + dług) · `applies_to` · weryfikacja/selftest · `review_by` |
| BRAMKA | `owner` · skrypt istnieje · źródło (config/DB/API **albo żywy stan**) · progi w SSOT **tylko gdy porównuje liczby** · `--selftest` · wpięcie (trigger) · kontrakt pass/fail |
| SKILL | trigger (frontmatter `description` **lub** „Użyj gdy" w ciele) · kroki numerowane · weryfikacja/dowód · pitfalle |

Rola jest liczona tylko wtedy, gdy ma **artefakt + miernik + trigger** — inaczej jest
opisem, nie sterowaniem.

## Procedura

1. **Zbierz populację** (nie „próbkę"): liczba praw, bramek, skilli; mianownik jawny.
2. **Zdefiniuj rubrykę** i **zwaliduj ją, zanim zaufasz wynikowi** (patrz „Pułapka #1").
3. **Policz baseline** rubryki i zapisz (`artifacts/<audyt>/review.json` + `SUMMARY.json`).
4. **Napraw falami**, jedna klasa artefaktu na raz; po każdej fali policz ponownie TĄ
   SAMĄ komendą i pokaż PRZED/PO.
5. **Dług rejestruj jawnie**: `panel_meta.enforced_by: NONE`, `contract_owner: <zespół>`,
   `accepted_hardcoded` z `reason`. Wpis bez uzasadnienia jest ignorowany przez bramkę.
6. **Wpnij w graf**: SSOT ról → idempotentny linker → bramka pokrycia (patrz niżej).
7. **Przekaż resztę pętli**: cron „naczelnik" bierze jeden punkt backlogu na cykl i zamyka
   go dowodem (ledger before/after), bo audyt tej skali nie kończy się w jednej sesji.

## Pułapki (wszystkie zmierzone)

1. **RUBRYKA CZĘSTO MIERZY ZŁE MIEJSCE — i wtedy ogłaszasz fałszywy dług.**
   Zmierzone 2026-10-18: „953 skille bez triggera" było artefaktem, bo rubryka szukała
   „Użyj gdy" w pierwszych 2000 znakach CIAŁA, a Hermes czyta `description`
   z FRONTMATTERA. Po naprawie 13% → 25% perfekcyjnych. Analogicznie: wymaganie „progi
   w SSOT" od bramki, która nie porównuje liczb (bramka stanu), oraz liczenie „źródła"
   tylko jako config/DB bez żywego stanu (`docker`/`git`/`/proc`/`findmnt`/textfile).
   **Kontrola obowiązkowa:** rubryka musi dać pełny wynik na JEDNYM poprawnym artefakcie
   (kontrola dodatnia) i zero na jednym celowo zepsutym (kontrola ujemna). Bez tego
   nie wiesz, czy mierzysz artefakt, czy własny regex.
2. **Nie patchuj wielkiego generatora regexem — dopisz osobny, idempotentny linker.**
   Próba dopisania bloku do 900-liniowego `decision-graph-generate.py` przez `str.replace`
   wylądowała w środku literału dict → `SyntaxError`. Wzorzec, który działa: osobny
   skrypt czytający SSOT + gotowy graf, usuwający własne węzły/krawędzie przed
   dopisaniem (idempotencja), z trybem `--check` dla bramki. Gotowy przepis:
   `references/panel-graph-wiring.md`.
3. **Przywrócenie uszkodzonego pliku, gdy `git checkout` blokuje cudzy `index.lock`:**
   `git show HEAD:<ścieżka> > <ścieżka>` (czyta obiekt, nie dotyka indeksu), potem
   `python3 -m py_compile` / `bash -n` jako dowód sprawności.
4. **Masowa edycja plików kanonu: waliduj YAML PO KAŻDEJ zmianie i cofaj przy błędzie.**
   Dopisanie bloku do 10 plików `config/canonical/*.yaml` uszkodziło 8 — wartość
   z dwukropkiem (`verification: tool: tools/gates/x.sh`) nie jest poprawnym skalarem.
   Zapisz tylko gdy `yaml.safe_load(new)` przejdzie; przy wyjątku zostaw plik nietknięty.
5. **Rola bez instrumentu = teatr.** Rola, dla której nie ma bramki ani skilla, musi mieć
   jawne `no_instrument: '<co zbudować>'`; inaczej bramka pokrycia słusznie ją FAIL-uje.
6. **Dwa klucze na ten sam obiekt.** `name` vs `id`, `backend:name` vs `name`, nazwa
   zadania vs `nazwa@harmonogram` — porównuj po kluczu, który jest unikalny, i nazwij
   krotność (multiset), nie zbiór.
7. **Liczba bez nazw nie jest audytem.** Raport „228 bramek bez selftestu" wymaga listy
   (albo pliku JSON), inaczej następna sesja liczy od zera.

## Wzorzec domknięcia: SSOT → linker → bramka pokrycia

```
config/canonical/<domena>-panel.yaml     # SSOT: role/obiekty + patterns + artefakt + miernik
scripts/<domena>-graph-link.py           # idempotentny linker: najpierw usuń swoje, potem dodaj
tools/gates/<domena>-coverage.sh         # --check: obiekt bez krawędzi => FAIL; --selftest 2/2
cron: regeneracja grafu && linker         # inaczej następna regeneracja zgubi węzły
```
Dowód negatywny bramki: wstrzyknij do SSOT obiekt bez instrumentu i pokaż `rc=1`
(parametr `AIGON_<DOMENA>_FILE` pozwala wskazać tymczasową kopię SSOT — bez ruszania repo).

## Verification Checklist

- [ ] mianownik jawny (ile praw / bramek / skilli) i ta sama komenda PRZED i PO
- [ ] rubryka przeszła kontrolę dodatnią i ujemną (nie tylko „coś policzyła")
- [ ] każdy brak ma właściciela i termin (`review_by`), a nie tylko status
- [ ] dług zadeklarowany jawnie (`enforced_by: NONE`, `contract_owner`, `reason`)
- [ ] rola/obiekt bez instrumentu nie jest liczony jako perfekcyjny
- [ ] SSOT → linker → bramka: linker idempotentny, bramka ma `--selftest` ≥2/2
- [ ] regeneracja grafu w cronie woła linker (inaczej krawędzie znikają po cyklu)
- [ ] wynik zapisany jako JSON (lista, nie liczba), z polem `missing` per artefakt

## Artefakty

- `references/panel-graph-wiring.md` — gotowy przepis: SSOT ról YAML → idempotentny
  linker → bramka pokrycia, z kodami i pułapkami (w tym odtworzenie pliku przez
  `git show HEAD:` i walidacja YAML po masowej edycji).
