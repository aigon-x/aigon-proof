---
name: design-document
description: "Tworzenie dokumentu projektowego (design doc / ADR): kontekst, decyzje, alternatywy, ryzyka, proces review i akceptacji. Użyj przed implementacją znaczącej zmiany architektonicznej lub funkcjonalnej."
---


# Design Document

**Purpose:** Zapisanie decyzji projektowej przed implementacją — kontekst,
rozważane opcje, wybór z uzasadnieniem, ryzyka — tak aby każdy członek zespołu
(i przyszły maintenance) rozumiał, dlaczego system jest taki, a nie inny.

**When to use:** Przed implementacją zmiany o istotnym wpływie (architektura,
interfejsy, dane), przy wyborze między rozwiązaniami, oraz gdy decyzja projektowa
ma być trwała i audytowalna (ADR).

## Checklist

- [ ] **Kontekst i problem:** opis obecnego stanu i problemu, który design doc rozwiązuje — konkretnie, z realnymi danymi, nie ogólnikami.
- [ ] **Cele i nie-cele:** jawne cele (czego ma dostarczyć zmiana) i nie-cele (czego świadomie NIE robimy).
- [ ] **Wymagania i ograniczenia:** zwięzła lista wymagań (funkcjonalnych i niefunkcjonalnych) oraz ograniczeń (czas, zasoby, kompatybilność).
- [ ] **Opcje:** co najmniej 2 rozważane rozwiązania (w tym „nie robić nic" gdy zasadne), każde z zaletami i wadami.
- [ ] **Wybór i uzasadnienie:** wskazana opcja z uzasadnieniem wobec wymagań; jeśli to ADR — decyzja jednoznaczna (status: proposed/accepted/superseded).
- [ ] **Alternatywy odrzucone:** dlaczego odrzucone pozostałe opcje — zapisane, nie pominięte.
- [ ] **Ryzyka i mitygacje:** lista ryzyk z prawdopodobieństwem i planem mitygacji; ryzyka bez mitygacji oznaczone jako otwarte.
- [ ] **Impact:** wskazane obszary dotknięte (kod, dane, API, operacje, dokumentacja) z listą plików/moduli do zmiany.
- [ ] **Proces review:** dokument zrecenzowany przez co najmniej 1 osobę spoza autora; uwagi rozpatrzone i odnotowane (rozwiązane/odroczone).
- [ ] **Zapis i odwołanie:** dokument zapisany w repo (np. `docs/decisions/`) i odwołany w pozycji backlogu realizującej zmianę.

## Rules

- **Decyzja przed kodem:** implementacja nie wyprzedza akceptacji design docu dla zmian o istotnym wpływie.
- **Bez retrospektywnego pisania:** design doc tworzy się PRZED implementacją; pisanie „jak zrobiliśmy" to już dokumentacja, nie design.
- **Opcje realne:** nie opisuj opcji, której nikt nie rozważyłby w praktyce.
- **ADR nie jest eselem:** ma strukturę i status; luźny opis pomysłu nie przechodzi jako decyzja.
