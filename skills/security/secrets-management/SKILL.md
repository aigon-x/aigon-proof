---
name: secrets-management
description: Zarządzanie sekretami — wykrywanie wycieków w repo i logach, rotacja, integracja z Vault, polityka dostępu, zero secrets w artefaktach. Użyj przy audycie bezpieczeństwa i przy każdym repo z kluczami.
---


# Secrets Management

**Purpose:** Wyeliminować sekrety (klucze, tokeny, hasła, certyfikaty) z kodu,
logów i artefaktów oraz zapewnić ich bezpieczną rotację i kontrolowany dostęp.

**When to use:** Przy audycie bezpieczeństwa repo, przy wykryciu podejrzenia
wycieku, przy konfigurowaniu nowego środowiska, przed release'em, przy pracy nad
repo zawierającym klucze API, tokeny JWT lub dane uwierzytelniające.

## Checklist (odhaczaj wszystkie)

### Wykrywanie

- [ ] Repo przeskanowane narzędziem do wykrywania sekretów (np. `gitleaks scan`, `trufflehog`, `git-secrets`) w całej historii, nie tylko w HEAD.
- [ ] Przeszukane pliki konfiguracyjne, pliki `.env*`, przykłady, dokumentacja i testy — nawet „niewinne" stałe.
- [ ] Zablokowane wzorce: `api_key`, `secret`, `password`, `token`, `BEGIN PRIVATE KEY`, `Authorization: Bearer` — w kodzie i w logach.
- [ ] Sprawdzone artefakty release'owe (obrazy, pakiety, buildy) pod kątem wpisanych sekretów.

### Remediacja wycieku

- [ ] KAŻDY wykryty sekret uznany za skompromitowany i wycofany (revoke/rotate) — niezależnie od tego, czy był publiczny.
- [ ] Sekret usunięty z historii repo (rewrite z `git filter-repo`) LUB wycofany, jeśli rewrite nie wchodzi w grę — decyzja zapisana.
- [ ] Zgłoszone zdarzenie wycieku do właściciela usługi (provider) tam, gdzie to wymagane.
- [ ] Zapisany wpis w logu bezpieczeństwa: co, gdzie, kiedy, jak wycofano.

### Rotacja i przechowywanie

- [ ] Nowe sekrety wygenerowane losowo (bezpieczna entropia) i zapisane WYŁĄCZNIE w menedżerze sekretów (np. Vault), nigdy w plikach repo.
- [ ] Dostęp do sekretów nadany na zasadzie least-privilege: każdy klient/środowisko ma tylko swoje ścieżki.
- [ ] Sekrety mają politykę rotacji (termin ważności, automatyczna rotacja) — zapisana i wdrożona.
- [ ] Klucze asymetryczne (SSH, GPG) mają datę wygaśnięcia lub proces okresowej rotacji.

### Ochrona procesu

- [ ] Mechanizm zapobiegawczy wdrożony: pre-commit hook (np. gitleaks) lub CI gate skanujący sekrety przy każdym pushu.
- [ ] Aplikacja czyta sekrety ze środowiska/menedżera sekretów — brak sekretów w kodzie źródłowym, konfiguracji w repo i logach.
- [ ] Weryfikacja po wdrożeniu: uruchomione skanery w środowisku produkcyjnym nie zgłaszają wycieków z nowych zmian.

## Rules

- **Wyciek = wycofanie, nie „to chyba nic ważnego":** sekret w historii repo jest skompromitowany bez dyskusji.
- **Zero sekretów w komunikacji:** nie wklejaj sekretów do czatu, logów, komentarzy, ticketów ani commit message.
- **Nie twórz nowych sekretów „na szybko":** każdy sekret przechodzi przez menedżer sekretów i politykę dostępu.
- **Dowód, nie deklaracja:** na końcu pokaż wynik skanera i potwierdzenie rotacji, nie samo oświadczenie.

<!-- DO NOT EDIT — managed by sync-agent-models.py (sync_skills); SSOT: skills/shared/ -->
