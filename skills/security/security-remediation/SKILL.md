---
name: security-remediation
description: Naprawa podatności i skutków ataków — priorytetyzacja wg ryzyka, patchowanie i wzmacnianie, weryfikacja naprawy, ponowny skan i dowód zamknięcia. Użyj po skanie bezpieczeństwa lub incydencie.
---


# Security Remediation

**Purpose:** Zamknąć podatności i luki bezpieczeństwa w sposób priorytetyzowany,
zweryfikowany i udokumentowany — z dowodem, że naprawa faktycznie działa.

**When to use:** Po skanie podatności (SAST/DAST/dependency scan), po incydencie
zidentyfikowanym w attack-detection, przed release'em, przy audycie zgodności
oraz po zmianach w konfiguracji środowiska.

## Checklist

### Priorytetyzacja

- [ ] Zebrano pełną listę podatności z wyników skanów i zgłoszeń (z ID, CVSS, lokalizacją).
- [ ] Oszacowano ryzyko dla środowiska: ekspozycja, dostępność weakness'a, wartość dotkniętego zasobu, istniejące kontrolki kompensujące.
- [ ] Ustalono kolejność napraw: krytyczne z aktywnym weakness'em w pierwszej kolejności, potem wysokie, średnie, niskie.
- [ ] Zweryfikowano, czy podatność nie jest false positive (ręczny przegląd przed naprawą).

### Naprawa

- [ ] Dla każdej podatności wybrano metodę naprawy: patch, aktualizacja wersji, zmiana konfiguracji, kontrolka kompensująca.
- [ ] Patch przetestowano w środowisku testowym przed wdrożeniem na produkcję (regresja).
- [ ] Wdrożono naprawę z zachowaniem procedury zmiany (backout plan, okno wdrożeniowe).
- [ ] Przy braku patcha (np. EOL): wdrożono kontrolkę kompensującą i udokumentowano ryzyko resztkowe.

### Weryfikacja

- [ ] Ponownie uruchomiono skan / testy dla naprawionego zakresu — podatność zniknęła.
- [ ] Sprawdzono, że naprawa nie zepsuła funkcjonalności (testy regresyjne, smoke testy).
- [ ] Zweryfikowano, że kontrolka kompensująca działa (testy skuteczności, nie tylko obecność konfiguracji).

### Zamknięcie

- [ ] Każda podatność otrzymała status zamknięty z dowodem: wynik re-skanu, commit/konfiguracja, data.
- [ ] Pozostałe ryzyka resztkowe udokumentowano z akceptacją właściciela systemu.
- [ ] Raport podsumowujący: ile zamknięto, ile odroczono, jaka redukcja ryzyka.

## Rules

- **Dowód zamknięcia = re-skan:** status zamknięty tylko z potwierdzeniem weryfikacji, nie na słowo.
- **Ryzyko, nie CVSS:** kolejność napraw wynika z ryzyka w konkretnym środowisku, nie samej punktacji.
- **False positive też zamykany:** udokumentuj powód odrzucenia, nie zostawiaj wisiącego.
- **Nie zostawiaj dziur:** naprawa obejmuje wszystkie środowiska (dev/stage/prod), nie tylko to wskazane.
