---
name: incident-response
description: Reagowanie na incydenty bezpieczeństwa — klasyfikacja SEV, containment, eradication, recovery, komunikacja i lessons learned. Użyj gdy incydent został potwierdzony i wymaga skoordynowanej akcji.
---


# Incident Response

**Purpose:** Prowadzić incydent bezpieczeństwa od potwierdzenia do zamknięcia w
kontrolowany sposób: ograniczyć szkody, usunąć przyczynę, przywrócić usługi i
wyciągnąć wnioski.

**When to use:** Po potwierdzeniu incydentu (z detekcji lub zgłoszenia), podczas
ćwiczeń (tabletop), przy naruszeniu danych lub przerwie w działaniu wywołanej
atakiem. Nie stosować do luźnych podejrzeń — najpierw attack-detection.

## Checklist

### Klasyfikacja

- [ ] Nadano identyfikator incydentu (np. INC-2026-0001) i otwarto kartę w systemie trackingu.
- [ ] Oszacowano SEV (1–4): wpływ na biznes, zakres naruszenia, dostępność usług, dane.
- [ ] Wyznaczono osobę prowadzącą (incident commander) i zespół reakcyjny z rolami.
- [ ] Zebrano wstępne dowody (okno czasowe, systemy, konta, artefakty) i zabezpieczono ich integralność.

### Containment

- [ ] Wyizolowano dotknięte zasoby (odłączenie od sieci, wyłączenie kont, blokada egress) — proporcjonalnie do SEV.
- [ ] Zabezpieczono dowody przed utratą (kopie, snapshoty, logi) PRZED działaniami naprawczymi.
- [ ] Ocena, czy containment nie pogarsza sytuacji (utrata danych, przerwa w działaniu kluczowych usług).
- [ ] Poinformowano zainteresowane strony zgodnie z polityką komunikacji incydentalnej.

### Eradication

- [ ] Zidentyfikowano root cause (wektor wejścia, mechanizm utrzymania, zakres kompromitacji).
- [ ] Usunięto artefakty ataku (złośliwe pliki, backdoory, trwałe zmiany konfiguracji, konta).
- [ ] Zmieniono sekrety i poświadczenia dotknięte incydentem (hasła, klucze, tokeny).
- [ ] Zastosowano poprawki / wzmocnienia eliminujące root cause (nie tylko objawy).

### Recovery

- [ ] Przywrócono usługi z czystych kopii lub po weryfikacji integralności systemów.
- [ ] Wzmocniono monitoring dotkniętych systemów (dodatkowa obserwacja po wznowieniu).
- [ ] Potwierdzono, że usługa działa zgodnie z wymaganiami (funkcjonalność, bezpieczeństwo).

### Zamknięcie

- [ ] Przygotowano raport powdrożeniowy (timeline, działania, skuteczność, luki w procesie).
- [ ] Przeprowadzono sesję lessons learned — udokumentowano co zadziałało, co zawiodło.
- [ ] Wdrożono akcje korygujące z raportu (zmiany procesów, narzędzi, konfiguracji) z właścicielami i terminami.

## Rules

- **Dowody przed naprawą:** żadna akcja naprawcza nie niszczy dowodów.
- **Jedna osoba prowadzi:** brak jednoosobowego dowodzenia prowadzi do chaosu.
- **Komunikacja udokumentowana:** decyzje i uzasadnienia zapisane w karcie incydentu.
- **Nie obwiniamy, naprawiamy:** lessons learned koncentruje się na procesie, nie na osobach.
- **Zamknięcie po weryfikacji:** incydent zamknięty dopiero po recovery i akcjach korygujących.
