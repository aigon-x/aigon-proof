---
name: threat-modeling
description: Modelowanie zagrożeń — DFD, trust boundaries, STRIDE per komponent, ranking ryzyka, output do backlogu. Użyj przy projektowaniu/zmianie architektury lub przed audytem bezpieczeństwa.
---


# Threat Modeling

**Purpose:** Systematycznie zidentyfikować zagrożenia dla systemu zanim staną się
incydentami — przez analizę przepływów danych, granic zaufania i atrybutów STRIDE,
z rankingiem ryzyka możliwym do zaplanowania w backlogu.

**When to use:** Na starcie projektu/komponentu, przy każdej istotnej zmianie
architektury, przy dodawaniu granicy zaufania (nowy serwis, nowa integracja,
nowy dostęp), przed audytem bezpieczeństwa, w odpowiedzi na zgłoszone podatności
w komponencie.

## Checklist (odhaczaj wszystkie)

### DFD i granice

- [ ] Narysowany diagram przepływów danych (DFD) poziomu 1: procesy, magazyny danych, aktorzy zewnętrzni.
- [ ] Oznaczone **trust boundaries**: każda zmiana poziomu zaufania (user→app, app→db, internet→serwis) ma granicę.
- [ ] Każdy przepływ danych ma zdefiniowany protokół i mechanizm uwierzytelnienia/autoryzacji.
- [ ] DFD zweryfikowany z implementacją — brak fikcyjnych przepływów nieistniejących w kodzie.

### STRIDE per komponent

- [ ] Dla KAŻDEGO elementu DFD rozpatrzone wszystkie 6 atrybutów STRIDE:
  - **S**poofing — podrobienie tożsamości; **T**ampering — modyfikacja danych;
  - **R**epudiation — brak dowodu działania; **I**nformation disclosure — wyciek;
  - **D**enial of service — przeciążenie; **E**levation of privilege — eskalacja uprawnień.
- [ ] Dla każdego zagrożenia zapisany wektor ataku i warunek konieczny (co musi być prawdą, żeby atak się udał).
- [ ] Zagrożenia bez mechanizmu obronnego oznaczone jako akceptowane TYLKO z jawną decyzją właściciela ryzyka.

### Ranking i priorytetyzacja

- [ ] Każde zagrożenie ma score: prawdopodobieństwo (1–5) × wpływ (1–5) = ryzyko.
- [ ] Ryzyko ≥ 9 ma wpis w backlogu z właścicielem i terminem; ryzyko 6–8 ma ścieżkę remediacji.
- [ ] Zaakceptowane ryzyka mają datę przeglądu i kryterium ponownej oceny.

### Output

- [ ] Wynik zapisany w formacie wielokrotnego użytku (plik markdown/yaml w repo, nie tylko notatka w czacie).
- [ ] Output zawiera: DFD, listę zagrożeń z atrybutami STRIDE, score, właściciela, plan remediacji.
- [ ] Model zagrożeń zaktualizowany po każdej zmianie architektury objętej zakresem.

## Rules

- **Świeży umysł, nie checkbox:** jeśli żadne zagrożenie nie „przychodzi do głowy", wróć do DFD i przeanalizuj każdą granicę z osobna.
- **Dowód, nie teoria:** każde zagrożenie musi mieć zakotwiczenie w realnym komponencie/ścieżce kodu.
- **Rejestr decyzji:** zmiana zakresu, akceptacja ryzyka i odrzucenie zagrożenia to decyzje — zapisane z właścicielem.
- **Granica odpowiedzialności:** jeśli zakres wymaga analizy poza repo (zewnętrzne API, fizyczne środowiska), odnotuj to jako osobną pozycję, nie rozmywaj modelu.

<!-- DO NOT EDIT — managed by sync-agent-models.py (sync_skills); SSOT: skills/shared/ -->
