---
name: static-code-analysis
description: Analiza statyczna kodu (SAST) — wykrywanie podatności i błędów bez uruchamiania, triage fałszywych pozytywów, próg jakości w CI. Użyj przy audycie bezpieczeństwa i w kodzie przed merge.
---


# Static Code Analysis

**Purpose:** Wykryć podatności i defekty w kodzie źródłowym bez jego uruchamiania —
wcześnie, taniej niż testy dynamiczne — oraz utrzymać jakość na progu
egzekwowanym w CI.

**When to use:** Przy każdej istotnej zmianie kodu (code review), w CI przed
merge, przy audycie bezpieczeństwa, przy wdrażaniu SAST w istniejącym projekcie.

## Checklist (odhaczaj wszystkie)

### Konfiguracja

- [ ] Narzędzie SAST dopasowane do języków projektu (np. Semgrep, CodeQL, Ruff dla Pythona, ESLint z regułami security, Bandit).
- [ ] Zasady/reguły skonfigurowane pod projekt: włączone reguły security, wyłączone jawnie z uzasadnieniem.
- [ ] Skan działa w CI na każdym PR/merge request, z raportem w formacie czytelnym dla review.

### Przeprowadzenie

- [ ] Skan wykonany na faktycznej wersji kodu (nie na starej gałęzi) z uwzględnieniem zmienionych plików.
- [ ] Sprawdzone kluczowe klasy podatności: injection (SQL/OS/command), XSS, path traversal, hardcoded secrets, unsafe deserialization, użycie niebezpiecznych funkcji.
- [ ] Przepływy taint (wejście niezaufane → funkcja wrażliwa) prześledzone tam, gdzie narzędzie na to pozwala.
- [ ] Wynik zapisany (raport/JSON/SARIF) i dołączony do kontekstu review.

### Triage

- [ ] Każde znalezisko sklasyfikowane: true positive / false positive / nieosiągalne w tym kodzie.
- [ ] Fałszywe pozytywy wykluczone z uzasadnieniem (nie „bo tak") i zgłoszone do konfiguracji narzędzia.
- [ ] True positive: lokalizacja (plik:linia), wektor, proponowana poprawka — przypisane do właściciela.
- [ ] Podatności krytyczne (np. injection w ścieżce zewnętrznej) zablokowane przed merge.

### Jakość i utrzymanie

- [ ] Próg jakości w CI: reguła „zero nowych krytycznych" lub „zero nowych błędów dowolnej wagi" — wybrany i zapisany.
- [ ] Reguły narzędzia aktualizowane (nowe wzorce podatności) przy każdej aktualizacji narzędzia.
- [ ] Raport końcowy: znaleziska → sklasyfikowane → zremediowane, z dowodami (linki do fixów).

## Rules

- **SAST nie zastępuje review:** wyniki trafiają do review jako input, nie jako automatyczna wyrocznia.
- **Zero ślepych wykluczeń:** wyłączenie reguły/narzędzia dla pliku to decyzja z komentarzem i datą.
- **Krytyka osiągalności:** podatność w martwym kodzie to nadal wpis do backlogu, ale z niższym priorytetem — nie „zamieciona".
- **Mierz, nie deklaruj:** na końcu pokaż raport narzędzia i liczbę zremediowanych pozycji.

<!-- DO NOT EDIT — managed by sync-agent-models.py (sync_skills); SSOT: skills/shared/ -->
